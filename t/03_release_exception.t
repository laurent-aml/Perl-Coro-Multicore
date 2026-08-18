#!perl
# What an exception does across a perlinterp_release () / perlinterp_acquire () pair.
#
# While a coro sits inside a released multicore call, the interpreter is being run
# by a pool thread on *other* coro stacks - so every switch there is a stack
# switch performed by a thread that did not create the stack.  That is the part
# most at risk on a platform whose longjmp takes part in stack-based unwinding
# (Win64 SEH above all), which is why this is asserted outright rather than left
# to be covered incidentally.
#
# Gated to the release/acquire backend (offload never moves the interpreter, so
# there is no crossing to test) and to the asm libcoro backend, the only one whose
# saved context is a bare stack pointer and can therefore be parked by one thread
# and resumed by another; fiber, for one, cannot.

use strict;

use Test::More;
use Time::HiRes ();

BEGIN { $ENV{PERL_ANYEVENT_MODEL} = "EV" }

use Coro;
use Coro::State ();
use Coro::AnyEvent;
use Coro::Multicore;

plan skip_all => "libcoro backend is " . Coro::State::BACKEND . ", not asm"
   unless Coro::State::BACKEND eq "asm";

plan skip_all => "the offload backend is installed, so nothing gets released"
   if $Coro::Multicore::OFFLOAD_ENABLED;

plan tests => 9;

alarm 120;   # a stalled acquire would otherwise hang the whole suite

my $NAP = 0.5;      # how long each released call stays out of the interpreter

# --- controls --------------------------------------------------------------
# Without these, everything below would hold just as well if nothing were ever
# actually released.
{
   my $ran = 0;
   my $other = async { $ran = 1 };

   ok eval { Coro::Multicore::sleep $NAP; 1 }, "control: a released call returns normally";
   ok $ran, "control: another coro ran while the interpreter was released"
      or diag "nothing was released - the rest of this file proves little";

   $other->cancel unless $ran;
}

# --- a throw aimed at a coro that is inside a released call ----------------
my (@seen, $call_returned, $eval_err, $yield_err);

my $t0 = Time::HiRes::time ();

my $victim = async {
   $call_returned = 0;
   my $ok = eval { Coro::Multicore::sleep $NAP; $call_returned = 1; 1 };
   $eval_err = $ok ? undef : $@;

   # the coro's next yield point after the released call
   eval { Coro::cede; 1 } or $yield_err = $@;
};

async {
   Coro::AnyEvent::sleep $NAP / 5;      # let the victim get well inside the call
   $victim->throw ("boom\n");
};

$victim->join;

my $elapsed = Time::HiRes::time () - $t0;

# The XS call is left alone: it is not interrupted part-way, so whatever C state
# it owns cannot be torn in half by the exception.
ok $call_returned, "a throw during a released call does not interrupt the call";
is $eval_err, undef, "so nothing is raised out of the call itself";

# If the throw had landed before the call was even entered, this would be ~0 and
# the crossing we care about would never have happened.
cmp_ok $elapsed, '>=', $NAP * 0.8,
   "the release boundary really was crossed while the throw was pending";

# ...and the exception is not lost: it is delivered at the next yield.
like $yield_err, qr/boom/, "the pending exception surfaces at the next yield";

# --- the gap that is left ---------------------------------------------------
#
# Letting the call finish is deliberate (see EXCEPTIONS in Multicore.pm): raising
# from pmapi_acquire () would unwind out of the middle of an XS function that
# still has cleanup pending, and the blocking work is finished by then anyway, so
# nothing would be cancelled - only discarded.
#
# What is *not* deliberate is how late delivery then is.  It happens at the coro's
# next yield, which test 6 above pins down; a thread that returns from the call
# and then finishes without yielding again may never see the exception at all.
#
# The intended fix is to deliver at the first perl-level boundary after the XS
# function returns - still without unwinding through it, so the cleanup-safety
# argument is untouched, but promptly rather than whenever a yield happens along.
# Note what that would look like from perl: an eval around the released call would
# then catch the exception, because the boundary falls inside it. So it reads like
# "the call died" to the caller, while the XS frame really did return normally.
#
# Hence the assertion below, and hence tests 3 and 4 are the ones that must be
# revisited if this is implemented - they pin the current, later timing.
TODO: {
   local $TODO = "delivery is as late as the next yield; the intended behaviour "
               . "is the first perl-level boundary after the call returns, which "
               . "an eval around the call would catch (see BUGS & LIMITATIONS)";

   ok !$call_returned, "pending exception is delivered promptly after the call";
}

# --- the interpreter is still usable afterwards ----------------------------
my $after = 0;
async { $after = 1 }->join;
is $after, 1, "scheduling still works after all of that";

ok eval { Coro::Multicore::sleep $NAP; 1 },
   "release/acquire still works after all of that";
