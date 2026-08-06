#!perl
# The handle multicore_offload () hands back has to satisfy the awaitable
# protocol, which is what lets a stackless caller await it and a module return it
# without naming its class.  Future::AsyncAwait ships the conformance suite for
# that protocol; this runs it.
#
# It runs against instances the class makes itself (AWAIT_NEW_DONE, AWAIT_CLONE,
# and a bare `new`), since the suite needs to resolve and cancel them by hand.
# The ones the backend hands back over a real job are covered by t/09.

use strict;

use Test::More;

use Coro;
use Coro::Multicore;

BEGIN {
   eval { require Test::Future::AsyncAwait::Awaitable; 1 }
      or plan skip_all => "Test::Future::AsyncAwait::Awaitable not available";
}

Test::Future::AsyncAwait::Awaitable::test_awaitable ("offload handle",
   class  => "Coro::Multicore::Offload::Awaitable",
   new    => sub { Coro::Multicore::Offload::Awaitable->new },
   cancel => sub { $_[0]->cancel },
);

done_testing;
