#!/bin/sh
#  Runs refine-build over the small projects in tests/cases and compares
#  what it says and how it ends with each case's `expected`.
#
#  Usage: tests/run.sh BUILD [REFINE] [--record]
#
#  BUILD is the refine-build to test.  With REFINE, a refine to compile
#  with, the last check has BUILD build this package from its own recipe
#  and compares the result with BUILD byte for byte.  --record writes each
#  `expected` anew from what the tool said; read the difference before
#  keeping it.
#
#  The memory check repeats a whole build in one process with the tool's
#  `--repeat N`, a few times and many times, and fails when the many use
#  more memory than the few: a build gives back all it took.  It needs a
#  `time` program that takes `-f %M`, GNU's, and says so when there is none.
#
#  A case is a directory: `command` holds the arguments, one line of plain
#  words; `expected` what both streams said, then `[exit N]`; `produces`,
#  when it is there, the files that must exist afterwards.  Each case runs
#  in a copy, so nothing is written into the tree.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
build=$(realpath "$1")
refine=
record=no
shift
for word in "$@"; do
    case $word in
        --record) record=yes ;;
        *) refine=$(realpath "$word") ;;
    esac
done
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
failed=0
count=0
for case in "$here"/cases/*/; do
    name=$(basename "$case")
    count=$((count + 1))
    cp -R "$case" "$scratch/$name"
    status=0
    # shellcheck disable=SC2046  # the arguments are plain words by contract
    (cd "$scratch/$name" && "$build" $(cat command)) \
        > "$scratch/$name.said" 2>&1 || status=$?
    echo "[exit $status]" >> "$scratch/$name.said"
    sed -i "s#$scratch/$name#PROJECT#g" "$scratch/$name.said"
    if [ "$record" = yes ]; then
        cp "$scratch/$name.said" "$case/expected"
    elif ! diff -u "$case/expected" "$scratch/$name.said"; then
        echo "FAILED $name: said something else than expected"
        failed=$((failed + 1))
        continue
    fi
    if [ -f "$case/produces" ]; then
        while IFS= read -r path; do
            if [ ! -e "$scratch/$name/$path" ]; then
                echo "FAILED $name: did not produce $path"
                failed=$((failed + 1))
            fi
        done < "$case/produces"
    fi
done
if [ -n "$refine" ]; then
    count=$((count + 1))
    root=$(dirname "$here")
    if ! (cd "$root" && "$build" --refine "$refine" > "$scratch/self.said" 2>&1); then
        cat "$scratch/self.said"
        echo "FAILED self-build: the tool did not build itself"
        failed=$((failed + 1))
    elif ! cmp "$build" "$root/.landin/steps/tool/out/refine-build"; then
        echo "FAILED self-build: the tool built differs from the tool that built it"
        failed=$((failed + 1))
    fi
fi
#  peak NAME ARGUMENTS...: the peak resident size, in KiB, of the tool
#  run in the case NAME with ARGUMENTS.
peak() {
    name=$1
    shift
    (cd "$scratch/$name" && env time -f %M -o "$scratch/peak" "$build" "$@" \
        > /dev/null 2>&1) || { echo "FAILED memory: $name $* did not run"; return 1; }
    tail -n 1 "$scratch/peak"
}
#  steady WHAT NAME FEW MANY ARGUMENTS...: MANY builds may take no more than
#  FEW do, but for the slack a page or two of the heap's own makes.
slack=256
steady() {
    what=$1 name=$2 few=$3 many=$4
    shift 4
    count=$((count + 1))
    small=$(peak "$name" "$@" --repeat "$few") || { failed=$((failed + 1)); return 0; }
    large=$(peak "$name" "$@" --repeat "$many") || { failed=$((failed + 1)); return 0; }
    echo "memory, $what: $few builds peak at $small KiB, $many at $large KiB"
    if [ "$large" -gt $((small + slack)) ]; then
        echo "FAILED memory, $what: memory grows with the number of builds"
        failed=$((failed + 1))
    fi
}
if env time -f %M true > /dev/null 2>&1; then
    steady "read and check" steps-run 10 20000 --check
    steady "read, check and run" steps-run 2 200
else
    echo "memory check not run: no \`time\` program that takes -f %M"
fi
if [ "$failed" -gt 0 ]; then
    echo "$failed of $count failed"
    exit 1
fi
if [ -n "$refine" ]; then
    echo "$count passed"
else
    echo "$count passed; self-build not run, since no refine was given"
fi
