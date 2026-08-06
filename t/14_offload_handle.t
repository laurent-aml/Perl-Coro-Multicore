#!perl
# What the backend's own handle does, over a real job.
#
# multicore_offload () returns before the work is over, so the handle comes back
# PENDING and the suspension that used to happen inside the call now happens in
# get ().  A consumer that asks for the value straight away therefore behaves
# exactly as an offloaded call always did (t/04-t/06 cover that, unchanged), and
# what this file covers is what the shape change buys and what it now has to
# promise: several offloads in flight from one coro, a handle waited on by
# someone other than its issuer, cancellation through the handle, and a pending
# handle that is simply dropped.

use strict;

use Test::More;

BEGIN { $ENV{PERL_ANYEVENT_MODEL} = "EV" }

use Coro;
use Coro::AnyEvent;
use Coro::Multicore;
use Time::HiRes ();

plan skip_all => "offload backend not built (this perl lacks the core multicore_offload hook)"
   unless Coro::Multicore::_offload_supported ();

plan tests => 39;

alarm 120;

Coro::Multicore::enable_offload (1);

# The async helper's work () runs 10 chunks, polling the cancel flag between
# them, and its done () reports how many it got through.  A tenth of a second
# altogether, so that "still pending" is observable.
my $USEC = 100_000;

async { Coro::Multicore::_offload_selftest () }->join;   # build the pool
my $slots = Coro::Multicore::_offload_free_slots ();
my $abandons = Coro::Multicore::_offload_abandons ();

# --- the shape --------------------------------------------------------------
{
   async {
      my $h = Coro::Multicore::_offload_selftest_async ($USEC);

      isa_ok $h, "Coro::Multicore::Offload::Awaitable", "multicore_offload returns";
      ok !$h->AWAIT_IS_READY, "the handle comes back pending: the call did not wait";
      is Coro::Multicore::_offload_free_slots (), $slots - 1,
         "and a job slot is in flight while it is";

      my $r = $h->get;

      is $r, "chunks=10 cancelled=0 dropped=0", "get () waits and yields done ()'s value";
      ok $h->AWAIT_IS_READY, "the handle is resolved afterwards";
      is scalar $h->get, $r, "get () again returns the same value without waiting";
      is scalar $h->AWAIT_GET, $r, "and so does AWAIT_GET";
   }->join;

   is Coro::Multicore::_offload_free_slots (), $slots, "slot returned";
}

# --- what the handle buys: N in flight from ONE coro ------------------------
# Without a handle this needs a coro per job, because the call itself blocked.
{
   async {
      my $t0 = Time::HiRes::time ();
      my @h  = map { Coro::Multicore::_offload_selftest_async ($USEC) } 1 .. 4;

      is Coro::Multicore::_offload_free_slots (), $slots - 4,
         "four offloads in flight, issued from one coro";

      my @r = map { $_->get } @h;
      my $elapsed = Time::HiRes::time () - $t0;

      is_deeply [ @r ], [ ("chunks=10 cancelled=0 dropped=0") x 4 ], "all four completed";
      cmp_ok $elapsed, "<", 4 * $USEC / 1e6 * 0.9,
         "and ran concurrently, not one after another";
   }->join;

   is Coro::Multicore::_offload_free_slots (), $slots, "all slots returned";
}

# --- someone other than the issuer waits ------------------------------------
# The handle is an object like any other: whoever holds it can collect it, which
# is what makes it worth returning from a module's entry point.
{
   my ($h, $r);

   async { $h = Coro::Multicore::_offload_selftest_async ($USEC) }->join;

   ok !$h->AWAIT_IS_READY, "the issuing coro is gone and the offload is still running";

   async { $r = $h->get }->join;

   is $r, "chunks=10 cancelled=0 dropped=0", "a different coro collected it";
   is Coro::Multicore::_offload_free_slots (), $slots, "slot returned";
}

# --- prompt cancellation ----------------------------------------------------
# cancel () is prompt: it blocks the interpreter until the work has actually
# stopped, so that the offload is over by the time it returns.  Advisory all the
# same - the work stops when it next polls, and one that never polls is waited out.
{
   my ($r, $blocked);

   async {
      my $h = Coro::Multicore::_offload_selftest_async (1_000_000);   # 1s if left alone

      Coro::AnyEvent::sleep 0.05;

      my $t0 = Time::HiRes::time ();
      $h->cancel;
      $blocked = Time::HiRes::time () - $t0;

      ok $h->AWAIT_IS_CANCELLED, "cancel () marks the handle cancelled";
      ok $h->AWAIT_IS_READY,
         "and blocks until the work has stopped, so the offload is over when it returns";

      $r = $h->get;
   }->join;

   cmp_ok $blocked, '>', 0, "it really waited";
   cmp_ok $blocked, '<', 0.8, "but only for the poll, not for the whole run";
   like $r, qr/\bcancelled=1\b/, "done () was told the work was cancelled";
   like $r, qr/\bchunks=[0-9]\b/, "and it stopped before the last chunk";
   is Coro::Multicore::_offload_free_slots (), $slots, "slot returned";
}

