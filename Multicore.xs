/* most win32 perls are beyond fixing, requiring dTHX */
/* even for ISO-C functions such as malloc. avoid! avoid! avoid! */
/* and fail to define numerous symbols, but still overrwide them */
/* with non-working versions (e.g. setjmp). */
#ifdef _WIN32
/*# define PERL_CORE 1 fixes some, breaks others */
#else
# define PERL_NO_GET_CONTEXT
#endif

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define X_STACKSIZE 1024 * sizeof (void *)

#include "CoroAPI.h"
#include "perlmulticore.h"
#include "schmorp.h"
#include "xthread.h"

#ifdef _WIN32
  #ifndef sigset_t
    #define sigset_t int
  #endif
#endif

#ifndef SvREFCNT_dec_NN
  #define SvREFCNT_dec_NN(sv) SvREFCNT_dec (sv)
#endif

#ifndef SvREFCNT_dec_simple_void_NN
  #define SvREFCNT_dec_simple_void_NN(sv) SvREFCNT_dec (sv)
#endif

#ifndef SvREFCNT_inc_NN
  #define SvREFCNT_inc_NN(sv) SvREFCNT_inc (sv)
#endif

#ifndef RECURSION_CHECK
  #define RECURSION_CHECK 0
#endif

static X_TLS_DECLARE(current_key);
#if RECURSION_CHECK
static X_TLS_DECLARE(check_key);
#endif

static void
fatal (const char *msg)
{
  write (2, msg, strlen (msg));
  abort ();
}

static s_epipe ep;
static void *perl_thx;
static sigset_t cursigset, fullsigset;

static int global_enable = 0;

/* per-coro override of global_enable, set by scoped_enable/scoped_disable:
 *   0 = unset, defer to global_enable
 *   1 = enabled  (scoped_enable)
 *   2 = disabled (scoped_disable)
 * Two things are encoded at once, which is why the test below reads
 * "(thread_enable ? thread_enable : global_enable) & 1": nonzero means "set, so
 * do not fall back", while bit 0 carries the on/off answer itself. */
static int thread_enable;

/* assigned to a thread for each release/acquire */
struct tctx
{
  void *coro;
  int wait_f;
  xcond_t acquire_c;
  int jeret;
};

static struct tctx *tctx_free;

static struct tctx *
tctx_get (void)
{
  struct tctx *ctx;

  if (!tctx_free)
    {
      ctx = malloc (sizeof (*tctx_free));
      X_COND_CREATE (ctx->acquire_c);
    }
  else
    {
      ctx = tctx_free;
      tctx_free = tctx_free->coro;
    }

  return ctx;
}

static void
tctx_put (struct tctx *ctx)
{
  ctx->coro = tctx_free;
  tctx_free = ctx;
}

/* a stack of tctxs */
struct tctxs
{
  struct tctx **ctxs;
  int cur, max;
};

static struct tctx *
tctxs_get (struct tctxs *ctxs)
{
  return ctxs->ctxs[--ctxs->cur];
}

static void
tctxs_put (struct tctxs *ctxs, struct tctx *ctx)
{
  if (ctxs->cur >= ctxs->max)
    {
      ctxs->max = ctxs->max ? ctxs->max * 2 : 16;
      ctxs->ctxs = realloc (ctxs->ctxs, ctxs->max * sizeof (ctxs->ctxs[0]));
    }

  ctxs->ctxs[ctxs->cur++] = ctx;
}

static xmutex_t release_m = X_MUTEX_INIT;
static xcond_t release_c = X_COND_INIT;
static struct tctxs releasers;
static int idle;
static int max_idle = 1;      /* idle worker threads to keep warm; excess ones retire */
static int idle_timeout = 10; /* seconds an excess idle thread waits before retiring (0 = never reap) */
static int curthreads, max_threads = 1; /* protected by release_m */

static xmutex_t acquire_m = X_MUTEX_INIT;
static struct tctxs acquirers;

X_THREAD_PROC(thread_proc)
{
  PERL_SET_CONTEXT (perl_thx);

  {
    dTHXa (perl_thx);
    dJMPENV;
    struct tctx *ctx;
    int catchret;

    X_LOCK (release_m);

    for (;;)
      {
        int reaping = 0;

        /* wait for a releaser; if we stay idle past idle_timeout while more than
         * max_idle threads sit idle, retire this one (never dropping the warm
         * pool below max_idle threads). */
        while (!releasers.cur)
          if (idle_timeout && idle > max_idle)
            {
              struct timespec ts = { time (0) + idle_timeout, 0 };

              if (X_COND_TIMEDWAIT (release_c, release_m, ts) == ETIMEDOUT
                  && idle > max_idle && !releasers.cur)
                {
                  reaping = 1;
                  break;
                }
            }
          else
            X_COND_WAIT (release_c, release_m);

        if (reaping)
          {
            --idle;
            --curthreads;
            X_UNLOCK (release_m);
            break;
          }

        ctx = tctxs_get (&releasers);
        --idle;
        X_UNLOCK (release_m);

        pthread_sigmask (SIG_SETMASK, &cursigset, 0);
        JMPENV_PUSH (ctx->jeret);

        if (!ctx->jeret)
          while (ctx->coro)
            CORO_SCHEDULE;

        JMPENV_POP;
        pthread_sigmask (SIG_SETMASK, &fullsigset, &cursigset);

        X_LOCK (acquire_m);
        ctx->wait_f = 1;
        X_COND_SIGNAL (ctx->acquire_c);
        X_UNLOCK (acquire_m);

        X_LOCK (release_m);
        ++idle;
      }
  }
}

static void
start_thread (void)
{
  xthread_t tid;

  if (!curthreads)
    {
      X_UNLOCK (release_m);
      {
        dTHX;
        dSP;

        PUSHSTACKi (PERLSI_REQUIRE);

        eval_pv ("Coro::Multicore::init", 1);

        POPSTACK;
      }
      X_LOCK (release_m);
    }

  if (curthreads >= max_threads && 0)
    return;

  ++curthreads;
  ++idle;
  xthread_create (&tid, thread_proc, 0);
}

/* Whether Coro's libcoro backend can have a parked context resumed by a thread
 * other than the one that parked it.  Decided once at BOOT from Coro's own
 * report; assume it can, so that an unrecognised backend behaves as before. */
static int backend_migrates = 1;

