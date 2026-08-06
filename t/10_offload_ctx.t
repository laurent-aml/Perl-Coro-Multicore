#!perl
# The contexts a backend hands to work()/done() (perlmulticore.h, offload ABI 2).
#
# Verified through Coro::Multicore::_offload_selftest, a private XSUB that runs one
# offload round trip with a C work/done pair and reports what it was given.  There
# is no other offload consumer in this dist - Coro::Multicore::sleep uses the
# release/acquire bracket, not offload - so without that helper the context
# contract would go unexercised until an external module adopted it.

use strict;

use Test::More;

BEGIN { $ENV{PERL_ANYEVENT_MODEL} = "EV" }

use Coro;
use Coro::AnyEvent;
use Coro::Multicore;

plan skip_all => "offload backend not built (this perl lacks the core multicore_offload hook)"
   unless Coro::Multicore::_offload_supported ();

plan tests => 6;

alarm 60;

Coro::Multicore::enable_offload (1);
ok $Coro::Multicore::OFFLOAD_ENABLED, "offload backend installed";

# offload suspends the calling coro, so this has to run in one, with a loop.
my $report;
async { $report = Coro::Multicore::_offload_selftest () }->join;

diag "selftest: $report" if $ENV{TEST_VERBOSE};

like $report, qr/\bwork_ran=1\b/,      "work () ran on the worker";
like $report, qr/\bwork_ctx_ok=1\b/,   "work got a work_ctx whose size covers the known fields";
like $report, qr/\bdone_ctx_ok=1\b/,   "done got a done_ctx whose size covers the known fields";

like $report, qr/\bcancel_ok=1\b/,     "work is handed a cancellation flag, initially clear";
like $report, qr/\bcancelled=0\b/,     "done_ctx reports the work as not cancelled";
