=encoding utf8

=head1 NAME

Coro::Multicore - make coro threads on multiple cores with specially supported modules

=head1 SYNOPSIS

 # when you DO control the main event loop, e.g. in the main program

 use Coro::Multicore; # enable by default

 Coro::Multicore::scoped_disable;
 AE::cv->recv; # or EV::run, AnyEvent::Loop::run, Event::loop, ...

 # when you DO NOT control the event loop, e.g. in a module on CPAN
 # do nothing (see HOW TO USE IT) or something like this:

 use Coro::Multicore (); # disable by default

 async {
    Coro::Multicore::scoped_enable;

    # blocking is safe in your own threads
    ...
 };

=head1 DESCRIPTION

While L<Coro> threads (unlike ithreads) provide real threads similar to
pthreads, python threads and so on, they do not run in parallel to each
other even on machines with multiple CPUs or multiple CPU cores.

This module lifts this restriction under two very specific but useful
conditions: firstly, the coro thread executes in XS code and does not
touch any perl data structures, and secondly, the XS code is specially
prepared to allow this.

This means that, when you call an XS function of a module prepared for it,
this XS function can execute in parallel to any other Coro threads. This
is useful for both CPU bound tasks (such as cryptography) as well as I/O
bound tasks (such as loading an image from disk). It can also be used
to do stuff in parallel via APIs that were not meant for this, such as
database accesses via DBI.

The mechanism to support this is easily added to existing modules
and is independent of L<Coro> or L<Coro::Multicore>, and therefore
could be used, without changes, with other, similar, modules, or even
the perl core, should it gain real thread support anytime soon. See
L<http://perlmulticore.schmorp.de/> for more info on how to prepare a
module to allow parallel execution. Preparing an existing module is easy,
doesn't add much overhead and no dependencies.

This module is an L<AnyEvent> user (and also, if not obvious, uses
L<Coro>).

=head1 HOW TO USE IT

Quick explanation: decide whether you control the main program/the event
loop and choose one of the two styles from the SYNOPSIS.

Longer explanation: There are two major modes this module can used in -
supported operations run asynchronously either by default, or only when
requested. The reason you might not want to enable this module for all
operations by default is compatibility with existing code:

Since this module integrates into an event loop and you must not normally
block and wait for something in an event loop callbacks. Now imagine
somebody patches your favourite module (e.g. Digest::MD5) to take
advantage of of the Perl Multicore API.

Then code that runs in an event loop callback and executes
Digest::MD5::md5 would work fine without C<Coro::Multicore> - it would
simply calculate the MD5 digest and block execution of anything else. But
with C<Coro::Multicore> enabled, the same operation would try to run other
threads. And when those wait for events, there is no event loop anymore,
as the event loop thread is busy doing the MD5 calculation, leading to a
deadlock.

=head2 USE IT IN THE MAIN PROGRAM

One way to avoid this is to not run perlmulticore enabled functions
in any callbacks. A simpler way to ensure it works is to disable
C<Coro::Multicore> thread switching in event loop callbacks, and enable it
everywhere else.

Therefore, if you control the event loop, as is usually the case when
you write I<program> and not a I<module>, then you can enable C<Coro::Multicore>
by default, and disable it in your event loop thread:

   # example 1, separate thread for event loop

   use EV;
   use Coro;
   use Coro::Multicore;

   async {
      Coro::Multicore::scoped_disable;
      EV::run;
   };

   # do something else

   # example 2, run event loop as main program

   use EV;
   use Coro;
   use Coro::Multicore;

   Coro::Multicore::scoped_disable;

   ... initialisation

   EV::run;

The latter form is usually better and more idiomatic - the main thread is
the best place to run the event loop.

Often you want to do some initialisation before running the event
loop. The most efficient way to do that is to put your intialisation code
(and main program) into its own thread and run the event loop in your main
program:

   use AnyEvent::Loop;
   use Coro::Multicore; # enable by default

   async {
      load_data;
      do_other_init;
      bind_socket;
      ...
   };

   Coro::Multicore::scoped_disable;
   AnyEvent::Loop::run;

This has the effect of running the event loop first, so the initialisation
code can block if it wants to.

If this is too cumbersome but you still want to make sure you can
call blocking functions before entering the event loop, you can keep
C<Coro::Multicore> disabled till you cna run the event loop:

   use AnyEvent::Loop;
   use Coro::Multicore (); # disable by default

   load_data;
   do_other_init;
   bind_socket;
   ...

   Coro::Multicore::scoped_disable; # disable for event loop
   Coro::Multicore::enable 1; # enable for the rest of the program
   AnyEvent::Loop::run;

=head2 USE IT IN A MODULE

When you I<do not> control the event loop, for example, because you want
to use this from a module you published on CPAN, then the previous method
doesn't work.

However, this is not normally a problem in practise - most modules only
do work at request of the caller. In that case, you might not care
whether it does block other threads or not, as this would be the callers
responsibility (or decision), and by extension, a decision for the main
program.

So unless you use XS and want your XS functions to run asynchronously,
you don't have to worry about C<Coro::Multicore> at all - if you
happen to call XS functions that are multicore-enabled and your
caller has configured things correctly, they will automatically run
asynchronously. Or in other words: nothing needs to be done at all, which
also means that this method works fine for existing pure-perl modules,
without having to change them at all.