static void
pmapi_release (void)
{
  /* Releasing the interpreter hands it to another native thread, which runs
   * other coro threads - exactly what an atomic {} section forbids. So while the
   * running coro is atomic, suppress multicore entirely and let the XS function
   * run inline on this thread. This deliberately overrides both scoped_enable
   * and the global enable: atomicity is a correctness guarantee, whereas
   * multicore is an optimisation, and perlmulticore is specified so that a
   * release that does nothing is always valid.
   *
   * Without this the call dies rather than merely breaking atomicity: the worker
   * thread's CORO_SCHEDULE hits the same atomic check, and the exception comes
   * back through the transfer's JMPENV to be rethrown at pmapi_acquire ().
   *
   * Clearing current_key is what makes the matching pmapi_acquire () a no-op,
   * so the pairing stays correct even if the atomic count changes in between. */
  if (CORO_ATOMIC)
    {
      X_TLS_SET (current_key, 0);
      return;
    }

  /* Same treatment for a backend whose context only its own thread may resume
   * (see BOOT).  There the release is not merely pointless but undefined, so it
   * has to be refused rather than attempted - and refusing is always valid, since
   * perlmulticore specifies a release that does nothing as legal. */
  if (!backend_migrates)
    {
      X_TLS_SET (current_key, 0);
      return;
    }

  if (! ((thread_enable ? thread_enable : global_enable) & 1))
    {
      X_TLS_SET (current_key, 0);
      return;
    }

  #if RECURSION_CHECK
  if (X_TLS_GET (check_key))
    fatal ("FATAL: perlinterp_release () called without valid perl context");

  X_TLS_SET (check_key, &check_key);
  #endif

  struct tctx *ctx = tctx_get ();
  ctx->coro = SvREFCNT_inc_simple_NN (CORO_CURRENT);
  ctx->wait_f = 0;

  X_TLS_SET (current_key, ctx);
  pthread_sigmask (SIG_SETMASK, &fullsigset, &cursigset);

  X_LOCK (release_m);

  if (idle <= max_idle)
    start_thread ();

  tctxs_put (&releasers, ctx);
  X_COND_SIGNAL (release_c);

  while (!idle && releasers.cur)
    {
      X_UNLOCK (release_m);
      X_LOCK (release_m);
    }

  X_UNLOCK (release_m);
}

/* Fires at the consuming XSUB's scope exit - after its body has returned and
 * cleaned up - and raises the exception that was aimed at this coro while it had
 * the interpreter released.  Armed by pmapi_acquire () below, which deliberately
 * does not raise it itself.
 *
 * We own the exception: pmapi_acquire () took it out of CORO_THROW when arming, so
 * nothing else can deliver it as well. */
static void
deliver_pending_throw (pTHX_ void *arg)
{
  SV *exception = (SV *)arg;

  sv_setsv (ERRSV, exception);
  SvREFCNT_dec (exception);
  croak (0);
}

static void
pmapi_acquire (void)
{
  int jeret;
  struct tctx *ctx = X_TLS_GET (current_key);

  if (!ctx)
    return;

  #if RECURSION_CHECK
  if (X_TLS_GET (check_key) != &check_key)
    fatal ("FATAL: perlinterp_acquire () called with valid perl context");

  X_TLS_SET (check_key, 0);
  #endif

  X_LOCK (acquire_m);

  tctxs_put (&acquirers, ctx);

  s_epipe_signal (&ep);
  while (!ctx->wait_f)
    X_COND_WAIT (ctx->acquire_c, acquire_m);
  X_UNLOCK (acquire_m);

  jeret = ctx->jeret;
  tctx_put (ctx);
  pthread_sigmask (SIG_SETMASK, &cursigset, 0);

  if (jeret)
    {
      dTHX;
      JMPENV_JUMP (jeret);
    }

  /* An exception aimed at this coro while it was released must not be raised
   * here: the XS function has finished its blocking work but still has cleanup to
   * do, and it installed no handler for us unwinding through it.  Instead take
   * ownership and arm it to fire at this XSUB's scope exit, once the body has
   * returned - so an eval around the call sees it, while the XS frame really did
   * return normally.
   *
   * Without this the exception waits for the coro's next Schedule-Like Function
   * (pp_slf is the only place Coro delivers one), which may be far away - or never
   * happen, if the coro returns from the call and then ends, in which case it was
   * silently dropped. */
  if (CORO_THROW)
    {
      dTHX;
      SV *exception = CORO_THROW;

      CORO_THROW = 0;
      SAVEDESTRUCTOR_X (deliver_pending_throw, exception);
    }
}

static void
set_thread_enable (pTHX_ void *arg)
{
  thread_enable = PTR2IV (arg);
}

static void
atfork_child (void)
{
  s_epipe_renew (&ep);
}

/* ===========================================================================
 * EXPERIMENTAL offload backend (off by default)
 *
 * The core "offload" primitive (perlmulticore.h: multicore_offload) is the dual
 * of the release/acquire bracket: instead of migrating the interpreter to a
 * worker while a blocking call stays put, it runs a pure-C `work` function on a
 * worker thread while the interpreter stays PINNED to this thread.  Because that
 * migration never happens, it works where release/acquire cannot - notably
 * Windows.
 *
 * This backend is the STACKFUL (Coro) delivery: multicore_offload() suspends the
 * calling Coro, runs `work` on a worker, and when it finishes resumes the Coro
 * and runs the consumer's `done` in it to marshal the C result into an SV, which
 * is returned as the call's value.  So the offloaded call looks synchronous to
 * the caller (no function colouring) while other Coro threads run meanwhile - and
 * because the interpreter itself is never migrated or blocked, it works where the
 * release/acquire bracket cannot, notably Windows.  (A stackless Future::AsyncAwait
 * backend implements the same core hook differently: it returns a Future and
 * resolves it from done() on the loop - same signature, caller awaits it.)
 *
 * Backed by a small pool of worker threads plus our existing wakeup pipe: each
 * enqueue reserves an idle worker or grows the pool (so concurrent offloads run
 * in parallel), the worker signals the pipe on completion, and poll() readies the
 * suspended Coro, which then runs done() and returns its SV.
 *
 * Jobs come from a small pool preallocated on first use, not from a per-call
 * malloc.  When every pooled job is in flight the caller simply runs the work
 * inline on the interpreter thread (blocking, but correct): with all worker
 * slots busy, doing the work on the calling thread is a sensible fallback and
 * keeps the hot path allocation-free.
 *
 * It is only compiled when this perl provides the core hook (HAVE_MULTICORE_-
 * OFFLOAD, set by Makefile.PL), and even then it is NOT installed unless
 * Coro::Multicore::enable_offload(1) is called.  The default backend
 * remains the release/acquire bracket registered in BOOT.
 * ======================================================================== */
#ifdef HAVE_MULTICORE_OFFLOAD

/* Contexts handed to work/done.  Centralised so the worker and the three inline
 * paths cannot drift apart.  Nothing is carried yet: no cancellation mechanism
 * exists, so `cancel` is always 0 and `cancelled` always 0 - the structs are
 * constructed regardless so a module never has to special-case a path. */
#define OFFLOAD_WORK_CTX_INIT(ctx, cancelp) \
  do { (ctx).size = sizeof (ctx); (ctx).cancel = (cancelp); } while (0)
#define OFFLOAD_DONE_CTX_INIT(ctx, was_cancelled, was_dropped) \
  do { (ctx).size = sizeof (ctx); (ctx).cancelled = (was_cancelled); \
       (ctx).dropped = (was_dropped); } while (0)

struct offload_job
{
  perl_multicore_work_t work;
  void *work_arg;
  perl_multicore_done_t done;   /* marshals the C result into the handle's value */
  void *done_arg;
  HV *hv;                       /* the handle this job resolves - NOT a reference:
                                 * the handle would then never be destroyed, and its
                                 * destruction is what tells us it was dropped.  Only
                                 * ever dereferenced on the interpreter thread, and
                                 * cleared there before the handle is freed. */
  void *coro;                   /* the Coro (SV*) that issued this, for the
                                 * cancel_offload ($coro) shim.  A counted
                                 * reference, dropped when the job is released. */
  int state;                    /* OJ_* below: who is responsible for the slot     */
  perl_multicore_cancel_t cancel; /* advisory: set when the work should stop early  */
  int finished;                 /* set by the WORKER, under the lock, when work ()
                                 * has returned - so whoever is unwinding can tell
                                 * whether anything is still touching its data */
  struct offload_job *next;
};

