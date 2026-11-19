#!/usr/bin/env bash
#
# mayhem/build.sh — build less's fuzz targets and its own test suite.
#
# Runs inside the commit image as `mayhem` in /mayhem. The base exports CC/CXX/SANITIZER_FLAGS/
# DEBUG_FLAGS/SRC.
#
# Layout (all build directories are under mayhem/build-*/, gitignored by mayhem/.gitignore; the
# distfiles Makefile.aut generates in the source root — configure, defines.h.in, funcs.h, help.c,
# lessmsg.inc — are gitignored by upstream's .gitignore and regenerated here):
#   mayhem/build-fuzz/  less (LESSTEST build) + less_env, afl-clang-fast + ASan/UBSan + DWARF 3.
#                       These are the AFL file-input targets (`afl: true`): less is a CLI whose
#                       every path ends in exit() (quit()), so it is fuzzed through its own main.
#   mayhem/build-test/  the same programs with upstream's normal flags, plus upstream's lesstest
#                       driver + lt_screen terminal emulator, for mayhem/test.sh.
# Target binaries: /mayhem/mayhem/build-fuzz/less_t and /mayhem/mayhem/build-fuzz/less_env.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS COVERAGE_FLAGS
export AFL_QUIET=1

cd "$SRC"

# 0) Upstream's git tree carries no configure/funcs.h/help.c; its authoring Makefile makes them
#    (autoheader+autoconf, perl mkhelp). Offline and idempotent.
make -f Makefile.aut help.c funcs.h lessmsg.inc ./configure

# 1) Fuzz build: AFL-instrumented, sanitized, DWARF 3. --with-regex=regcomp-local makes the
#    search/pattern code use less's own regexp.c so it is instrumented too.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
mkdir -p mayhem/build-fuzz
cd mayhem/build-fuzz
afl-clang-fast $FUZZ_CFLAGS -c "$SRC/mayhem/lsan_off.c" -o lsan_off.o
if [ ! -f config.status ]; then
  "$SRC/configure" CC=afl-clang-fast CFLAGS="$FUZZ_CFLAGS" LDFLAGS="$FUZZ_CFLAGS" \
    --with-regex=regcomp-local
fi
make -j"$MAYHEM_JOBS" LESSTEST=1 LDFLAGS="$FUZZ_CFLAGS $PWD/lsan_off.o" less_t
# less_env: the same objects with main.c renamed to less_main, behind mayhem/less_env_main.c,
# for the inputs less takes through environment variables ($LESS, $LESSHISTFILE) and the
# tags target, which runs less in a scratch directory holding the input as ./tags.
LIBS=$(sed -n 's/^LIBS *= *//p' Makefile | sed 's/$(LIBSAN)//')
afl-clang-fast -I. -I"$SRC" -DBINDIR=\"/usr/local/bin\" -DLIBEXECDIR=\"/usr/local/libexec\" \
  -DSYSDIR=\"/usr/local/etc\" -DLESSTEST -DUSE_TERMCAP $FUZZ_CFLAGS -Dmain=less_main \
  -c "$SRC/main.c" -o main_renamed.o
afl-clang-fast $FUZZ_CFLAGS -c "$SRC/mayhem/less_env_main.c" -o less_env_main.o
# shellcheck disable=SC2086
afl-clang-fast $FUZZ_CFLAGS -o less_env less_env_main.o main_renamed.o \
  $(ls ./*.t.o | grep -v '^./main\.t\.o$') lsan_off.o $LIBS
cd "$SRC"

# 2) Test build: upstream's normal configure (-O2, the default regex library, i.e. glibc
#    regcomp, which matches multibyte text the way upstream's recorded sessions expect),
#    LESSTEST so lesstest can drive it, plus the lesstest tools themselves.
mkdir -p mayhem/build-test/lesstest
cd mayhem/build-test
if [ ! -f config.status ]; then
  env -u CFLAGS -u LDFLAGS "$SRC/configure" CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" \
    LDFLAGS="$COVERAGE_FLAGS"
fi
make -j"$MAYHEM_JOBS" LESSTEST=1 less_t
TERMLIB=$(sed -n 's/^LIBS *= *//p' Makefile | sed 's/$(LIBSAN)//')
make -C lesstest -f "$SRC/lesstest/Makefile" -j"$MAYHEM_JOBS" VPATH="$SRC/lesstest" \
  srcdir="$SRC/lesstest" CC="$CC" CFLAGS="-O2 -I$SRC/lesstest" TERMLIB="$TERMLIB" lesstest lt_screen
cd "$SRC"

for b in mayhem/build-fuzz/less_t mayhem/build-fuzz/less_env mayhem/build-test/less_t \
         mayhem/build-test/lesstest/lesstest mayhem/build-test/lesstest/lt_screen; do
  [ -x "$b" ] || { echo "build.sh: missing $b" >&2; exit 1; }
done
