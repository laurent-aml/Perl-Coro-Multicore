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

# CoroAPI revision 4 (Coro 6.5701) publishes the atomic depth, which is what
# lets an atomic {} section suppress multicore for its duration.  Without it the
# module still builds and works, minus that protection - see the note in
# Multicore.xs and has_atomic_support ().
#
# Find CoroApi.h following @INC path, to be consistent with the loaded Coro.pm.
{
   my $want     = 4;
   my $want_ver = 6.5701;   # the Coro that ships revision $want

   my $rev_of = sub {
      my ($dir) = @_;
      defined $dir or return;
      open my $fh, "<", "$dir/Coro/CoroAPI.h" or return;
      local $/;
      my $txt = <$fh>;
      $txt =~ /^\s*#\s*define\s+CORO_API_REVISION\s+(\d+)/m ? $1 : 0
   };

   # The Coro that will be LOADED: the first Coro.pm along @INC.  Read rather
   # than required, so a Coro that cannot bootstrap here (wrong perl, half-built
   # tree) does not take the build down with it.
   my ($coro_pm, $coro_ver);
   for my $d (@INC) {
      next unless -e "$d/Coro.pm";
      $coro_pm = "$d/Coro.pm";
      if (open my $fh, "<", $coro_pm) {
         while (<$fh>) {
            $coro_ver = $1, last if /^\s*our\s+\$VERSION\s*=\s*([\d._]+)\s*;/;
         }
      }
      last;
   }

   # The header that will be COMPILED against.
   my $hdr_dir = $Coro::MakeMaker::installsitearch;
   my $rev     = $rev_of->($hdr_dir);

   defined $rev
      or die "Cannot find Coro/CoroAPI.h - is Coro installed?\n";

   if (defined $coro_ver) {
      my $newer_module = $coro_ver >= $want_ver;
      my $newer_header = $rev >= $want;

      if ($newer_module != $newer_header) {
         my ($a, $b) = $newer_module
            ? ("Coro $coro_ver, which ships CoroAPI revision $want",
               "a CoroAPI.h that declares revision $rev")
            : ("Coro $coro_ver, which predates CoroAPI revision $want",
               "a CoroAPI.h that declares revision $rev");

         die <<EOF;

***
*** Inconsistent Coro - stopping rather than building something that would not
*** load.
***
*** The module that would be loaded and the header that would be compiled against
*** do not belong together:
***   loads    $coro_pm  ($a)
***   compiles $hdr_dir/Coro/CoroAPI.h  ($b)
***
*** perl loads the first Coro.pm along \@INC, while Coro::MakeMaker takes the
*** first CoroAPI.h along \$Config{sitearch} and then \@INC - so an older Coro
*** installed in sitearch can supply the header for a newer one in PERL5LIB.
*** I_CORO_API () refuses such a mismatch at load time.
***
*** Point both at the same Coro: put its directory first in PERL5LIB, or remove
*** the one that does not belong to this build.
***
EOF
      }
   }

   if ($rev >= $want) {
      print "Using CoroAPI.h revision $rev from $hdr_dir: atomic {} sections will suppress multicore.\n";
   } else {
      warn <<EOF;

***
*** The Coro being built against is older than $want_ver:
***   $hdr_dir/Coro/CoroAPI.h declares CoroAPI revision $rev.
***
*** Building anyway, WITHOUT atomic-section support: a multicore-enabled XS call
*** inside a Coro::Atomic section will break the section instead of running
*** inline for its duration.  Coro::Multicore::has_atomic_support() will be false.
***
*** To get it, build against Coro $want_ver or later.
***
EOF
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