/* Slot ownership.  The handle and the worker share a job, so exactly one side must
 * be responsible for returning the slot at any moment:
 *
 *   OJ_INFLIGHT  queued or being worked on - the WORKER owns it.  The handle must
 *                not free it; the worker will still write j->next when it moves the
 *                job to offload_done.
 *   OJ_ABANDONED the handle was destroyed while still pending, so nothing is
 *                waiting for this result and nothing may be resolved.
 *                offload_run_done () reclaims the slot instead.
 *
 * A job never becomes the handle's to free: offload_run_done () releases the slot
 * itself, before running done () (see there).  Only the interpreter thread reads or
 * writes `state`, so it needs no lock of its own. */
#define OJ_INFLIGHT  0
#define OJ_ABANDONED 2

/* What resolution still needs after the job slot has gone back.  The slot must be
 * released before done () runs - done () may croak, and that must not lose a slot -
 * so the three things done () needs are copied out of the job first. */
struct offload_completion
{
  perl_multicore_done_t done;
  void *done_arg;
  int cancelled;
  int dropped;      /* the handle went away: the value has nowhere to go */
};

/* size of the preallocated job pool; jobs beyond this run inline (see above) */
#define OFFLOAD_SLOTS 16

static xmutex_t offload_m = X_MUTEX_INIT;
static xcond_t  offload_c = X_COND_INIT;     /* new work for a worker            */
static xcond_t  offload_fin_c = X_COND_INIT; /* a worker finished with a job     */
static struct offload_job *offload_pending; /* jobs to run on the worker    */
static struct offload_job *offload_done;    /* finished, awaiting done()     */
static struct offload_job *offload_free;    /* pooled jobs available to reuse */
static struct offload_job offload_slots[OFFLOAD_SLOTS]; /* the pool storage   */
static int offload_inited;                  /* freelist built once           */
static int offload_idle;                    /* worker threads waiting for work */
static int offload_nthreads;                /* worker threads alive (<= SLOTS) */

/* Stop an offload and take the job away from the pool, waiting for the worker if it
 * is still going.  Two callers, and the difference between them is the whole
 * difference between the two kinds of cancellation:
 *
 *   dropped=1  the handle was destroyed while still pending, so nobody is going to
 *              collect this result.  `work_arg`, and whatever the work writes into,
 *              generally belongs to the frame being torn down, so returning while
 *              the work ran would hand the worker freed memory.
 *
 *   dropped=0  $handle->cancel, which is PROMPT: it blocks the interpreter until
 *              the work has actually stopped, so that when it returns the offload
 *              is over.  ($handle->safe_cancel is the one that does not block; it
 *              only raises the flag, and waits by resolving an awaitable.)
 *
 * Either way the wait blocks this thread - that is what prompt costs - and how long
 * depends on how promptly `work` polls its cancel flag.
 *
 * A job still queued is simply taken off the queue - it never has to start.
 *
 * OJ_ABANDONED poisons the job so that offload_run_done () resolves nothing: the
 * completion goes to the caller instead, since it is the caller that now knows when
 * the work stopped.  Whoever gets the job off the finished list frees the slot; if
 * poll () already has the list in its hands, it does.
 *
 * `done` runs either way - it is the only place a module can release what it built,
 * and a consumer that returned the handle upward has its job on the heap with
 * nothing else able to free it.  So the completion is handed back to the perl half,
 * which runs it there and then: for a dropped handle it has to be before the handle
 * finishes being destroyed, because a frame-owned job dies with the frame being torn
 * down.
 *
 * The coro reference is dropped outside the lock, since freeing a coro can run
 * perl. */
static int offload_abandons;      /* how many times a handle was dropped pending */
static int offload_abandon_waits; /* ... and had to wait for a running work      */

static struct offload_completion *
offload_stop_and_take (pTHX_ struct offload_job *j, int dropped)
{
  struct offload_completion *c = 0;
  SV *coro = 0;

  X_LOCK (offload_m);

  if (j->state == OJ_INFLIGHT)
    {
      struct offload_job **pp;
      int queued = 0;

      if (dropped)
        {
          ++offload_abandons;
          j->hv = 0;            /* the handle is on its way out */
        }

      j->state = OJ_ABANDONED;
      j->cancel = 1;
      coro = (SV *)j->coro;
      j->coro = 0;

      /* still queued: unlink it, and give back both the slot and the worker that
       * was reserved for it.  Nothing ever ran. */
      for (pp = &offload_pending; *pp; pp = &(*pp)->next)
        if (*pp == j)
          {
            *pp = j->next;
            ++offload_idle;
            queued = 1;
            break;
          }

      if (!queued && !j->finished)
        {
          if (dropped)
            ++offload_abandon_waits;

          do
            X_COND_WAIT (offload_fin_c, offload_m);
          while (!j->finished);
        }

      Newx (c, 1, struct offload_completion);
      c->done      = j->done;
      c->done_arg  = j->done_arg;
      c->cancelled = 1;
      c->dropped   = dropped;

      /* Take the finished job off the list ourselves and free the slot, so that the
       * offload is over in every sense by the time this returns.  If poll () has
       * already detached the list, leave it: the poison makes it reclaim the slot
       * and resolve nothing. */
      if (queued)
        {
          j->next = offload_free;
          offload_free = j;
        }
      else
        for (pp = &offload_done; *pp; pp = &(*pp)->next)
          if (*pp == j)
            {
              *pp = j->next;
              j->next = offload_free;
              offload_free = j;
              break;
            }
    }

  X_UNLOCK (offload_m);

  if (coro)
    SvREFCNT_dec_NN (coro);

  return c;
}

/* ---------------------------------------------------------------------------
 * The handle
 *
 * multicore_offload () hands back a handle object instead of a value: the core
 * contract says the backend supplies it, the consuming module returns it without
 * naming its class, and the caller takes the result out through `await` (a
 * stackless caller), or `get` (a Coro one, which suspends until it is there).
 *
 * The object is a blessed hash, and its protocol half - the AWAIT_* methods of
 * Future::AsyncAwait::Awaitable, plus get/cancel - lives in perl, in
 * Coro::Multicore::Offload::Awaitable.  What is here is the part that needs the
 * job: creating the handle, parking a coro on it, cancelling, abandoning, and
 * running done () once the worker is finished.  Fields shared with the perl half:
 *
 *   job      IV, the in-flight job; deleted at resolution, absent on a handle
 *            that has no job (one made by AWAIT_NEW_DONE and friends)
 *   ready    set by the perl half when the handle resolves; what the wait polls
 *   waiters  the Coro threads parked in offload_wait (), readied at resolution
 *
 * Resolution runs on the interpreter thread, from poll (), not in the coro that
 * issued the offload - the same place a stackless backend would resolve its
 * future.  done () therefore runs there too, and a croak from it becomes the
 * handle's failure rather than an exception at the point of call, which is what
 * makes the failure reach whoever eventually asks for the value.
 * ------------------------------------------------------------------------- */

#define OFFLOAD_HANDLE_CLASS "Coro::Multicore::Offload::Awaitable"