Only if your module runs it's own L<Coro> threads could it be an
issue - maybe your module implements some kind of job pool and relies
on certain operations to run asynchronously. Then you can still use
C<Coro::Multicore> by not enabling it be default and only enabling it in
your own threads:

   use Coro;
   use Coro::Multicore (); # note the () to disable by default

   async {
      Coro::Multicore::scoped_enable;

      # do things asynchronously by calling perlmulticore-enabled functions
   };

=head2 EXPORTS

This module does not (at the moment) export any symbols. It does, however,
export "behaviour" - if you use the default import, then Coro::Multicore
will be enabled for all threads and all callers in the whole program:

   use Coro::Multicore;

In a module where you don't control what else might be loaded and run, you
might want to be more conservative, and not import anything. This has the
effect of not enabling the functionality by default, so you have to enable
it per scope:

   use Coro::Multicore ();

   sub myfunc {
      Coro::Multicore::scoped_enable;

      # from here to the end of this function, and in any functions
      # called from this function, tasks will be executed asynchronously.
   }

=head1 API FUNCTIONS

=over 4

=item $previous = Coro::Multicore::enable [$enable]

This function enables (if C<$enable> is true) or disables (if C<$enable>
is false) the multicore functionality globally. By default, it is enabled.

This can be used to effectively disable this module's functionality by
default, and enable it only for selected threads or scopes, by calling
C<Coro::Multicore::scoped_enable>.

Note that this setting nonly affects the I<global default> - it will not
reflect whether multicore functionality is enabled for the current thread.

The function returns the previous value of the enable flag.

Enabling it does not by itself guarantee that anything is released. Releasing
the interpreter means parking this thread's machine context and letting another
thread resume it, and not every L<Coro> backend permits that: a Windows fiber may
only be switched to by the thread that last ran it. When Coro was built with such
a backend this module says so once, at load time, and runs the bracket inline
instead - correct, just not parallel. Rebuild Coro with C<CORO_INTERFACE=a> (the
handcoded assembler backend, which is the default on Windows x86/x86_64 built with
MinGW) to get the real thing. The I<offload> backend is unaffected either way,
since it never moves the interpreter.

=item Coro::Multicore::scoped_enable

This function instructs Coro::Multicore to handle all requests executed
in the current coro thread, from the call to the end of the current scope.

Calls to C<scoped_enable> and C<scoped_disable> don't nest very well at
the moment, so don't nest them.

=item Coro::Multicore::scoped_disable

The opposite of C<Coro::Multicore::scope_disable>: instructs Coro::Multicore to
I<not> handle the next multicore-enabled request.

=item Coro::Atomic as a stronger scoped_disable

A L<Coro::Atomic> section - C<atomic { ... }>, C<scoped_atomic>, or a
C<:Atomic> sub - also switches this module off for its duration, and is the
stronger of the two ways to do it.  Where C<scoped_disable> only asks this module
to leave the interpreter alone, an atomic section additionally forbids the
running coro thread to yield at all, so nothing else can interleave by any route
- an explicit C<cede>, a blocking C<< Coro::Semaphore->down >>, or a condvar wait
inside the region are fatal errors rather than silent switches.

Use C<scoped_disable> when you only want the work to stay on this thread, and an
atomic section when the region must actually run as one indivisible step.  The
latter also nests, which C<scoped_disable> does not.

Note that C<scoped_enable> does B<not> do what it says inside an atomic section.
The suppression is unconditional and deliberately wins over C<enable>,
C<scoped_enable> and C<scoped_disable> alike.  A C<scoped_enable> written inside
the region therefore has no effect at all: not within it, because the section
wins, and not after it either, since its own scope normally ends with the region
it was written in.  (One already in effect from an enclosing scope simply resumes
once the section ends.)  This is not an error - the call is simply inert, so do
not reach for it expecting to carve a parallel hole out of an atomic region.

See L</INTERACTION WITH OTHER SOFTWARE> for why, and for what becomes of the
multicore-enabled calls themselves.

=item $previous = Coro::Multicore::enable_offload [$enable]

Install (C<$enable> true, the default) or remove (false) the I<offload> backend
for the core C<multicore_offload> hook, returning the previous on/off state.
Unlike the default release/acquire backend - which migrates the interpreter to a
worker while the blocking call stays put on the caller's thread - offload keeps
the interpreter B<pinned> to its thread and runs the module's pure-C C<work> on a
pool of worker threads. Because the interpreter is never migrated, this works even
where release/acquire cannot: that one hands the interpreter to another native
thread, so it needs a perl that is not I<using> ithreads - which on Windows is
what the C<fork> emulation is built on, so there it wants a non-ithread build.
Offload does not care either way. The cost is that the XS module hands its C call
to the hook as a C<work>/C<done> pair.

C<multicore_offload> hands the module back a B<handle> (see
L</THE OFFLOAD HANDLE>) rather than a value, and this backend returns it while the
work is still running. What the module does with it decides how the call looks:
if it waits for the value - which the C<multicore_offload_sync> wrapper in
F<perlmulticore.h> does for it - the calling L<Coro> thread is suspended for the
duration and the call looks synchronous, exactly as a blocking one would, while
other Coro threads run meanwhile. If it returns the handle instead, from an
asynchronous entry point, the caller decides when to collect it - and may have
several offloads running from one Coro thread.

