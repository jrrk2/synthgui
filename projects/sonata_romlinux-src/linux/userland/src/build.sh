#!/bin/sh
# Compile the programs in /usr/src into /tmp (RAM: they are gone after a reboot; run this again).
#
#   build.sh                   compile every .c here           (about 50 s each on the 50 MHz core)
#   build.sh hello plasma      compile just these
#   OUT=/tmp/bin build.sh      put the programs in another directory (it is created)
#
# Then run one, for example:  /tmp/hello   /tmp/plasma 60   /tmp/mandel   /tmp/life
# The link line names libc and then libgcc.a explicitly: libgcc.a (floating point, long long division) must come after
# libc, and naming it is harmless where tcc already adds it.
src=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-/tmp}
mkdir -p "$out" || exit 1
progs=$*
[ -z "$progs" ] && progs=$(cd "$src" && ls *.c | sed 's/\.c$//')
fail=0
for p in $progs; do
    if [ ! -f "$src/$p.c" ]; then
        echo "build.sh: no $src/$p.c" >&2
        fail=1
        continue
    fi
    echo "tcc $p.c -> $out/$p"
    if tcc -static "$src/$p.c" -o "$out/$p" -lc /usr/lib/libgcc.a; then
        :
    else
        echo "build.sh: $p failed" >&2
        fail=1
    fi
done
exit $fail