/* A fresh handle has no job: the inline paths never get one, and for the queued
 * path offload_handle_attach () adds it while the pool lock is held. */
static SV *
offload_handle_new (pTHX)
{
  HV *hv = newHV ();
  SV *rv;

  (void)hv_stores (hv, "ready", newSViv (0));

  rv = newRV_noinc ((SV *)hv);
  sv_bless (rv, gv_stashpv (OFFLOAD_HANDLE_CLASS, GV_ADD));

  return rv;
}

/* Tie a handle and a job together.  Each side needs the other: the handle to
 * cancel or abandon the job, the job to know what to resolve when the work is
 * over.  Neither pointer is a counted reference - see the job's `hv`. */
static void
offload_handle_attach (pTHX_ HV *hv, struct offload_job *j)
{
  (void)hv_stores (hv, "job", newSViv (PTR2IV (j)));
  j->hv = hv;
}

static HV *
offload_handle_hv (pTHX_ SV *hsv)
{
  if (!SvROK (hsv) || SvTYPE (SvRV (hsv)) != SVt_PVHV)
    croak ("Coro::Multicore: not an offload handle");

  return (HV *)SvRV (hsv);
}

/* the job a handle is still waiting for, or 0 if it has none (resolved, abandoned,
 * or never had one) */
static struct offload_job *
offload_handle_job (pTHX_ HV *hv)
{
  SV **svp = hv_fetchs (hv, "job", 0);

  return svp && SvOK (*svp) ? INT2PTR (struct offload_job *, SvIV (*svp)) : 0;
}

static int
offload_handle_ready (pTHX_ HV *hv)
{
  SV **svp = hv_fetchs (hv, "ready", 0);

  return svp && SvTRUE (*svp);
}

/* Register the running coro as waiting on this handle, so that resolution readies
 * it.  Several coros may park on one handle, and one coro parks again on every
 * turn of the wait loop, so the list is emptied at resolution rather than kept.
 *
 * A parked coro cannot be forgotten while it is parked: the frame that called
 * get () holds the handle, so it cannot be destroyed under us.  A coro that is
 * cancelled while parked would leave its entry behind, though, and readying it
 * later is at best pointless - so the wait arms offload_unpark () to take it out
 * again, which also breaks the reference cycle (handle -> coro -> ... -> handle)
 * that would otherwise leak both. */
static void
offload_handle_park (pTHX_ HV *hv)
{
  SV **svp = hv_fetchs (hv, "waiters", 0);
  AV *waiters;

  if (svp && SvROK (*svp))
    waiters = (AV *)SvRV (*svp);
  else
    {
      waiters = newAV ();
      (void)hv_stores (hv, "waiters", newRV_noinc ((SV *)waiters));
    }

  av_push (waiters, newRV_inc (CORO_CURRENT));
}

struct offload_waiter
{
  HV *hv;
  SV *coro;
};

static void
offload_unpark (pTHX_ void *arg)
{
  struct offload_waiter *w = arg;
  SV **svp = hv_fetchs (w->hv, "waiters", 0);

  if (svp && SvROK (*svp))
    {
      AV *waiters = (AV *)SvRV (*svp);
      SSize_t i;

      for (i = av_len (waiters); i >= 0; --i)
        {
          SV **e = av_fetch (waiters, i, 0);

          if (e && SvROK (*e) && SvRV (*e) == w->coro)
            (void)av_delete (waiters, i, G_DISCARD);
        }
    }
}

/* Hand the completion to the perl half, which runs done () inside an eval and
 * resolves the handle with what came back - a value, or the failure done () raised.
 *
 * Called from poll () on the normal path and directly from multicore_offload () on
 * the inline ones, so this is the single place a handle is ever resolved. */
static void
offload_complete (pTHX_ HV *hv, perl_multicore_done_t done, void *done_arg,
                  int cancelled)
{
  struct offload_completion *c;
  dSP;

  Newx (c, 1, struct offload_completion);
  c->done      = done;
  c->done_arg  = done_arg;
  c->cancelled = cancelled;
  c->dropped   = 0;

  ENTER;
  SAVETMPS;

  PUSHMARK (SP);
  EXTEND (SP, 2);
  PUSHs (sv_2mortal (newRV_inc ((SV *)hv)));  /* blessed: the HV carries the stash */
  mPUSHi (PTR2IV (c));
  PUTBACK;

  call_method ("_complete", G_VOID | G_DISCARD | G_EVAL);

  /* _complete () traps done () itself, so a failure here is a bug in this module
   * (or a destructor firing during it); there is nobody to raise it to - we are in
   * an event-loop callback - so report it and carry on. */
  if (SvTRUE (ERRSV))
    warn ("Coro::Multicore: offload completion failed: %" SVf, SVfARG (ERRSV));

  FREETMPS;
  LEAVE;
}

X_THREAD_PROC(offload_thread_proc)
{
#ifndef _WIN32
  pthread_sigmask (SIG_SETMASK, &fullsigset, 0); /* the worker never handles perl signals */
#endif

  X_LOCK (offload_m);

  for (;;)
    {
      struct offload_job *j;

      /* a freshly spawned worker goes straight to its (already pending) job; a
       * reused worker was made idle at the bottom and reserved by an enqueue. */
      while (!offload_pending)
        X_COND_WAIT (offload_c, offload_m);

      j = offload_pending;
      offload_pending = j->next;
      X_UNLOCK (offload_m);

      {
        perl_multicore_work_ctx work_ctx;
        OFFLOAD_WORK_CTX_INIT (work_ctx, &j->cancel);
        j->work (j->work_arg, &work_ctx); /* pure C - must touch no perl data */
      }

      X_LOCK (offload_m);
      j->finished = 1;
      j->next = offload_done;
      offload_done = j;
      ++offload_idle;        /* available again (a later enqueue reserves us) */
      s_epipe_signal (&ep);  /* wake the interpreter loop to run done() */
      X_COND_BROADCAST (offload_fin_c); /* an unwinding issuer may be waiting */
    }
}

/* the offload backend, registered with core's multicore_register_offload().
 * This is the stackful (Coro) delivery: `work` runs on a worker thread with the
 * interpreter pinned here, and this returns at once with a PENDING handle.  When
 * the worker finishes, poll () runs `done` to marshal the C result and resolves
 * the handle with it; a caller that asks for the value with `get` is suspended
 * until then, so an offloaded call still looks synchronous to its caller - while
 * other Coro threads run meanwhile - and the interpreter is neither blocked nor
 * migrated (which is why this works on Windows).
 *
 * Returning the handle rather than the value is what lets a caller hold several
 * offloads in flight from one coro, and what makes the same XSUB usable under a
 * stackless backend, which resolves its own handle from its loop.
 *
 * The two inline paths below run the work here and hand back an already-resolved
 * handle: permitted by the contract, and indistinguishable to a consumer that
 * asks for the value straight away. */