B<The whole offload backend is experimental> - not just this method: the
mechanism, its interaction with the event loop, and its API may all change or be
removed. It is B<off by default> (the default backend remains release/acquire),
and, to actually run, needs an active event loop.

It also needs a perl that B<carries the core C<multicore_offload> hook>, which
today means a patched one: unlike the release/acquire bracket, whose two function
pointers a module and a backend can pass between themselves through
C<PL_modglobal> on any perl at all, offload rendezvouses inside the interpreter.
On a perl without it this method C<die>s, the offload backend is not even compiled
(see C<_offload_supported>), and everything else in this module works as it always
has - the release/acquire bracket is unaffected, and it is the default.

=item $found = Coro::Multicore::cancel_offload $coro

Ask an offload issued by C<$coro> and still in flight to stop, returning whether
one was found.  Advisory: it raises the flag that C<work> polls, and a C<work>
that does not poll runs to completion regardless.

C<$coro> itself is left alone - it stays suspended in its wait, and when C<work>
returns early C<done> runs as usual with C<done_ctx.cancelled> set, so the offload
call returns a partial result rather than raising.  That is what distinguishes this
from throwing at or cancelling the thread: both of those unwind it, so C<done>
never runs and there is nothing to collect.

Where the handle is to hand, C<< $handle->cancel >> does the same thing and says
which offload it means - and blocks until the work has stopped, which this cannot,
having no way to know which offload it asked about. C<< $handle->safe_cancel >>
stops one without blocking at all. This function remains the way to reach an
offload whose handle a module kept to itself.

Only meaningful with the I<offload> backend installed; croaks otherwise, and
croaks if C<$coro> is not a Coro thread.  See L</CANCELLING WORK IN PROGRESS>.

=item $previous = Coro::Multicore::max_idle [$threads]

Get or set the number of idle worker threads kept warm (default C<1>). The
release/acquire backend grows its worker pool on demand - one thread per
blocking call in flight - and, once a burst subsides, lets the excess threads
retire (see C<idle_timeout>). This is the floor that retirement never drops
below, so a small pool is always ready to pick up the next release without
paying thread-creation latency. Returns the previous value.

=item $previous = Coro::Multicore::idle_timeout [$seconds]

Get or set how long, in seconds, a surplus idle worker thread (one above
C<max_idle>) waits for work before it retires (default C<10>). Set to C<0> to
disable reaping entirely, keeping every thread the pool ever grew to. Returns
the previous value.

Together with C<max_idle> this bounds the steady-state worker-thread count after
a load spike: threads beyond C<max_idle> that stay idle for C<idle_timeout>
seconds exit, shrinking the pool back down.

=back

=cut

package Coro::Multicore;

use Coro ();

BEGIN {
   our $VERSION = '1.0701';

   use XSLoader;
   XSLoader::load __PACKAGE__, $VERSION;
}


sub import {
   if (@_ > 1) {
      require Carp;
      Carp::croak ("Coro::Multicore does not export any symbols");
   }

   enable 1;
}

our $WATCHER;

# A Coro event-loop backend can register how to watch our wakeup pipe, so that
# the reacquire after a released XS call is serviced by whatever loop is in use
# - not just AnyEvent. A backend (Coro::EV, Coro::IOAsync, ...) sets
# $Coro::Multicore::WATCH_FD to a coderef ($fd, $poll_cb) that watches $fd for
# readability, arranges to call $poll_cb when readable, and returns a
# watcher/guard to keep alive. When it is unset we fall back to AnyEvent, so
# existing Coro::AnyEvent setups keep working unchanged.
our $WATCH_FD;

# called when first thread is started, on first release. can
# be called manually, but is not currently a public interface.
sub init {
   if ($WATCH_FD) {
      $WATCHER ||= $WATCH_FD->(fd (), \&poll);
   } else {
      require AnyEvent; # maybe load it unconditionally?
      $WATCHER ||= AE::io (fd, 0, \&poll);
   }
}

our $OFFLOAD_ENABLED = 0; # whether the (experimental) offload backend is installed

# Install/remove the offload backend for the core multicore_offload hook,
# returning the previous on/off state. The whole offload backend is EXPERIMENTAL
# and off by default (the release/acquire backend is installed in BOOT); this is
# opt-in and requires a perl with the core hook.
sub enable_offload {
   my $on   = @_ ? ($_[0] ? 1 : 0) : 1;
   my $prev = $OFFLOAD_ENABLED;

   if ($on) {
      _offload_supported ()
         or do { require Carp; Carp::croak ("Coro::Multicore: offload backend not available (this perl lacks the core multicore_offload hook)") };
      init ();             # ensure our wakeup pipe is watched by the event loop
      _offload_register (1);
   } else {
      _offload_register (0) if _offload_supported ();
   }

   $OFFLOAD_ENABLED = $on;
   $prev
}

package Coro::Multicore::Offload::Awaitable;

