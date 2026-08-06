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
my ($reached_past_call, $eval_err, $yield_err);

my $t0 = Time::HiRes::time ();

my $victim = async {
   my $ok = eval { Coro::Multicore::sleep $NAP; $reached_past_call = 1; 1 };
   $eval_err = $ok ? undef : $@;

   # it has already been delivered by now, so this must come back clean
   eval { Coro::cede; 1 } or $yield_err = $@;
};

async {
   Coro::AnyEvent::sleep $NAP / 5;      # let the victim get well inside the call
   $victim->throw ("boom\n");
};

$victim->join;

my $elapsed = Time::HiRes::time () - $t0;

# The XS function is left to finish its blocking work and clean up; the exception
# is armed instead to fire at the XSUB's scope exit.  So from perl this reads as
# "the released call died", while the XS frame really did return normally.
like $eval_err, qr/boom/, "the exception is raised out of the released call";
ok !$reached_past_call, "so execution does not continue past the call";

# Had it been delivered before the call was entered, this would be ~0.
cmp_ok $elapsed, '>=', $NAP * 0.8,
   "delivered on reacquiring, i.e. the release boundary really was crossed";

is $yield_err, undef, "nothing is left pending for a later yield";

# Delivery is at the XSUB's scope exit rather than at some later yield, so an
# exception can no longer be dropped by a coro that returns and then just ends.
{
   my $late_err;
   my $ender = async {
      eval { Coro::Multicore::sleep $NAP; 1 } or $late_err = $@;
      # no cede, no block: the coro simply ends here
   };
   async { Coro::AnyEvent::sleep $NAP / 5; $ender->throw ("gone\n") };
   $ender->join;

   like $late_err, qr/gone/, "not lost when the coro ends without yielding again";
}

# --- the interpreter is still usable afterwards ----------------------------
my $after = 0;
async { $after = 1 }->join;
is $after, 1, "scheduling still works after all of that";

ok eval { Coro::Multicore::sleep $NAP; 1 },
   "release/acquire still works after all of that";