static SV *
pmapi_offload (perl_multicore_work_t work, void *work_arg,
               perl_multicore_done_t done, void *done_arg)
{
  dTHX;
  struct offload_job *j;
  SV *hsv;

  /* Collecting the result suspends the calling coro, which an atomic {} section
   * forbids - and would trip Coro's yield check and croak.  Since a handle
   * returned from inside a section is very likely waited on inside it too, run
   * the work inline instead: same fallback as pool exhaustion below, blocking but
   * correct.  Overrides the enable flags for the reasons given in
   * pmapi_release (). */
  if (CORO_ATOMIC)
    {
      perl_multicore_work_ctx work_ctx;
      SV *hsv;

      OFFLOAD_WORK_CTX_INIT (work_ctx, 0);
      work (work_arg, &work_ctx);

      hsv = offload_handle_new (aTHX);
      offload_complete (aTHX_ (HV *)SvRV (hsv), done, done_arg, 0);

      return hsv;
    }

  /* The handle is created before the job is attached to it, so there is exactly
   * one construction path whether or not a slot is available.  Nothing can
   * resolve it in between: resolution only happens in poll (), on this thread,
   * and there is no yield point between here and the return. */
  hsv = offload_handle_new (aTHX);

  X_LOCK (offload_m);

  if (!offload_inited)
    {
      int i;

      /* first use: build the freelist from the preallocated job pool. */
      for (i = OFFLOAD_SLOTS; i--; )
        {
          offload_slots[i].next = offload_free;
          offload_free = &offload_slots[i];
        }

      offload_inited = 1;
    }

  j = offload_free;

  if (j)
    {
      offload_free = j->next;

      j->work = work; j->work_arg = work_arg;
      j->done = done; j->done_arg = done_arg;
      j->coro = SvREFCNT_inc_simple_NN (CORO_CURRENT);
      j->state = OJ_INFLIGHT;
      j->cancel = 0;
      j->finished = 0;

      offload_handle_attach (aTHX_ (HV *)SvRV (hsv), j);

      j->next = offload_pending;
      offload_pending = j;

      /* claim a worker for this job: reserve an idle one, or (if none, and we
       * are under the cap) grow the pool by one.  Reserving up-front - rather
       * than letting the worker decrement when it wakes - is what lets a burst
       * of concurrent offloads each get their own worker (and so run in
       * parallel) instead of piling onto the first idle worker. Beyond the cap
       * the job simply waits for a worker to free up. */
      if (offload_idle > 0)
        --offload_idle;
      else if (offload_nthreads < OFFLOAD_SLOTS)
        {
          xthread_t tid;
          ++offload_nthreads;
          xthread_create (&tid, offload_thread_proc, 0);
        }

      X_COND_SIGNAL (offload_c);
    }

  X_UNLOCK (offload_m);

  if (!j) /* pool exhausted: run inline - blocking but correct (see above) */
    {
      perl_multicore_work_ctx work_ctx;

      OFFLOAD_WORK_CTX_INIT (work_ctx, 0);
      work (work_arg, &work_ctx);
      offload_complete (aTHX_ (HV *)SvRV (hsv), done, done_arg, 0);
    }

  return hsv;
}

/* Suspend this coro until the handle resolves.  This is where the blocking that
 * multicore_offload () used to do has moved to: the perl half calls it from get ()
 * and AWAIT_WAIT, so a consumer that asks for the value straight away behaves
 * exactly as an offloaded call always did.
 *
 * CORO_SCHEDULE keeps the event loop turning, which is what makes waiting here
 * safe: the completion arrives through poll (), so a wait that blocked the thread
 * would deadlock instead.
 *
 * It is also a yield point, so an exception aimed at this coro is delivered here -
 * and must not be raised yet.  The worker is still using work_arg, and whatever
 * the work writes into generally belongs to the frame that unwinding would
 * destroy, so the exception is taken over, the work is asked to stop, and it is
 * raised below once the work has really finished. */
static void
offload_wait (pTHX_ SV *hsv)
{
  HV *hv = offload_handle_hv (aTHX_ hsv);
  SV *pending = 0;
  struct offload_waiter w;

  if (CORO_ATOMIC)
    croak ("Coro::Multicore: cannot wait for an offload inside an atomic section");

  w.hv   = hv;
  w.coro = CORO_CURRENT;

  ENTER;
  SAVEDESTRUCTOR_X (offload_unpark, &w);  /* `w` outlives it: same C frame */

  while (!offload_handle_ready (aTHX_ hv))
    {
      offload_handle_park (aTHX_ hv);

      CORO_SCHEDULE;

      if (CORO_THROW)
        {
          struct offload_job *j = offload_handle_job (aTHX_ hv);

          /* Coro itself only delivers a pending exception at the end of a
           * Schedule-Like Function, and CORO_SCHEDULE is not one, so nothing
           * would raise this until the coro's next yield - long after the offload
           * finished.  Take it over and raise it ourselves.  A further exception
           * arriving meanwhile is dropped: we are already on our way out. */
          if (pending)
            SvREFCNT_dec (CORO_THROW);
          else
            pending = CORO_THROW;

          CORO_THROW = 0;

          if (j)
            {
              X_LOCK (offload_m);
              j->cancel = 1;    /* advisory; only effective if work () polls */
              X_UNLOCK (offload_m);
            }
          else
            break;              /* no job to wait for: nothing to protect */
        }
    }

  LEAVE;

  if (pending)
    {
      sv_setsv (ERRSV, pending);
      SvREFCNT_dec (pending);
      croak (0);
    }
}

static IV offload_handle_stop (pTHX_ SV *hsv, int dropped);

/* The flag half of cancellation, for $handle->safe_cancel: raise the flag that
 * `work` polls and return, so that nothing blocks and the handle resolves when the
 * work stops of its own accord.
 *
 * Except in an atomic section.  There the caller cannot suspend, so it has no way
 * to wait for the awaitable safe_cancel hands back - and an offload that stays
 * pending for the rest of the section is worse than one that is simply stopped.  So
 * the prompt path is taken instead: stop the work, wait for it, and hand back the
 * completion for the perl half to resolve with.  Same trade the rest of this
 * backend makes, and for the same reason - atomicity is a correctness guarantee,
 * while doing the cleanup asynchronously is an optimisation.
 *
 * Returns the completion when it went that way, 0 when it only raised the flag, and
 * -1 when there was no job left to ask. */
static IV
offload_handle_cancel (pTHX_ SV *hsv)
{
  HV *hv = offload_handle_hv (aTHX_ hsv);
  struct offload_job *j = offload_handle_job (aTHX_ hv);

  if (!j)
    return -1;

  if (CORO_ATOMIC)
    return offload_handle_stop (aTHX_ hsv, 0);

  X_LOCK (offload_m);
  j->cancel = 1;
  X_UNLOCK (offload_m);

  return 0;
}

/* the handle's destructor, when it is still pending, and $handle->cancel: see
 * offload_stop_and_take ().  Both return the completion the perl half must still
 * run, or 0 if there was no job left to stop. */
static IV
offload_handle_stop (pTHX_ SV *hsv, int dropped)
{
  HV *hv = offload_handle_hv (aTHX_ hsv);
  struct offload_job *j = offload_handle_job (aTHX_ hv);

  if (!j)
    return 0;

  (void)hv_delete (hv, "job", 3, G_DISCARD);

  return PTR2IV (offload_stop_and_take (aTHX_ j, dropped));
}

/* Run the module's done () and hand over what it produced.  Called from the perl
 * half inside an eval, so that a croak from done () becomes the handle's failure
 * instead of an exception at a point of the program's execution that has nothing
 * to do with the offloaded call.
 *
 * The completion is freed before done () is called, since done () may not return. */