# The handle multicore_offload () hands back.  The core contract says the backend
# supplies the object, the offloading module returns it without naming its class,
# and the caller takes the result out of it - with `await` from a stackless caller,
# or `get` from a Coro one, which suspends the calling Coro thread until the work
# is over.  So an offloaded call still looks synchronous where that is what is
# wanted, while several of them can be in flight from one Coro thread.
#
# The protocol is the AWAIT_* method set of Future::AsyncAwait::Awaitable, which is
# duck-typed: implementing the methods is all that is required, and nothing here
# depends on Future being installed.
#
# The object is a hash created in XS (see Multicore.xs), and the fields shared with
# that half are `job` (the in-flight job, absent once resolved and on a handle that
# never had one), `ready`, and `waiters`.  The rest - `values`, `failure`,
# `cancelled`, `on_ready`, `on_cancel` - is private to this half.

# Constructors.  The protocol needs to be able to make instances of its own
# accord: AWAIT_CLONE for the future an async sub returns, and the two NEW_ ones
# for a result that is already known.  None of those has a job, which is the one
# way an instance from here differs from one the backend handed back - and the
# reason the class supports a state with no job at all.
sub new            { bless { ready => 0 }, ref $_[0] || $_[0] }
sub AWAIT_CLONE    { bless { ready => 0 }, ref $_[0] || $_[0] }
sub AWAIT_NEW_DONE { my $class = shift; bless { ready => 1, values  => [ @_ ]  }, ref $class || $class }
sub AWAIT_NEW_FAIL { my $class = shift; bless { ready => 1, failure => $_[0]   }, ref $class || $class }

sub AWAIT_IS_READY     { $_[0]{ready} ? 1 : 0 }
sub AWAIT_IS_CANCELLED { $_[0]{cancelled} ? 1 : 0 }

# The result, reported as coming from $level frames up: a failure has to be raised
# at the point that asked for the value, not from inside this file, which is both
# what the protocol's own test suite checks and what makes the error useful.
sub _result {
   my ($self, $level) = @_;

   if (defined (my $failure = $self->{failure})) {
      die $failure if ref $failure;

      my (undef, $file, $line) = caller $level;
      $failure .= " at $file line $line.\n" unless $failure =~ /\n\z/;

      die $failure;
   }

   my $values = $self->{values} || [];

   wantarray ? @$values : $values->[0]
}

sub AWAIT_GET { $_[0]->_result (1) }

# Wait for the result, running the event loop meanwhile.  Under this backend that
# means suspending the calling Coro thread - the completion arrives through our
# wakeup pipe, so a wait that blocked the thread would deadlock instead - and it is
# where the blocking that multicore_offload () itself used to do now happens.
sub AWAIT_WAIT {
   my $self = shift;

   Coro::Multicore::_offload_wait ($self) unless $self->{ready};

   $self->_result (1)
}

*get = \&AWAIT_WAIT;

sub AWAIT_ON_READY {
   my ($self, $cb) = @_;

   if ($self->{ready}) {
      $cb->($self);
   } else {
      push @{$self->{on_ready}}, $cb;
   }
}

# The protocol's resolvers, which belong to the job-less mode: an instance made by
# AWAIT_CLONE or one of the AWAIT_NEW_ constructors, which is what Future::AsyncAwait
# resolves when it builds the future an async sub returns.  Resolving a handle that
# has a job in flight would let a waiter return while the worker was still writing
# into the caller's frame, so it is refused rather than trusted not to happen.
sub AWAIT_DONE {
   my $self = shift;

   $self->_no_job ("AWAIT_DONE");
   $self->{values} = [ @_ ];
   $self->_resolved
}

sub AWAIT_FAIL {
   my ($self, $failure) = @_;

   $self->_no_job ("AWAIT_FAIL");
   $self->{failure} = $failure;
   $self->_resolved
}

sub _no_job {
   my ($self, $what) = @_;

   return unless $self->{job};

   require Carp;
   Carp::croak ("Coro::Multicore: $what on a handle whose offload is still running");
}

sub _resolved {
   my $self = shift;

   $self->{ready} = 1;

   my $waiters  = delete $self->{waiters};
   my $on_ready = delete $self->{on_ready};

   # a coro that was cancelled while parked leaves a hole behind (see
   # offload_unpark () in the XS)
   if ($waiters)  { $_->ready for grep defined, @$waiters }
   if ($on_ready) { $_->($self) for @$on_ready }

   ()
}

sub AWAIT_ON_CANCEL    { push @{$_[0]{on_cancel}}, $_[1] }
sub AWAIT_CHAIN_CANCEL { push @{$_[0]{on_cancel}}, $_[1] }

sub _fire_on_cancel {
   my $self = shift;

   if (my $on_cancel = delete $self->{on_cancel}) {
      for my $c (@$on_cancel) {
         ref $c eq 'CODE' ? $c->($self) : $c->cancel;
      }
   }
}

