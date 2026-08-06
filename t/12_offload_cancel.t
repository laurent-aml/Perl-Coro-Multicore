#!perl
# Cancelling work that is already running.
#
# Neither backend can interrupt C code on its own, so cancellation is advisory: a
# flag reaches work () through its context, and a work () that polls between
# chunks can return early.
#
# The triggers are an exception aimed at the coro that issued the offload, an
# explicit cancel_offload, and cancelling the coro outright.  In every case the
# work is asked to stop and then WAITED FOR: work_arg, and whatever the work
# writes into, belong to the frame that is about to be destroyed.

use strict;

use Test::More;

BEGIN { $ENV{PERL_ANYEVENT_MODEL} = "EV" }

use Coro;
use Coro::AnyEvent;
use Coro::Multicore;

plan skip_all => "offload backend not built (this perl lacks the core multicore_offload hook)"
   unless Coro::Multicore::_offload_supported ();

plan tests => 23;

alarm 120;

Coro::Multicore::enable_offload (1);

# The helper's work () runs 100 chunks of 10ms, polling the flag between them.
my $CHUNKS = 100;

async { Coro::Multicore::_offload_selftest () }->join;   # build the pool
my $slots = Coro::Multicore::_offload_free_slots ();

# --- control: left alone, it runs to completion ----------------------------
{
   my $ret;
   async { $ret = Coro::Multicore::_offload_selftest_cancellable () }->join;

   is Coro::Multicore::_offload_chunks_done (), $CHUNKS,
      "an uninterrupted cancellable offload runs every chunk";
   is $ret, 0, "and done () is told it was not cancelled";
   is Coro::Multicore::_offload_free_slots (), $slots, "slot returned";
}

# --- interrupted part way through -----------------------------------------
{
   my $abandons = Coro::Multicore::_offload_abandons ();
   my ($err, $past);

   my $victim = async {
      my $ok = eval { Coro::Multicore::_offload_selftest_cancellable (); $past = 1; 1 };
      $err = $ok ? undef : $@;
   };

   Coro::AnyEvent::sleep 0.15;          # a fraction of the way in
   $victim->throw ("stop\n");
   $victim->join;

   like $err, qr/stop/, "the exception is raised out of the offload call";
   ok !$past, "so execution does not continue past it";

   cmp_ok Coro::Multicore::_offload_chunks_done (), '<', $CHUNKS,
      "work () saw the flag and stopped early";

   is Coro::Multicore::_offload_abandons (), $abandons,
      "the job was never abandoned - the wait held until the work had stopped";

   is Coro::Multicore::_offload_free_slots (), $slots,
      "so its slot is back already, with no reclaim to wait for";

   my $report;
   async { $report = Coro::Multicore::_offload_selftest () }->join;
   like $report, qr/\bwork_ran=1\b/, "offload still functional afterwards";
}

# --- cancel_offload: stop the work without disturbing the caller ----------
# The other triggers all unwind the issuing thread, so done () never runs for a
# cancelled job.  This one leaves the thread suspended in its wait, so work ()
# returns early and done () marshals whatever it managed - the call comes back
# normally with a partial result instead of raising.
{
   my $abandons = Coro::Multicore::_offload_abandons ();
   my ($ret, $err, $past);

   my $victim = async {
      my $ok = eval { $ret = Coro::Multicore::_offload_selftest_cancellable (); $past = 1; 1 };
      $err = $ok ? undef : $@;
   };

   Coro::AnyEvent::sleep 0.15;
   ok Coro::Multicore::cancel_offload ($victim), "cancel_offload found the in-flight job";
   $victim->join;

   is $err, undef, "the offload call does not raise";
   ok $past, "so the caller carries on normally";
   is $ret, 1, "done () is told the work was cancelled";
   cmp_ok Coro::Multicore::_offload_chunks_done (), '<', $CHUNKS, "work () stopped early";
   is Coro::Multicore::_offload_abandons (), $abandons,
      "and the job was not abandoned - the caller was never unwound";

   Coro::AnyEvent::sleep 0.4;
   is Coro::Multicore::_offload_free_slots (), $slots, "slot returned";
}

# --- cancelling the thread itself, mid-offload ----------------------------
# Nothing resumes here, so the wait above never gets to run: the scope guard is
# what runs, while the frame holding work_arg is being torn down.  It has to wait
# for the worker too, and this is the one place the interpreter thread blocks.
{
   my $abandons = Coro::Multicore::_offload_abandons ();
   my $waits    = Coro::Multicore::_offload_abandon_waits ();
   my $past     = 0;

   my $victim = async { Coro::Multicore::_offload_selftest_cancellable (); $past = 1 };

   Coro::AnyEvent::sleep 0.15;
   $victim->cancel;

   ok !$past, "the cancelled thread does not carry on";

   is Coro::Multicore::_offload_abandons (), $abandons + 1,
      "the guard fired: the worker still owned the job";
   is Coro::Multicore::_offload_abandon_waits (), $waits + 1,
      "and it waited for the work to stop before letting the frame go";

   cmp_ok Coro::Multicore::_offload_chunks_done (), '<', $CHUNKS,
      "work () saw the flag and stopped early";

   Coro::AnyEvent::sleep 0.2;           # let poll () reclaim the abandoned slot
   is Coro::Multicore::_offload_free_slots (), $slots, "slot returned";
}

# --- and the uninteresting cases ------------------------------------------
{
   my $idle = async { Coro::AnyEvent::sleep 0.05 };
   ok !Coro::Multicore::cancel_offload ($idle),
      "cancel_offload is false for a thread with nothing in flight";
   $idle->join;

   ok !eval { Coro::Multicore::cancel_offload ("not a thread"); 1 },
      "cancel_offload croaks on something that is not a Coro thread";
}