# --- asynchronous cancellation ----------------------------------------------
# safe_cancel () is the other half of the pair: it raises the same flag but does
# NOT block.  It hands back an awaitable that completes once the work has stopped,
# so the event loop and the other Coro threads keep running while it does.
{
   my ($ready_on_return, $ticks, $r) = (undef, 0);

   async {
      my $h = Coro::Multicore::_offload_selftest_async (1_000_000);

      Coro::AnyEvent::sleep 0.05;

      my $cleanup = $h->safe_cancel;

      $ready_on_return = $h->AWAIT_IS_READY;

      my $ticker = async { until ($h->AWAIT_IS_READY) { $ticks++; Coro::AnyEvent::sleep 0.005 } };

      $cleanup->get;                       # waits for the cleanup, does not block

      ok $h->AWAIT_IS_READY, "the handle has resolved once the cleanup is done";
      ok $h->AWAIT_IS_CANCELLED, "and reports itself cancelled";

      $r = $h->get;
      $ticker->join;
   }->join;

   ok !$ready_on_return, "safe_cancel () returns before the work has stopped";
   cmp_ok $ticks, '>', 0, "another coro ran while it was stopping";
   like $r, qr/\bcancelled=1\b/, "and done () was told the work was cancelled";
   is Coro::Multicore::_offload_free_slots (), $slots, "slot returned";
}

# --- the safe-cancel chain --------------------------------------------------
# The shape Future::AsyncAwait uses: the future an async sub returns is a CLONE of
# the thing it awaited, with the awaited thing chained to it.  Safe-cancelling the
# clone must tear the child down and - the ordering the protocol requires - become
# cancelled itself BEFORE the child does, so that a frame resumed by the child sees
# its own future already cancelled.
{
   my (@order, $cleanup_ready);

   async {
      my $child  = Coro::Multicore::_offload_selftest_async (1_000_000);
      my $parent = $child->AWAIT_CLONE;

      $parent->AWAIT_CHAIN_SAFE_CANCEL ($child);

      $parent->AWAIT_ON_READY (sub { push @order, "parent" });
      $child->AWAIT_ON_READY  (sub { push @order, "child" });

      my $cleanup = $parent->safe_cancel;

      $cleanup->get;
      $cleanup_ready = $cleanup->AWAIT_IS_READY ? 1 : 0;
   }->join;

   ok $cleanup_ready, "safe-cancelling the parent completes when the child has stopped";
   is_deeply \@order, [ "parent", "child" ],
      "and the parent is cancelled before the child, as the protocol requires";
   is Coro::Multicore::_offload_free_slots (), $slots, "slot returned";
}

# --- a pending handle nobody collects ---------------------------------------
# Dropping it is the caller saying it wants neither the value nor the work.  The
# work still owns whatever it was given, so the handle's destructor asks it to
# stop and waits: this is where the abandon-and-wait that used to hang off the
# suspend point now lives.
{
   my $dones = Coro::Multicore::_offload_async_dones ();

   async {
      my $h = Coro::Multicore::_offload_selftest_async (10_000_000);
      undef $h;   # here
   }->join;

   is Coro::Multicore::_offload_abandons (), $abandons + 1,
      "dropping a pending handle abandons the job";
   is Coro::Multicore::_offload_free_slots (), $slots, "and the slot comes back";

   # done () still runs, with dropped set: it is the only thing that can free a job
   # a module allocated on the heap in order to return the handle upward.
   is Coro::Multicore::_offload_async_dones (), $dones + 1,
      "done () ran even though nobody was waiting for the value";
}

# --- an atomic section still runs inline ------------------------------------
# Suspending is forbidden there, so the work runs on this thread and the handle
# is resolved before it is ever seen - which a consumer cannot distinguish.
SKIP: {
   eval { require Coro::Atomic; 1 } or skip "this Coro has no Coro::Atomic", 5;

   async {
      # called rather than written as a block, since the block form has to be
      # imported before this file is compiled and the module may not be there
      Coro::Atomic::atomic (sub {
         my $h = Coro::Multicore::_offload_selftest_async (10_000);

         ok $h->AWAIT_IS_READY, "inside an atomic section the handle comes back resolved";
         like scalar $h->get, qr/\bchunks=10\b/, "with the work done inline";
      });
   }->join;

   # An offload issued outside a section but cancelled inside one: safe_cancel
   # cannot hand back something to wait for, since waiting means suspending and
   # that is what the section forbids.  So it does what cancel does instead.
   async {
      my $h = Coro::Multicore::_offload_selftest_async (2_000_000);

      Coro::AnyEvent::sleep 0.02;                 # let the work start

      Coro::Atomic::atomic (sub {
         my $cleanup = $h->safe_cancel;

         ok $h->AWAIT_IS_READY,
            "safe_cancel inside an atomic section blocks, as cancel does";
         ok $cleanup->AWAIT_IS_READY,
            "and the cleanup it hands back is already complete";
         ok eval { $cleanup->get; 1 },
            "so waiting for it is a no-op rather than a deadlock";
      });
   }->join;
}