# Cancellation comes in two kinds, and the difference is what happens to the
# interpreter while the work is stopping.  Both are advisory in the same way: they
# raise the flag `work` polls, and a work that does not poll runs to completion
# regardless.
#
#   cancel       PROMPT.  Blocks the interpreter until the work has actually
#                stopped, then resolves.  When it returns the offload is over,
#                which is what makes it comparable to a Future's cancel.
#
#   safe_cancel  ASYNCHRONOUS.  Raises the flag and hands back an awaitable that
#                resolves once the work has stopped, so the other Coro threads -
#                and the event loop - keep running meanwhile.
#
# Neither invents a partial result.  What the caller ends up with is whatever the
# module's done () makes of a truncated run, and a module that knows its result is
# incomplete raises PerlMulticore::Cancelled rather than returning something that
# cannot be told apart from a whole answer.  A cancellation that arrived too late to
# truncate anything is not an error at all.
sub cancel {
   my $self = shift;

   return if $self->{ready};

   $self->{cancelled} = 1;
   $self->_fire_on_cancel;

   # a result held back by a safe_cancel in progress (see _complete): applying it
   # is what this cancel is for
   if (my $held = delete $self->{held}) {
      return $self->_apply ($held);
   }

   if ($self->{job}) {
      my $completion = Coro::Multicore::_offload_cancel_wait ($self);

      # the work has stopped by the time that returns; done () still has to run
      $self->_complete ($completion) if $completion;
   } else {
      # PerlMulticore comes with the perl that carries the hook, so a handle made
      # by hand on a perl without it - which is all a handle can be there - falls
      # back to a plain string rather than dying in require
      $self->{failure} ||=
         eval { require PerlMulticore; PerlMulticore::Cancelled->new }
         || "offload cancelled";

      $self->_resolved;
   }

   ()
}

# The asynchronous companion, from Future::AsyncAwait::Awaitable: begin cancelling
# and hand back an awaitable that completes when the cleanup - here, the worker
# actually stopping - is over.  This instance becomes cancelled at that point and
# not before.
sub safe_cancel {
   my $self = shift;

   return $self->AWAIT_NEW_DONE if $self->{ready};

   $self->{cancelled} = 1;
   $self->_fire_on_cancel;

   my $disposal = $self->AWAIT_CLONE;
   my @waiting;

   if ($self->{job}) {
      $self->{safe_cancelling} = 1;
      $self->{safe_disposal}   = $disposal;

      my $completion = Coro::Multicore::_offload_cancel ($self);

      # Inside an atomic section there is no way to wait for the awaitable this
      # would hand back - suspending is exactly what such a section forbids - so
      # the flag half took the prompt path instead and the work has already
      # stopped.  Resolve here and report the cleanup as finished, so that
      # awaiting it is a no-op rather than a deadlock.
      if ($completion > 0) {
         delete $self->{safe_cancelling};
         delete $self->{safe_disposal};

         $self->_complete ($completion);
         $disposal->AWAIT_DONE;
      }

      return $disposal;
   }

   # No job of our own, so our cleanup is our children's: this is the shape
   # Future::AsyncAwait uses, where the future an async sub returns is a clone of
   # the thing it awaited, and the thing it awaited is chained to it.
   @waiting = map { $_->safe_cancel } grep { !$_->AWAIT_IS_READY }
                 @{ delete $self->{safe_children} || [] };

   unless (@waiting) {
      $self->cancel;
      $disposal->AWAIT_DONE;

      return $disposal;
   }

   my $pending = @waiting;

   for my $w (@waiting) {
      $w->AWAIT_ON_READY (sub {
         return if --$pending;

         # The ordering the protocol requires: WE become cancelled first, so that a
         # frame resumed by a child becoming ready sees its own future already
         # cancelled - and only then are the children finished off.
         $self->cancel;
         $_->cancel for @{ $self->{safe_cancelled_children} || [] };
         $disposal->AWAIT_DONE;
      });
   }

   $disposal
}

# Attaching a child for safe cancellation also tells the child that a parent is
# orchestrating its teardown, so that it holds its result back until we say (see
# _complete) rather than resolving as soon as the work stops.
sub AWAIT_CHAIN_SAFE_CANCEL {
   my ($self, $child) = @_;

   push @{$self->{safe_children}}, $child;
   push @{$self->{safe_cancelled_children}}, $child;

   $child->{safe_parent_driven} = 1 if ref $child eq ref $self;

   ()
}

# Called from the XS when the work is over: run the module's done () inside an eval
# - the sanctioned way for it to report failure is to croak - and resolve with
# whichever came back.  This is the only place a job-backed handle is resolved.
sub _complete {
   my ($self, $completion) = @_;

   my @values = eval { Coro::Multicore::_offload_run_done ($completion) };
   my $result = $@ ? { failure => $@ } : { values => \@values };

   # A safe_cancel is in progress and a parent is orchestrating it: hold the result
   # until the parent has marked itself cancelled and comes back to us (see
   # safe_cancel).  Without a parent there is nobody to wait for, so resolve now and
   # report the cleanup as done.
   if (delete $self->{safe_cancelling}) {
      my $disposal = delete $self->{safe_disposal};

      $self->{held} = $result if $self->{safe_parent_driven};
      $self->_apply ($result) unless $self->{safe_parent_driven};
      $disposal->AWAIT_DONE if $disposal;

      return;
   }

   $self->_apply ($result)
}

sub _apply {
   my ($self, $result) = @_;

   exists $result->{failure}
      ? $self->AWAIT_FAIL ($result->{failure})
      : $self->AWAIT_DONE (@{$result->{values}})
}