static SV *
offload_run_completion (pTHX_ SV *cptr)
{
  struct offload_completion *c = INT2PTR (struct offload_completion *, SvIV (cptr));
  perl_multicore_done_t done = c->done;
  void *done_arg = c->done_arg;
  perl_multicore_done_ctx done_ctx;

  OFFLOAD_DONE_CTX_INIT (done_ctx, c->cancelled, c->dropped);
  Safefree (c);

  return done (aTHX_ done_arg, &done_ctx);
}

/* On the interpreter thread (from poll (), after draining the wakeup pipe): for
 * each job the workers have finished, run done () and resolve its handle - which
 * readies whoever is waiting on it.
 *
 * The slot goes back to the free list, and the job's coro reference is dropped,
 * BEFORE done () runs: done () may croak, which is a module's sanctioned way of
 * reporting failure, and neither the slot nor the reference may depend on it
 * returning.  Everything done () needs is copied into the completion first, so the
 * job is finished with by the time it is called. */
static void
offload_run_done (pTHX)
{
  struct offload_job *j;

  X_LOCK (offload_m);
  j = offload_done;
  offload_done = 0;
  X_UNLOCK (offload_m);

  while (j)
    {
      struct offload_job *next = j->next;
      perl_multicore_done_t done = j->done;
      void *done_arg = j->done_arg;
      int cancelled = j->cancel ? 1 : 0;
      HV *hv = j->hv;
      SV *coro = (SV *)j->coro;
      int abandoned = j->state == OJ_ABANDONED;

      j->hv = 0;
      j->coro = 0;

      X_LOCK (offload_m);
      j->next = offload_free;
      offload_free = j;
      X_UNLOCK (offload_m);

      if (coro)
        SvREFCNT_dec_NN (coro);

      /* the handle was dropped while we were working, so there is nothing to
       * resolve and nobody to hand a value to: do not run done () at all. */
      if (!abandoned && hv)
        {
          (void)hv_delete (hv, "job", 3, G_DISCARD);
          offload_complete (aTHX_ hv, done, done_arg, cancelled);
        }

      j = next;
    }
}

/* install/remove the offload backend (called from the _offload_register XSUB) */
static void
offload_register (pTHX_ int on)
{
  multicore_register_offload (on ? pmapi_offload : 0);
}

/* Test-only consumer, exercising one full offload round trip and reporting what
 * the backend handed over.  There is no other offload consumer in this dist
 * (Coro::Multicore::sleep uses the release/acquire bracket), so without this the
 * context contract would be unverified until an external module adopted it. */
struct offload_selftest
{
  int work_ran, work_ctx_ok, work_cancel_ok;
  int done_ctx_ok, done_cancelled;
};

static void
offload_selftest_work (void *arg, const perl_multicore_work_ctx *ctx)
{
  struct offload_selftest *st = arg;

  st->work_ran         = 1;
  st->work_ctx_ok      = ctx && ctx->size >= sizeof (*ctx);
  /* a cancellation flag is supplied, and starts out clear */
  st->work_cancel_ok   = ctx && ctx->cancel && !*ctx->cancel;
}

static SV *
offload_selftest_done (pTHX_ void *arg, const perl_multicore_done_ctx *ctx)
{
  struct offload_selftest *st = arg;

  st->done_ctx_ok    = ctx && ctx->size >= sizeof (*ctx);
  st->done_cancelled = ctx ? ctx->cancelled : -1;

  /* NOT mortal: done () hands over a reference, and the SV * RETVAL typemap in the
   * consuming XSUB mortalises it (xsubpp emits sv_2mortal there).  Returning a
   * mortal here would mortalise it twice. */
  return newSVpvf ("work_ran=%d work_ctx_ok=%d cancel_ok=%d done_ctx_ok=%d cancelled=%d",
                   st->work_ran, st->work_ctx_ok, st->work_cancel_ok,
                   st->done_ctx_ok, st->done_cancelled);
}

static SV *
offload_selftest (pTHX)
{
  struct offload_selftest st = { 0, 0, 0, 0, -1 };

  return multicore_offload_sync (offload_selftest_work, &st,
                                 offload_selftest_done, &st);
}

/* Test-only: an offload whose done () croaks.  Croaking from done () is the
 * sanctioned way for a module to report failure, so the slot must survive it. */
static void
offload_selftest_nowork (void *arg, const perl_multicore_work_ctx *ctx)
{
  PERL_UNUSED_ARG (arg);
  PERL_UNUSED_ARG (ctx);
}

static SV *
offload_selftest_croak_done (pTHX_ void *arg, const perl_multicore_done_ctx *ctx)
{
  PERL_UNUSED_ARG (arg);
  PERL_UNUSED_ARG (ctx);
  croak ("offload selftest: deliberate croak from done ()");
}

static SV *
offload_selftest_croak (pTHX)
{
  return multicore_offload_sync (offload_selftest_nowork, 0,
                                 offload_selftest_croak_done, 0);
}

/* Test-only: an offload whose work () sleeps, so an exception can be delivered
 * while the caller is suspended at the offload wait. */
static int offload_selftest_usec;

static void
offload_selftest_slowwork (void *arg, const perl_multicore_work_ctx *ctx)
{
  PERL_UNUSED_ARG (arg);
  PERL_UNUSED_ARG (ctx);
  usleep (offload_selftest_usec);
}

/* its own done (): the selftest one dereferences its arg, and there is nothing
 * meaningful to pass here.  Reports only whether the work was cancelled. */
static SV *
offload_selftest_slow_done (pTHX_ void *arg, const perl_multicore_done_ctx *ctx)
{
  PERL_UNUSED_ARG (arg);
  return newSViv (ctx && ctx->cancelled ? 1 : 0);   /* hands over a reference */
}

static SV *
offload_selftest_slow (pTHX_ int usec)
{
  offload_selftest_usec = usec;
  return multicore_offload_sync (offload_selftest_slowwork, 0,
                                 offload_selftest_slow_done, 0);
}

/* Ask an in-flight offload issued by $coro to stop, WITHOUT disturbing $coro
 * itself: it stays suspended in its wait, work () returns early if it polls, and
 * done () then runs with done_ctx.cancelled set, so the call returns a partial
 * result rather than raising.  That is the difference from throwing at or
 * cancelling the thread, both of which unwind it and so never reach done ().
 *
 * Jobs on the free list cannot match: coro is cleared when a job is released or
 * abandoned, so the identity test is the real guard. */
static int
offload_cancel_for (pTHX_ SV *coro)
{
  int found = 0, i;

  X_LOCK (offload_m);

  for (i = 0; i < OFFLOAD_SLOTS; ++i)
    {
      struct offload_job *j = &offload_slots[i];

      if (j->state == OJ_INFLIGHT && j->coro == (void *)coro)
        {
          j->cancel = 1;
          found = 1;
        }
    }

  X_UNLOCK (offload_m);

  return found;
}

/* Test-only: a work () that polls the cancellation flag between chunks, which is
 * the contract Coro::Multicore asks of a cancellable offload.  Records how many
 * chunks it got through, so a test can see it stopped early. */
static int offload_selftest_chunks_done;
#define OFFLOAD_SELFTEST_CHUNKS 100

