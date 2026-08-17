#!/usr/bin/perl
# A Coro::Atomic section must suppress this module for its duration, overriding
# both the global enable and any scoped_enable/scoped_disable.

use strict;

use Test::More;

BEGIN { $ENV{PERL_ANYEVENT_MODEL} = "EV" }

# Everything needed to observe a real interpreter release: an event loop (the
# reacquire is serviced from it), Coro's atomic support, and some XS function
# that is actually perlmulticore-enabled.  Checked in a BEGIN so skip_all runs
# before "use Coro::Atomic" below is compiled.
BEGIN {
   eval { require EV; require Coro::EV; 1 }
      or plan skip_all => "EV and Coro::EV are needed to run the event loop";

   eval { require Coro::Atomic; 1 }
      or plan skip_all => "this Coro has no Coro::Atomic";

   eval { require Digest::MD5; 1 }
      or plan skip_all => "Digest::MD5 not available";

   $Digest::MD5::PERLMULTICORE_SUPPORT
      or plan skip_all => "this Digest::MD5 is not perlmulticore-enabled";
}

use Coro;
use Coro::Multicore;    # import enables globally
use Coro::Atomic;

plan tests => 9;

alarm 120;              # don't hang the suite if a handshake stalls

# Big enough that the release window (~80ms here) dwarfs the thread handoff, so
# the control below is not a race.  md5 is the documented reentrant-anywhere
# entry point, so it is safe to call from several coros.
my $BUF = "x" x (64 * 1024 * 1024);
my $WANT = Digest::MD5::md5_hex ($BUF);

# Did any other coro thread get to run while $code executed?  A one-shot coro is
# used rather than a ticking loop deliberately: a coro that never blocks would
# starve the event loop that services the reacquire, and deadlock.
sub other_coro_ran(&) {
   my $code = shift;
   my $ran  = 0;
   my $c    = async { $ran = 1 };

   $code->();

   my $seen = $ran;
   $c->cancel unless $ran;   # never got to run - don't leak it
   $seen;
}

my $body = async {
   ok Coro::Multicore::enable (), "multicore is globally enabled";

   # Control: without this passing, the assertions below prove nothing, because
   # they would also hold if multicore never engaged at all.
   ok other_coro_ran { Digest::MD5::md5 ($BUF) },
      "control: a released md5 outside atomic lets another coro run";

   # Inside an atomic section the release must be suppressed: no other coro runs,
   # and it must degrade silently rather than croak (before this was implemented
   # the worker's CORO_SCHEDULE tripped the atomic check and the exception came
   # back through the transfer's JMPENV).
   my ($ran, $digest, $err);
   my $ok = eval {
      atomic {
         $ran = other_coro_ran { $digest = Digest::MD5::md5_hex ($BUF) };
      };
      1;
   };
   $err = $@ unless $ok;

   is $err, undef, "a multicore-enabled call inside atomic does not croak";
   ok !$ran, "no other coro ran inside atomic (release suppressed)";
   is $digest, $WANT, "and it still computes the right answer, just inline";

   # An explicit scoped_enable inside the section must not win over it.
   my $ran2;
   atomic {
      Coro::Multicore::scoped_enable;
      $ran2 = other_coro_ran { Digest::MD5::md5 ($BUF) };
   };
   ok !$ran2, "atomic overrides an explicit scoped_enable";

   # Nesting: the atomic depth is a counter, so suppression must hold at any
   # depth - and must still hold after an inner section exits while an outer one
   # is live (a boolean flag would have been cleared by the inner leave).
   my ($ran_deep, $ran_after_inner);
   atomic { atomic { $ran_deep = other_coro_ran { Digest::MD5::md5 ($BUF) } } };
   ok !$ran_deep, "suppressed inside a nested atomic section";

   atomic {
      atomic { };
      $ran_after_inner = other_coro_ran { Digest::MD5::md5 ($BUF) };
   };
   ok !$ran_after_inner, "still suppressed after an inner section exits";

   # Regression: Coro's own yield enforcement still fires.
   my $croaked = !eval { atomic { Coro::cede }; 1 };
   ok $croaked && $@ =~ /atomic/, "an explicit cede inside atomic still croaks";

   EV::break;
};

Coro::Multicore::scoped_disable;   # the event loop itself must not use multicore
EV::run;