# A pending handle that nobody is going to collect: the consumer dropped it, or the
# Coro thread holding it was cancelled.  The work still owns whatever it was given,
# so this asks it to stop and waits until it has - see offload_abandon () in the XS.
#
# done () still runs, with done_ctx.dropped set and its value discarded: it is the
# only place a module can release what it built, and a module that returned this
# handle upward has its job on the heap with nothing else able to free it.  It runs
# here rather than later because a frame-owned job dies with the frame that is being
# torn down - and inside an eval, because there is nobody to raise to.
sub DESTROY {
   my $self = shift;

   return unless $self->{job};

   my $completion = Coro::Multicore::_offload_abandon ($self)
      or return;

   eval { Coro::Multicore::_offload_run_done ($completion); 1 }
      or warn "Coro::Multicore: offload done () failed after the handle was dropped: $@";
}

package Coro::Multicore;

=head1 THE OFFLOAD HANDLE

None of this section applies unless the perl carries the core
C<multicore_offload> hook and C<Coro::Multicore::enable_offload> has installed
this backend; see there for what that requires.

An offloading XS module gets a handle back from C<multicore_offload>, not a
value, and it is C<Coro::Multicore::Offload::Awaitable> when this backend is
installed. The class is deliberately not something a caller names: core's
contract (F<perlmulticore.h>) fixes the B<methods>, every backend supplies its
own class, and that is what lets an XS module offer one asynchronous entry point
that works whichever backend the application chose - or none.

Most callers never see it. A module whose method has always returned a value
still returns one, because the C wrapper C<multicore_offload_sync> waits for the
handle on its behalf: for this backend that suspends the calling Coro thread until
the work is over, which is the transparent behaviour the whole module exists to
provide. The handle only surfaces where a module offers an asynchronous entry
point as well:

   my $handle = $obj->scramble_async ($buf);   # returns as soon as it is queued

   my $result = $handle->get;                  # suspend this Coro thread for it
   $handle->cancel;                            # stop it, blocking until it has
   await $handle->safe_cancel;                 # stop it without blocking

   # or, from a Future::AsyncAwait sub, when that is the backend in use
   my $result = await $handle;

What it buys under this backend is several offloads in flight from one Coro
thread, which otherwise needs a thread each:

   my @h = map { $_->scramble_async } @jobs;   # all of them running
   my @r = map { $_->get } @h;                 # collected in order

=over 4

=item $result = $handle->get

Wait for the work to finish and return what the module's C<done> produced,
suspending the calling Coro thread meanwhile - the event loop keeps turning, since
that is how the completion arrives. Returns at once if the handle is already
resolved, which it may be: an offload issued inside an C<atomic> section, or one
that found no free job slot, has already run by the time the handle is seen.

If C<done> croaked - a module's sanctioned way of reporting failure - the
exception is raised here. So is an exception aimed at the waiting Coro thread, but
only once the work has really stopped: unwinding earlier would free memory the
worker is still writing into.

Must not be called from an C<atomic> section, which forbids suspending; that
croaks rather than deadlocking.

=item $handle->cancel

Stop the work and B<block> until it has stopped, so that the offload is over by the
time this returns. Advisory in the usual way - C<work> stops when it next polls,
and one that never polls is waited out - so how long it blocks is up to the
operation. Blocking is what makes this the I<prompt> form, comparable to a
L<Future>'s C<cancel>: the alternative, returning while the worker is still
writing, is what C<safe_cancel> is for.

Same mechanism as C<Coro::Multicore::cancel_offload>, but it says which offload it
means, and it waits.

What the caller ends up with is whatever the module's C<done> makes of a truncated
run. A module that knows its result is incomplete raises
C<PerlMulticore::Cancelled> rather than returning something the caller could not
tell apart from a whole answer; one whose work had finished anyway before noticing
the flag returns the whole answer, because a late cancellation is not an error.

=item $cleanup = $handle->safe_cancel

The asynchronous companion, from L<Future::AsyncAwait::Awaitable>: raise the same
flag, but return at once with an awaitable that completes when the work has
stopped. Nothing is blocked meanwhile - the event loop turns and the other Coro
threads run - and the handle becomes cancelled when the cleanup completes, not
before.

   await $handle->safe_cancel;    # or $handle->safe_cancel->get

This is the form a stackless caller needs, since blocking its thread would stop the
very loop the completion arrives on. C<AWAIT_CHAIN_SAFE_CANCEL> chains another
awaitable to this one, with the ordering the protocol requires: this instance is
marked cancelled before its children, so that a frame resumed by a child sees its
own future already cancelled.

Inside a C<Coro::Atomic> section this behaves as C<cancel> does - it blocks until
the work has stopped, and the awaitable it returns is already complete. It has to:
waiting for that awaitable would mean suspending, which is the one thing the
section forbids, so an asynchronous cancellation there could never be completed.
The same trade is made everywhere else in this module: atomicity is a correctness
guarantee, whereas doing the cleanup without blocking is an optimisation.


=item AWAIT_IS_READY, AWAIT_GET, AWAIT_WAIT, AWAIT_ON_READY, ...

The C<AWAIT_*> protocol of L<Future::AsyncAwait::Awaitable>, which is duck-typed:
implementing the methods is the whole requirement, and nothing here needs
L<Future> installed. It is what makes the handle usable from an C<async sub>, and
it is verified against that distribution's own conformance suite where it is
available.

=back