static void
offload_selftest_cancelwork (void *arg, const perl_multicore_work_ctx *ctx)
{
  int i;

  PERL_UNUSED_ARG (arg);

  for (i = 0; i < OFFLOAD_SELFTEST_CHUNKS; ++i)
    {
      if (ctx && ctx->size >= sizeof (*ctx) && ctx->cancel && *ctx->cancel)
        break;

      usleep (10000);   /* 10ms a chunk, so a whole run takes about a second */
    }

  offload_selftest_chunks_done = i;
}

static SV *
offload_selftest_cancellable (pTHX)
{
  offload_selftest_chunks_done = -1;
  return multicore_offload_sync (offload_selftest_cancelwork, 0,
                                    offload_selftest_slow_done, 0);
}

static int
offload_selftest_chunks (pTHX)
{
  return offload_selftest_chunks_done;
}

/* Test-only: the OTHER half of the contract - an entry point that returns the
 * handle instead of consuming it, which is what a module offering an asynchronous
 * method does.  Nothing waits before this returns, so the job may not live on this
 * frame: it is heap-allocated and released by done (), by when the work is over
 * and nothing else refers to it.  Its `work` sleeps, so a test can see the handle
 * come back pending and several be in flight at once. */
struct offload_selftest_async
{
  int usec;
  int chunks;
};

static void
offload_selftest_asyncwork (void *arg, const perl_multicore_work_ctx *ctx)
{
  struct offload_selftest_async *a = arg;
  int i;

  for (i = 0; i < 10; ++i)
    {
      if (ctx && ctx->size >= sizeof (*ctx) && ctx->cancel && *ctx->cancel)
        break;

      usleep (a->usec / 10);
    }

  a->chunks = i;
}

/* how many times the async selftest's done () has run, so a test can check that it
 * runs exactly once - including when the handle was dropped, which is the only
 * thing that frees the heap job on that path */
static int offload_selftest_async_dones;

static SV *
offload_selftest_async_done (pTHX_ void *arg, const perl_multicore_done_ctx *ctx)
{
  struct offload_selftest_async *a = arg;
  int have_ctx = ctx && ctx->size >= sizeof (*ctx);
  SV *result = newSVpvf ("chunks=%d cancelled=%d dropped=%d", a->chunks,
                         have_ctx && ctx->cancelled ? 1 : 0,
                         have_ctx && ctx->dropped ? 1 : 0);

  ++offload_selftest_async_dones;
  free (a);       /* the job was ours to free: see above */

  return result;
}

static int
offload_selftest_async_done_count (pTHX)
{
  return offload_selftest_async_dones;
}

static SV *
offload_selftest_async (pTHX_ int usec)
{
  struct offload_selftest_async *a = malloc (sizeof (*a));

  if (!a)
    croak ("Coro::Multicore: out of memory");

  a->usec   = usec;
  a->chunks = -1;

  return multicore_offload (offload_selftest_asyncwork, a,
                            offload_selftest_async_done, a);
}

/* Test-only: how many job slots are on the free list.  Used to assert that no
 * path loses one.  Zero until the pool is first built (on first offload). */
static int
offload_abandon_count (pTHX)
{
  return offload_abandons;
}

/* Test-only: of those, how many had to wait for a work () that was still running. */
static int
offload_abandon_wait_count (pTHX)
{
  return offload_abandon_waits;
}

static int
offload_free_slots (pTHX)
{
  struct offload_job *j;
  int n = 0;

  X_LOCK (offload_m);
  for (j = offload_free; j; j = j->next)
    ++n;
  X_UNLOCK (offload_m);

  return n;
}

# define OFFLOAD_SUPPORTED 1

#else /* !HAVE_MULTICORE_OFFLOAD -- offload compiled out; provide no-op stubs so
       * the XSUB CODE blocks below carry no #ifdef (which confuses xsubpp). */

# define OFFLOAD_SUPPORTED 0
static void
offload_run_done (pTHX)
{
  PERL_UNUSED_CONTEXT;
}

static void
offload_register (pTHX_ int on)
{
  PERL_UNUSED_ARG (on);
  croak ("Coro::Multicore: offload backend not available (this perl lacks the core multicore_offload hook)");
}

static SV *
offload_selftest (pTHX)
{
  croak ("Coro::Multicore: offload backend not available (this perl lacks the core multicore_offload hook)");
}

static SV *
offload_selftest_croak (pTHX)
{
  croak ("Coro::Multicore: offload backend not available");
}

static SV *
offload_selftest_slow (pTHX_ int usec)
{
  PERL_UNUSED_ARG (usec);
  croak ("Coro::Multicore: offload backend not available");
}

static int
offload_free_slots (pTHX)
{
  return 0;
}

static int
offload_abandon_count (pTHX)
{
  return 0;
}

static int
offload_abandon_wait_count (pTHX)
{
  return 0;
}

static SV *
offload_selftest_cancellable (pTHX)
{
  croak ("Coro::Multicore: offload backend not available");
}

static SV *
offload_selftest_async (pTHX_ int usec)
{
  PERL_UNUSED_ARG (usec);
  croak ("Coro::Multicore: offload backend not available");
}

static int
offload_selftest_async_done_count (pTHX)
{
  return 0;
}

static int
offload_selftest_chunks (pTHX)
{
  return -1;
}

static int
offload_cancel_for (pTHX_ SV *coro)
{
  PERL_UNUSED_ARG (coro);
  croak ("Coro::Multicore: offload backend not available (this perl lacks the core multicore_offload hook)");
}

static void
offload_wait (pTHX_ SV *hsv)
{
  PERL_UNUSED_ARG (hsv);
  croak ("Coro::Multicore: offload backend not available");
}

static IV
offload_handle_cancel (pTHX_ SV *hsv)
{
  PERL_UNUSED_ARG (hsv);
  croak ("Coro::Multicore: offload backend not available");
}

static IV
offload_handle_stop (pTHX_ SV *hsv, int dropped)
{
  PERL_UNUSED_ARG (hsv);
  PERL_UNUSED_ARG (dropped);
  return 0;
}

static SV *
offload_run_completion (pTHX_ SV *cptr)
{
  PERL_UNUSED_ARG (cptr);
  croak ("Coro::Multicore: offload backend not available");
}

#endif /* HAVE_MULTICORE_OFFLOAD */

MODULE = Coro::Multicore		PACKAGE = Coro::Multicore

PROTOTYPES: DISABLE

