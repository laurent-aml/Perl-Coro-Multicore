use ExtUtils::MakeMaker;
use Coro::MakeMaker;
use Config;

use Canary::Stability Coro::Multicore => 1, 5.008009;

if ($^O eq "MSWin32") {
   # configuration on windows is hardcoded - as always

   print STDERR <<EOF;

***
*** Your platform is not standards compliant. To get this module working, you need to
*** have the win32 pthread library (http://sourceware.org/pthreads-win32/) and
*** the windows sdk or equivalent.
***

EOF

   $INC  = "$ENV{INC}";
   $LIBS = ["$ENV{LIBS} -lpthread"];

} else {

   $INC  = "";
   $LIBS = ['-lpthread', '-lpthreads', ''];

   if ($^O =~ /bsd/i) {
      print <<EOF;

If you have problems with deadlocks or crashes on your system,
make sure your perl has been linked with -lpthread (you might try
LD_PRELOAD=/path/to/libpthread.so as a workaround). Also, pthread support
under many BSDs is not the best - before reporting a bug in this module,
make sure it's not an OS bug.

EOF
   }
}

if ($^O =~ /linux/ && $Config{usemymalloc} eq "y") {
   print <<EOF;

***
*** WARNING:
***
*** Your perl uses its own memory allocator (-Dusemymalloc=y),
*** which is known not to be threadsafe on GNU/Linux and probably
*** other platforms (even when not used concurrently, it trashes
*** the data structures of the system malloc running concurrently),
*** for perls up to 5.8.8 and possibly later versions.
***
*** If you are unsure wether your perl has been fixed, your system
*** is safe for other reasons, or you experience spurious segfaults,
*** please compile your perl with -Dusemymalloc=n.
***

EOF
}

print <<EOF;

*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***

Coro::Multicore can do some simple checks to make sure perlinterp_release
is called only with a valid perl context, and perlinterp_acquire without
ensuring that they are always called in proper pairs. This is very useful
while developing XS modules using perlmulticore.h.

This costs a bit of performance though, so it is disabled by default.

The environment variable CORO_MULTICORE_CHECK can be used to set a
default for this answer.

EOF

my $extra = prompt ("Enable extra checks?", $ENV{CORO_MULTICORE_CHECK} ? "y" : "n") =~ /[Yy]/;

my $define = sprintf "-DRECURSION_CHECK=%d", $extra;

# EXPERIMENTAL: if this perl ships the core "offload" hook (perlmulticore.h in
# CORE/ exposing multicore_register_offload), compile the optional offload
# backend too. It stays OFF unless Coro::Multicore::enable_offload(1) is
# called, so this only ever *adds* a dormant, opt-in code path.
{
   my $core_h = "$Config{archlibexp}/CORE/perlmulticore.h";
   if (open my $fh, "<", $core_h) {
      local $/;
      my $txt = <$fh>;
      if ($txt =~ /multicore_register_offload/) {
         $define .= " -DHAVE_MULTICORE_OFFLOAD";
         print "Detected core multicore offload hook -> building experimental offload backend (off by default).\n";
      }
   }
}

WriteMakefile(Coro::MakeMaker::coro_args(
    dist	=> {
	            PREOP	=> 'pod2text Multicore.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
	            COMPRESS	=> 'gzip -9v',
	            SUFFIX	=> '.gz',
	           },
    NAME => "Coro::Multicore",
    VERSION_FROM => "Multicore.pm",
    CONFIGURE_REQUIRES => { "ExtUtils::MakeMaker" => 6.52, "Canary::Stability" => 0, "Coro" => 6.44 },
    TEST_REQUIRES => { "Coro" => 6.44 },
    DEFINE       => $define,
    PREREQ_PM    => { "Coro" => 6.44, "AnyEvent" => 7 },
    INC          => $INC,
    LIBS         => $LIBS,
));

