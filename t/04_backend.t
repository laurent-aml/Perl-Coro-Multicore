#!perl
# The release/acquire bracket parks the calling thread's machine context and lets
# another thread resume it.  Not every libcoro backend allows that: a Windows
# fiber may only be switched to by the thread that last ran it, so releasing to a
# worker would be undefined rather than slow.  BOOT asks Coro which backend it was
# built with and refuses in that case, running the bracket inline instead.
#
# This test is meaningful on either kind of build: it asserts the classification
# agrees with what Coro reports, whichever that is.

use strict;

use Test::More tests => 3;

use Coro;
use Coro::State ();
use Coro::Multicore;

my $backend = Coro::State::BACKEND();
ok defined $backend && length $backend, "Coro reports a backend ($backend)";

my $expected = ($backend eq "fiber" || $backend eq "loser") ? 0 : 1;
is Coro::Multicore::_backend_migrates() ? 1 : 0, $expected,
   "a '$backend' context " . ($expected ? "can" : "cannot") . " be resumed by another thread";

# Whatever the answer, the module stays usable: with a migrating backend the
# bracket really releases, and without one it runs inline - both correct, and
# enable() reports the same either way.
ok Coro::Multicore::enable (), "enable() is unaffected by the backend";
