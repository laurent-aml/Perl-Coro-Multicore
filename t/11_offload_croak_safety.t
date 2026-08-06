#!perl
# Phase 1: the offload path must not lose a job slot however the caller's frame
# exits.  Two exits matter:
#
#   done () croaks     - the sanctioned way for a module to report failure, so it
#                        is a normal path rather than an edge case.
#   the issuer is gone - a coro cancelled while suspended in the wait unwinds
#                        (Coro runs scope cleanup on cancel) while the worker still
#                        owns the job.
#
# Interruption by an exception is covered in t/06, together with cancellation.
#
# Both are asserted by watching the free list: whatever happens, every slot must
# come back.

use strict;

use Test::More;

BEGIN { $ENV{PERL_ANYEVENT_MODEL} = "EV" }

use Coro;
use Coro::AnyEvent;
use Coro::Multicore;

plan skip_all => "offload backend not built (this perl lacks the core multicore_offload hook)"
   unless Coro::Multicore::_offload_supported ();

plan tests => 9;

alarm 120;

Coro::Multicore::enable_offload (1);

# build the pool and learn the baseline
async { Coro::Multicore::_offload_selftest () }->join;
my $slots = Coro::Multicore::_offload_free_slots ();
cmp_ok $slots, '>', 0, "pool built, $slots slots free at rest";

# --- done () croaking must not lose the slot -------------------------------
{
   my $err;
   async { eval { Coro::Multicore::_offload_selftest_croak (); 1 } or $err = $@ }->join;

   like $err, qr/deliberate croak from done/, "a croak from done () reaches the caller";
   is Coro::Multicore::_offload_free_slots (), $slots,
      "the slot came back despite the croak";
}

# Repeat past the pool size: if the slot were lost each time, the pool would be
# exhausted and every later offload would silently fall back to inline.
{
   for (1 .. $slots + 4) {
      async { eval { Coro::Multicore::_offload_selftest_croak (); 1 } }->join;
   }
   is Coro::Multicore::_offload_free_slots (), $slots,
      "still all slots free after " . ($slots + 4) . " croaking offloads";

   my $report;
   async { $report = Coro::Multicore::_offload_selftest () }->join;
   like $report, qr/\bwork_ran=1\b/, "offload still functional afterwards";
}

# --- cancelling a coro suspended in an offload ----------------------------
# This one *does* unwind: Coro runs scope cleanup on cancel, so the guard armed
# around the wait fires.  The worker still owns the job at that point, so it is
# handed over as abandoned and the slot is reclaimed rather than lost - and no
# dead coro is readied.
{
   my $abandons = Coro::Multicore::_offload_abandons ();
   my @log;

   my $victim = async {
      Coro::Multicore::_offload_selftest_slow (200_000);
      push @log, "resumed past the offload";   # must not happen
   };

   Coro::AnyEvent::sleep 0.05;
   $victim->cancel;

   is "@log", "", "cancel terminates the coro without resuming past the offload";
   is Coro::Multicore::_offload_abandons (), $abandons + 1,
      "the abandon guard fired, so the worker owned the job at that moment";

   Coro::AnyEvent::sleep 0.5;    # let the worker finish and poll() reclaim
   is Coro::Multicore::_offload_free_slots (), $slots,
      "the abandoned job's slot was reclaimed";

   my $report;
   async { $report = Coro::Multicore::_offload_selftest () }->join;
   like $report, qr/\bwork_ran=1\b/, "offload still functional after a cancel in flight";
}
