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
#  The codes check asks the tool to explain every code it lists and holds
#  the list to `codes/codes.ldn` and to what the cases expect.  With REFINE,
#  the dispatcher check runs the tool through `refine` as a contributed
#  command: a build, help, a forwarded explanation and a completion.
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
    if ! (cd "$root" && env -u LANDIN_REFINE "$build" --refine "$refine" > "$scratch/self.said" 2>&1); then
        cat "$scratch/self.said"
        echo "FAILED self-build: the tool did not build itself"
        failed=$((failed + 1))
    elif ! cmp "$build" "$root/.landin/steps/tool/out/refine-build"; then
        echo "FAILED self-build: the tool built differs from the tool that built it"
        failed=$((failed + 1))
    fi
fi
#  Every code the tool can print is explained.  `explain` lists the codes;
#  each has to explain itself, each atom of `codes/codes.ldn` has to be in
#  the list, and no `expected` may show a code the list lacks.
count=$((count + 1))
root=$(dirname "$here")
"$build" explain > "$scratch/codes"
catalogue=ok
while IFS= read -r code; do
    if ! "$build" explain "$code" > "$scratch/explained" 2>&1 \
        || [ "$(wc -l < "$scratch/explained")" -lt 2 ]; then
        echo "FAILED codes: $code is not explained"
        catalogue=no
    fi
done < "$scratch/codes"
#  `unknown` is the one atom there that is no code.
declared=$(($(grep -c '^public [a-z_]*: atom$' "$root/codes/codes.ldn") - 1))
listed=$(wc -l < "$scratch/codes")
if [ "$declared" -ne "$listed" ]; then
    echo "FAILED codes: codes.ldn declares $declared codes and \`explain\` lists $listed"
    catalogue=no
fi
grep -h -o 'error\[[A-Z]*[0-9]*\]' "$here"/cases/*/expected \
    | sed 's/error\[\(.*\)\]/\1/' | sort -u > "$scratch/expected-codes"
while IFS= read -r code; do
    if ! grep -q -x "$code" "$scratch/codes"; then
        echo "FAILED codes: a case expects $code, which \`explain\` does not list"
        catalogue=no
    fi
done < "$scratch/expected-codes"
[ "$catalogue" = ok ] || failed=$((failed + 1))
#  Through refine's dispatcher, as a contributed command on PATH.  `refine`
#  reserves the word `build` and dispatches nothing under it, so the tool
#  is put on PATH as `refine-bld`: a wrapper that changes the name in what
#  `--describe` answers and nothing else.
if [ -n "$refine" ]; then
    count=$((count + 1))
    tools=$scratch/tools
    mkdir "$tools"
    {
        echo '#!/bin/sh'
        # shellcheck disable=SC2016  # written into the wrapper as it stands
        echo 'if [ "$1" = --describe ]; then'
        echo "    \"$build\" --describe | sed 's/\"name\":\"build\"/\"name\":\"bld\"/'"
        echo 'else'
        echo "    exec \"$build\" \"\$@\""
        echo 'fi'
    } > "$tools/refine-bld"
    chmod +x "$tools/refine-bld"
    dispatched=ok
    #  ran WHAT COMMAND...: run COMMAND with the tool on PATH, keep what it
    #  said in $scratch/ran, and fail the check when it did not end with 0.
    #  The caller's LANDIN_REFINE names nothing: refine replaces it.
    ran() {
        what=$1
        shift
        if ! PATH="$tools:$PATH" LANDIN_REFINE=/nowhere/refine "$@" \
            > "$scratch/ran" 2>&1; then
            cat "$scratch/ran"
            echo "FAILED dispatcher: $what"
            dispatched=no
        fi
    }
    #  holds WHAT TEXT: what the last command said has the line TEXT.
    holds() {
        if ! grep -q -x -F -e "$2" "$scratch/ran"; then
            cat "$scratch/ran"
            echo "FAILED dispatcher: $1"
            dispatched=no
        fi
    }
    #  The refine that dispatched is the one the steps run: no --refine.
    rm -rf "$root/.landin/steps"
    cd "$root"
    ran "refine bld did not build this package" "$refine" bld
    if ! cmp "$build" "$root/.landin/steps/tool/out/refine-build"; then
        echo "FAILED dispatcher: refine bld built something else than the tool"
        dispatched=no
    fi
    ran "refine help did not run" "$refine" help
    holds "refine help does not list the command" \
        "  bld         Run the steps of a package's recipe ($tools/refine-bld)"
    ran "refine help bld did not run" "$refine" help bld
    holds "refine help bld is not the tool's own help" \
        "usage: refine-build [--refine PATH] [--check] [STEP...]"
    ran "refine explain RB0102 was not forwarded" "$refine" explain RB0102
    holds "the forwarded explanation is not announced as the tool's" \
        "RB0102 is explained by refine-bld at $tools/refine-bld, not by Landin"
    holds "the forwarded explanation is not the tool's" \
        "Every line starts with a keyword, and this one starts with a"
    ran "refine bld --complete did not run" "$refine" bld --complete -- --ch
    holds "completion through refine does not offer the option" "--check"
    cd "$here"
    [ "$dispatched" = ok ] || failed=$((failed + 1))
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