A pending handle that is simply dropped - a caller that decides it wants neither
the value nor the work, or a Coro thread cancelled while holding one - is how the
backend learns nobody is waiting. It then asks the work to stop and B<waits> for
it, because whatever the work was given usually belongs to the frame being torn
down. How long that takes depends on how promptly C<work> polls.

The module's C<done> still runs on that path, with C<done_ctx.dropped> set and its
value discarded, because it is the only place the module can release what it built
- for one that returned the handle upward, its job is on the heap and nothing else
can reach it. It runs inside an C<eval>, there being nobody to raise to; a failure
is reported as a warning.

=head1 THREAD SAFETY OF SUPPORTING XS MODULES

Just because an XS module supports perlmulticore might not immediately
make it reentrant. For example, while you can (try to) call C<execute>
on the same database handle for the patched C<DBD::mysql> (see the
L<registry|http://perlmulticore.schmorp.de/registry>), this will almost
certainly not work, despite C<DBD::mysql> and C<libmysqlclient> being
thread safe and reentrant - just not on the same database handle.

Many modules have limitations such as these - some can only be called
concurrently from a single thread as they use global variables, some
can only be called concurrently on different I<handles> (e.g. database
connections for DBD modules, or digest objects for Digest modules),
and some can be called at any time (such as the C<md5> function in
C<Digest::MD5>).

Generally, you only have to be careful with the very few modules that use
global variables or rely on C libraries that aren't thread-safe, which
should be documented clearly in the module documentation.

Most modules are either perfectly reentrant, or at least reentrant as long
as you give every thread it's own I<handle> object.

=head1 EXCEPTIONS AND THREAD CANCELLATION

L<Coro> allows you to cancel threads even when they execute within an XS
function (C<cancel> vs. C<cancel> methods). Similarly, L<Coro> allows you
to send exceptions (e.g. via the C<throw> method) to threads executing
inside an XS function.

While doing this is questionable and dangerous with normal Coro threads
already, they are both supported in this module, although with potentially
unwanted effects. The following describes the current implementation and
is subject to change. It is described primarily so you can understand what
went wrong, if things go wrong.

=over 4

=item EXCEPTIONS

When a thread that has currently released the perl interpreter (e.g. because it is
executing a perlmulticore enabled XS function) receives an exception, the XS
function is B<not> interrupted: it finishes its blocking work, C<perlinterp_acquire
()> returns as usual, and the function runs to its end and cleans up.  The
exception is then raised as the XS function returns, so from perl it reads as
though the call itself died - an C<eval> around it catches it - while the XS frame
really did return normally.

Both halves of that matter.  Raising inside C<perlinterp_acquire ()> would unwind
out of the middle of an XS function that still has cleanup pending - a buffer to
free, a statement to finalise, a mutex to unlock - and the perlmulticore contract
every supporting module is written against is C<release (); work (); acquire ();>
and then I<carry on>; such modules install no unwind-safe cleanup around their
acquire.  But merely leaving the exception pending is not enough either: L<Coro>
delivers a pending exception only at the end of a Schedule-Like Function, so it
would wait for the thread's next C<cede> or blocking call - arbitrarily far away,
and skipped altogether by a thread that returns from the call and then simply
ends, which used to lose the exception silently.

So the exception is taken over on reacquiring the interpreter and armed to fire at
the scope exit of the XS function that released it.  That is the first perl-level
boundary after the call, it always happens, and it costs the XS function nothing.

If what you want is to B<abort> the work rather than to be told about it
afterwards, the release/acquire bracket cannot help: once the C code is running it
has no way to interrupt it.  The I<offload> backend can, with the module's
cooperation - see L</CANCELLING WORK IN PROGRESS>.

=item CANCELLATION

Unsafe cancellation on a thread that has released the perl interpreter
frees its resources, but let's the XS code continue at first. This should
not lead to corruption on the perl level, as the code isn't allowed to
touch perl data structures until it reacquires the interpreter.

The call to C<perlinterp_acquire ()> will then block indefinitely, leaking
the (OS level) thread.

Safe cancellation will simply fail in this case, so is still "safe" to
call.

=back

=head1 CANCELLING WORK IN PROGRESS

Neither backend can stop C code that is already executing - there is no safe way
to interrupt an arbitrary C function from outside.  So cancellation through the
I<offload> backend is B<advisory>, and needs the module to take part.

A cancellation flag is handed to C<work> in its context.  A C<work> written in
chunks polls it and returns early:

   static void
   my_work (void *arg, const perl_multicore_work_ctx *ctx)
   {
     while (more_to_do (arg))
       {
         if (ctx && ctx->size >= sizeof (*ctx) && ctx->cancel && *ctx->cancel)
           break;                     /* asked to stop */

         do_one_chunk (arg);
       }
   }

C<done> is told, through C<done_ctx.cancelled>, whether the work stopped early,
so it can marshal a partial result or none at all.

The flag is raised when the thread that issued the offload is no longer waiting
for the answer: an exception aimed at it, or its cancellation.  In that case the
offload call raises rather than returning.

It raises B<after the work has stopped>, though, not the moment the exception
arrives.  C<work_arg> points into the frame that is being unwound, and so, usually,
does everything C<work> writes into, which the worker is still busy with; letting
the frame go first would hand it freed memory.  So the wait asks the work to stop
and goes on waiting, and only then raises.  Cancelling the thread outright cannot
wait in the same green-thread sense - there is nothing left to resume - so it
blocks the interpreter thread instead, for as long as the work takes to notice.

Which means C<work> deciding not to poll is not free: a C<work> that never polls
cannot be aborted, and an interrupted call then waits out the whole thing.  Poll
often enough that the wait is short.

Which trigger you want decides how you ask.  Throwing at or cancelling the thread
unwinds it, so the offload call raises and C<done> never runs: use that when the
answer is no longer wanted at all - and note that C<work> must then release
anything it acquired itself, since C<done> is not there to do it.
C<cancel_offload> leaves the thread suspended, so C<done> does run and the call
returns whatever C<work> managed: use that when a partial result is worth having.

=head1 INTERACTION WITH OTHER SOFTWARE

This module is very similar to other environments where perl interpreters
are moved between threads, such as mod_perl2, and the same caveats apply.

I want to spell out the most important ones:

=over 4

=item pthreads usage

Any creation of pthreads make it impossible to fork portably from a
perl program, as forking from within a threaded program will leave the
program in a state similar to a signal handler. While it might work on
some platforms (as an extension), this might also result in silent data
corruption. It also seems to work most of the time, so it's hard to test
for this.

I recommend using something like L<AnyEvent::Fork>, which can create
subprocesses safely (via L<Proc::FastSpawn>).

Similar issues exist for signal handlers, although this module works hard
to keep safe perl signals safe.

=item module support

This module moves the same perl interpreter between different
threads. Some modules might get confused by that (although this can
usually be considered a bug). This is a rare case though.

=item atomic sections (L<Coro::Atomic>)

An C<atomic> section guarantees that no other coro thread runs until it
finishes.  Both of this module's backends would break that guarantee - the
default one releases the interpreter to another native thread, which then runs
other coro threads, and the I<offload> backend suspends the calling coro
outright.

So for as long as the running coro is inside an atomic section, this module is
suppressed: multicore-enabled XS functions still work, they simply run inline on
the current thread, as they would with this module not loaded at all.  This
overrides C<enable>, C<scoped_enable> and C<scoped_disable> alike - atomicity is
a correctness guarantee, whereas multicore is an optimisation, and the
perlmulticore specification makes a release that does nothing always valid.

That also makes an atomic section usable as a deliberate off-switch for this
module, a stronger one than C<scoped_disable>, and correspondingly makes any
C<scoped_enable> inside it inert - see
L</Coro::Atomic as a stronger scoped_disable> in L</API FUNCTIONS>.

Two consequences worth knowing:

Such calls become possible rather than merely safe.  Without this suppression
B<both> backends die: the offload backend suspends the caller and trips Coro's
yield check directly, and the release/acquire backend trips it just as surely on
the worker thread - the C<CORO_SCHEDULE> there goes through the same check, and
the exception is carried back through the transfer's C<JMPENV> and rethrown at
the C<perlinterp_acquire ()>.  So without it a C<Digest::MD5::md5> inside an
atomic section would be a fatal error; with it, the same digest is computed,
simply without releasing the interpreter.  Nothing is lost but parallelism.

An atomic section can delay other threads' C<perlinterp_acquire ()>.  A coro that
released the interpreter earlier cannot reacquire it until the atomic section
ends, because reacquiring needs the interpreter and the atomic coro will not
yield.  Keep atomic sections short, as you would anyway.

=item event loop reliance

To be able to wake up programs waiting for results, this module relies on
an active event loop (via L<AnyEvent>). This is used to notify the perl
interpreter when the asynchronous task is done.

Since event loops typically fail to work properly after a fork, this means
that some operations that were formerly working will now hang after fork.

A workaround is to call C<Coro::Multicore::enable 0> after a fork to
disable the module.

Future versions of this module might do this automatically.

=back

=head1 BUGS & LIMITATIONS

=over 4

=item (OS-) threads are never released

At the moment, threads that were created once will never be freed. They
will be reused for asynchronous requests, though, so as long as you limit
the maximum number of concurrent asynchronous tasks, this will also limit
the maximum number of threads created.

The idle threads are not necessarily using a lot of resources: on
GNU/Linux + glibc, each thread takes about 8KiB of userspace memory +
whatever the kernel needs (probably less than 8KiB).

Future versions will likely lift this limitation.

=item The enable_times feature of Coro is messed up

The enable_times feature uses the per-thread timer to measure per-thread
execution time, but since Coro::Multicore runs threads on different
pthreads it will get the wrong times. Real times are not affected.

=item The offload backend needs a patched perl

The release/acquire bracket - what this module is mostly for - works on any perl,
because a module and a backend meet in a C<PL_modglobal> struct that needs no
support from the interpreter. Offload does not: its hook lives in the interpreter,
so it exists only on a perl built with it. There, C<enable_offload> works; anywhere
else the offload half of this module is compiled out and C<enable_offload> dies,
which is a limitation of where the rendezvous was put rather than of the mechanism.

=item Fork support

Due to the nature of threads, you are not allowed to use this module in a
forked child normally, with one exception: If you don't create any threads
in the parent, then it is safe to start using it in a forked child.

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://software.schmorp.de/pkg/AnyEvent-XSThreadPool.html

Additional thanks to Zsbán Ambrus, who gave considerable design input for
this module and the perl multicore specification.

=cut

1