BOOT:
{
#ifndef _WIN32
	sigfillset (&fullsigset);
#endif

        X_TLS_INIT (current_key);
#if RECURSION_CHECK
        X_TLS_INIT (check_key);
#endif

        if (s_epipe_new (&ep))
          croak ("Coro::Multicore: unable to initialise event pipe.\n");

        pthread_atfork (0, 0, atfork_child);

        perl_thx = PERL_GET_CONTEXT;

	I_CORO_API ("Coro::Multicore");

        /* Which libcoro backend Coro was built with decides whether releasing the
         * interpreter is possible at all.  The bracket parks the calling thread's
         * machine context and lets another thread resume it; a Windows fiber
         * forbids exactly that - only the thread that last ran a fiber may switch
         * to it - so handing one to a worker is undefined behaviour rather than
         * merely slow.  Ask Coro (an undocumented constant, but the only report
         * there is), and if the answer is a backend like that, run the bracket
         * inline instead and say so once: silently declining to parallelise is
         * kinder than corrupting, but neither is worth being quiet about.
         *
         * The offload backend is unaffected and stays available - it never moves
         * the interpreter, which is the whole point of it. */
        {
          dSP;

          ENTER;
          SAVETMPS;
          PUSHMARK (SP);
          PUTBACK;

          if (call_pv ("Coro::State::BACKEND", G_SCALAR | G_EVAL) == 1)
            {
              SV *sv;

              SPAGAIN;
              sv = POPs;
              PUTBACK;

              if (!SvTRUE (ERRSV) && SvOK (sv))
                {
                  const char *b = SvPV_nolen (sv);

                  backend_migrates = !(strEQ (b, "fiber") || strEQ (b, "loser"));

                  if (!backend_migrates)
                    warn ("Coro::Multicore: Coro's \"%s\" backend cannot resume a "
                          "parked context on another thread, so release/acquire "
                          "will run inline - rebuild Coro with CORO_INTERFACE=a "
                          "for real multicore (offload is unaffected)", b);
                }
            }

          FREETMPS;
          LEAVE;
        }

        if (0) { /*D*/
        X_LOCK (release_m);
        while (idle < max_idle)
          start_thread ();
        X_UNLOCK (release_m);
        }

        /* not perfectly efficient to do it this way, but it is simple */
	perl_multicore_init (); /* calls release */
        perl_multicore_api->pmapi_release = pmapi_release;
        perl_multicore_api->pmapi_acquire = pmapi_acquire;
}

# Test-only: what BOOT decided about Coro's backend (see t/04_backend.t).
bool
_backend_migrates ()
	CODE:
        RETVAL = backend_migrates;
	OUTPUT:
        RETVAL

bool
enable (bool enable = NO_INIT)
	CODE:
        RETVAL = global_enable;
        if (items)
          global_enable = enable;
        OUTPUT:
        RETVAL

void
scoped_enable ()
	CODE:
        LEAVE; /* see Guard.xs */
        CORO_ENTERLEAVE_SCOPE_HOOK (set_thread_enable, (void *)1, set_thread_enable, (void *)0);
        ENTER; /* see Guard.xs */

void
scoped_disable ()
	CODE:
        LEAVE; /* see Guard.xs */
        CORO_ENTERLEAVE_SCOPE_HOOK (set_thread_enable, (void *)2, set_thread_enable, (void *)0);
        ENTER; /* see Guard.xs */

U32
max_idle (U32 n = NO_INIT)
	CODE:
        X_LOCK (release_m);
        RETVAL = max_idle;
        if (items)
          max_idle = n;
        X_UNLOCK (release_m);
        OUTPUT:
        RETVAL

U32
idle_timeout (U32 seconds = NO_INIT)
	CODE:
        X_LOCK (release_m);
        RETVAL = idle_timeout;
        if (items)
          idle_timeout = seconds;
        X_UNLOCK (release_m);
        OUTPUT:
        RETVAL

int
fd ()
	CODE:
        RETVAL = s_epipe_fd (&ep);
	OUTPUT:
        RETVAL

void
poll (...)
	CODE:
        s_epipe_drain (&ep);
	X_LOCK (acquire_m);
        while (acquirers.cur)
          {
            struct tctx *ctx = tctxs_get (&acquirers);
            CORO_READY ((SV *)ctx->coro);
            SvREFCNT_dec_simple_void_NN ((SV *)ctx->coro);
            ctx->coro = 0;
          }
	X_UNLOCK (acquire_m);
        offload_run_done (aTHX); /* run completed offload jobs' done() here (nop if offload not built) */

SV *
_offload_selftest ()
	CODE:
        RETVAL = offload_selftest (aTHX);
	OUTPUT:
        RETVAL

SV *
_offload_selftest_croak ()
	CODE:
        RETVAL = offload_selftest_croak (aTHX);
	OUTPUT:
        RETVAL

SV *
_offload_selftest_slow (int usec)
	CODE:
        RETVAL = offload_selftest_slow (aTHX_ usec);
	OUTPUT:
        RETVAL

int
_offload_free_slots ()
	CODE:
        RETVAL = offload_free_slots (aTHX);
	OUTPUT:
        RETVAL

int
_offload_abandons ()
	CODE:
        RETVAL = offload_abandon_count (aTHX);
	OUTPUT:
        RETVAL

int
_offload_abandon_waits ()
	CODE:
        RETVAL = offload_abandon_wait_count (aTHX);
	OUTPUT:
        RETVAL

SV *
_offload_selftest_cancellable ()
	CODE:
        RETVAL = offload_selftest_cancellable (aTHX);
	OUTPUT:
        RETVAL

int
_offload_chunks_done ()
	CODE:
        RETVAL = offload_selftest_chunks (aTHX);
	OUTPUT:
        RETVAL

SV *
_offload_selftest_async (int usec)
	CODE:
        RETVAL = offload_selftest_async (aTHX_ usec);
	OUTPUT:
        RETVAL

int
_offload_async_dones ()
	CODE:
        RETVAL = offload_selftest_async_done_count (aTHX);
	OUTPUT:
        RETVAL

bool
cancel_offload (SV *coro)
	CODE:
        if (!SvROK (coro))
          croak ("Coro::Multicore::cancel_offload: not a Coro thread");
        RETVAL = offload_cancel_for (aTHX_ SvRV (coro));
	OUTPUT:
        RETVAL

bool
_offload_supported ()
	CODE:
        RETVAL = OFFLOAD_SUPPORTED;
        OUTPUT:
        RETVAL

 # The job half of Coro::Multicore::Offload::Awaitable (see there): everything
 # that needs the in-flight job rather than the handle's own state.

void
_offload_wait (SV *handle)
	CODE:
        offload_wait (aTHX_ handle);

 # the flag half, for safe_cancel: see offload_handle_cancel () for what the
 # return value means, and why an atomic section is answered differently
IV
_offload_cancel (SV *handle)
	CODE:
        RETVAL = offload_handle_cancel (aTHX_ handle);
	OUTPUT:
        RETVAL

 # dropped: nobody will collect the result.  Used by the handle's destructor.
IV
_offload_abandon (SV *handle)
	CODE:
        RETVAL = offload_handle_stop (aTHX_ handle, 1);
	OUTPUT:
        RETVAL

 # $handle->cancel: stop the work and BLOCK until it has stopped, so that the
 # offload is over when this returns.  The handle stays; its result is whatever
 # done () makes of the truncated work.
IV
_offload_cancel_wait (SV *handle)
	CODE:
        RETVAL = offload_handle_stop (aTHX_ handle, 0);
	OUTPUT:
        RETVAL

SV *
_offload_run_done (SV *completion)
	CODE:
        RETVAL = offload_run_completion (aTHX_ completion);
	OUTPUT:
        RETVAL

void
_offload_register (bool on)
	CODE:
        offload_register (aTHX_ on);

void
sleep (NV seconds)
	CODE:
        perlinterp_release ();
	{
          int sec  = seconds > 0 ? (int)seconds : 0;
          int usec;

          if (sec) sleep (sec);

          /* usleep () takes MICROseconds - POSIX only defines it for values
           * below one second, which holds here by construction since the whole
           * seconds have just been slept off above. */
          usec = (seconds - sec) * 1e6;
          if (usec > 0) usleep (usec);
        }
        perlinterp_acquire ();

