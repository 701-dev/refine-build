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
#  The store checks build a small project against stores of their own and
#  look at what ran, what was kept and what the store holds: a second build
#  starts no program, an edit runs what depends on it, an output that did
#  not change keeps what takes it, a kept step says what it said, `always`
#  and `--again` run, a failed step leaves no key and no entry, two builds
#  at once leave one entry a step, and a store of another form is refused.
#
#  The hash checks go through `--hash-file` and `--hash-tree`, options for
#  these tests only.  SHA-256 is held to the FIPS 180-4 examples, to lengths
#  around a block's edges and to `sha256sum` on real files, read in chunks
#  of several sizes.  The tree hash is held to a hash written here, which a
#  few lines of Python make again from the form `hash/tree/tree.ldn`
#  describes, and to what must and must not change it.  They need
#  `sha256sum` and `python3` and say so when one is missing.
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
#  A store's entries are read-only, so they are made writable to be removed.
trap 'chmod -R u+w "$scratch" 2> /dev/null; rm -rf "$scratch"' EXIT
#  No test touches the user's store: every build here finds its store
#  under the scratch directory, each case one of its own.
export XDG_CACHE_HOME="$scratch/cache"
failed=0
count=0
for case in "$here"/cases/*/; do
    name=$(basename "$case")
    count=$((count + 1))
    cp -R "$case" "$scratch/$name"
    status=0
    # shellcheck disable=SC2046  # the arguments are plain words by contract
    (cd "$scratch/$name" && XDG_CACHE_HOME="$scratch/cache-$name" \
        "$build" $(cat command)) > "$scratch/$name.said" 2>&1 || status=$?
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
    if ! (cd "$root" && env -u LANDIN_REFINE "$build" --refine "$refine" \
        --store "$scratch/self-store" > "$scratch/self.said" 2>&1); then
        cat "$scratch/self.said"
        echo "FAILED self-build: the tool did not build itself"
        failed=$((failed + 1))
    elif ! cmp "$build" "$root/.landin/out/tool/refine-build"; then
        echo "FAILED self-build: the tool built differs from the tool that built it"
        failed=$((failed + 1))
    else
        #  A second build keeps both steps: nothing changed.
        (cd "$root" && env -u LANDIN_REFINE "$build" --refine "$refine" \
            --store "$scratch/self-store" > "$scratch/self.said" 2>&1) || true
        if [ "$(cat "$scratch/self.said")" != "step tool: kept
step fetcher: kept
step checked: kept" ]; then
            cat "$scratch/self.said"
            echo "FAILED self-build: a second build does not keep every step"
            failed=$((failed + 1))
        elif ! cmp "$build" "$root/.landin/out/tool/refine-build"; then
            echo "FAILED self-build: the tool kept differs from the tool that built it"
            failed=$((failed + 1))
        fi
    fi
fi
#  refine-fetch, which the self-build made, and building with what it
#  fetched: tests/fetch.sh, whose checks are counted here.
if [ -n "$refine" ] && [ -x "$(dirname "$here")/.landin/out/fetcher/refine-fetch" ]; then
    mkdir "$scratch/fetching"
    cp "$(dirname "$here")/.landin/out/fetcher/refine-fetch" "$scratch/refine-fetch"
    "$here/fetch.sh" "$scratch/refine-fetch" "$build" "$refine" "$scratch/fetching" \
        > "$scratch/fetch.said" 2>&1 || true
    grep -v '^fetch checks: ' "$scratch/fetch.said" || true
    tally=$(grep '^fetch checks: ' "$scratch/fetch.said" || echo "fetch checks: 1 run, 1 failed")
    count=$((count + $(echo "$tally" | sed 's/^fetch checks: \([0-9]*\) run.*/\1/')))
    failed=$((failed + $(echo "$tally" | sed 's/.*, \([0-9]*\) failed$/\1/')))
elif [ -n "$refine" ]; then
    count=$((count + 1))
    failed=$((failed + 1))
    echo "FAILED fetch: the self-build made no refine-fetch to check"
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
    rm -rf "$root/.landin/steps" "$root/.landin/out"
    cd "$root"
    ran "refine bld did not build this package" "$refine" bld
    if ! cmp "$build" "$root/.landin/out/tool/refine-build"; then
        echo "FAILED dispatcher: refine bld built something else than the tool"
        dispatched=no
    fi
    ran "refine help did not run" "$refine" help
    holds "refine help does not list the command" \
        "  bld         Run the steps of a package's recipe ($tools/refine-bld)"
    ran "refine help bld did not run" "$refine" help bld
    holds "refine help bld is not the tool's own help" \
        "usage: refine-build [--refine PATH] [--store PATH] [--again] [--raw]"
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
#  SHA-256, through --hash-file.
#  sums WHAT FILE EXPECTED [CHUNK]: the tool's hash of FILE is EXPECTED.
hashes=ok
sums() {
    got=$("$build" --hash-file "$2" ${4:+--chunk "$4"} 2>&1) || true
    if [ "$got" != "$3" ]; then
        echo "FAILED sha256: $1${4:+ in chunks of $4}: $got, not $3"
        hashes=no
    fi
}
count=$((count + 1))
vectors=$scratch/vectors
mkdir "$vectors"
: > "$vectors/empty"
printf 'abc' > "$vectors/abc"
printf 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' > "$vectors/448"
printf 'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu' > "$vectors/896"
head -c 1000000 /dev/zero | tr '\0' a > "$vectors/million"
sums "the empty message" "$vectors/empty" \
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
sums "abc" "$vectors/abc" \
    ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
sums "the 448-bit message" "$vectors/448" \
    248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
sums "the 896-bit message" "$vectors/896" \
    cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1
for chunk in "" 63 64 65 4096; do
    sums "a million a" "$vectors/million" \
        cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0 "$chunk"
done
if command -v sha256sum > /dev/null 2>&1; then
    #  Around the edges of a block and of the padding: 55 bytes are the
    #  most that share a block with the length, 64 fill one.
    for length in 0 1 54 55 56 57 62 63 64 65 119 120 121 127 128 129; do
        head -c "$length" "$build" > "$vectors/edge"
        want=$(sha256sum < "$vectors/edge" | cut -d' ' -f1)
        for chunk in "" 1 3 64; do
            sums "$length bytes" "$vectors/edge" "$want" "$chunk"
        done
    done
    for real in "$build" "$here/run.sh" "$here/../README.md"; do
        want=$(sha256sum < "$real" | cut -d' ' -f1)
        for chunk in "" 61 4096 100000; do
            sums "$(basename "$real")" "$real" "$want" "$chunk"
        done
    done
else
    echo "sha256 not compared with sha256sum: there is none"
fi
[ "$hashes" = ok ] || failed=$((failed + 1))
#  The tree hash, through --hash-tree.
#  planted DIRECTORY ORDER: make the fixed tree in DIRECTORY, its entries
#  made in one order or the other.
planted() {
    mkdir -p "$1"
    if [ "$2" = forwards ]; then
        mkdir -p "$1/a" "$1/dir/empty"
        printf 'hello\n' > "$1/a/one.txt"
        : > "$1/a.b"
        printf '#!/bin/sh\n' > "$1/run.sh"
        chmod 755 "$1/run.sh"
        ln -s a/one.txt "$1/link"
        ln -s /outside/the/tree "$1/away"
    else
        ln -s /outside/the/tree "$1/away"
        ln -s a/one.txt "$1/link"
        printf '#!/bin/sh\n' > "$1/run.sh"
        chmod 755 "$1/run.sh"
        mkdir -p "$1/dir/empty"
        : > "$1/a.b"
        mkdir "$1/a"
        printf 'hello\n' > "$1/a/one.txt"
    fi
    chmod 644 "$1/a/one.txt" "$1/a.b"
}
#  tree DIRECTORY [NAME...]: the tool's hash of the tree, NAMEs left out.
tree() {
    directory=$1
    shift
    leaving=
    for left in "$@"; do leaving="$leaving --leave $left"; done
    # shellcheck disable=SC2086  # the names are plain words
    "$build" --hash-tree "$directory" $leaving 2>&1 || true
}
#  differs WHAT DIRECTORY: the tree's hash is another than the fixed one.
differs() {
    if [ "$(tree "$2")" = "$fixed" ]; then
        echo "FAILED tree hash: $1 does not change it"
        trees=no
    fi
}
count=$((count + 1))
trees=ok
fixed=ced509cf639a5553d1294cd6009e269a9f92458c03db123f5af7ec4326110092
planted "$scratch/tree" forwards
planted "$scratch/tree-back" backwards
if [ "$(tree "$scratch/tree")" != "$fixed" ]; then
    echo "FAILED tree hash: the fixed tree hashes to $(tree "$scratch/tree"), not $fixed"
    trees=no
fi
if [ "$(tree "$scratch/tree-back")" != "$fixed" ]; then
    echo "FAILED tree hash: the same tree made in another order hashes differently"
    trees=no
fi
if command -v python3 > /dev/null 2>&1; then
    again=$(python3 "$here/tree_hash.py" "$scratch/tree")
    if [ "$again" != "$fixed" ]; then
        echo "FAILED tree hash: tests/tree_hash.py makes $again, not $fixed"
        trees=no
    fi
    again=$(python3 "$here/tree_hash.py" "$scratch/tree" dir away)
    if [ "$again" != "$(tree "$scratch/tree" dir away)" ]; then
        echo "FAILED tree hash: tests/tree_hash.py and the tool differ on a tree with entries left out"
        trees=no
    fi
else
    echo "tree hash not made a second time: there is no python3"
fi
#  vary NAME: a fresh copy of the fixed tree, to change one thing in.
vary() {
    varied=$scratch/tree-$1
    planted "$varied" forwards
}
vary content; printf 'hullo\n' > "$varied/a/one.txt"
differs "a file's content" "$varied"
vary length; printf 'hello\n\n' > "$varied/a/one.txt"
differs "a file's length" "$varied"
vary name; mv "$varied/a.b" "$varied/a.c"
differs "a file's name" "$varied"
vary bit; chmod 644 "$varied/run.sh"
differs "the execute bit" "$varied"
vary target; ln -sfn a/two.txt "$varied/link"
differs "a link's target" "$varied"
vary empty; mkdir "$varied/dir/another"
differs "an added empty directory" "$varied"
vary kind; rm "$varied/a.b"; mkdir "$varied/a.b"
differs "a file become a directory" "$varied"
#  What does not count: a time, and a permission bit other than the
#  owner's execute bit.
vary same; touch -d '2001-01-01' "$varied/a/one.txt"; chmod 600 "$varied/a.b"
if [ "$(tree "$varied")" != "$fixed" ]; then
    echo "FAILED tree hash: a file's time or its read bits change it"
    trees=no
fi
#  An entry left out is as good as absent, but only in the root.
vary left; mkdir -p "$varied/.landin/x" "$varied/dir/.landin"
if [ "$(tree "$varied" .landin)" = "$fixed" ]; then
    echo "FAILED tree hash: --leave also leaves out a name below the root"
    trees=no
fi
rmdir "$varied/dir/.landin"
if [ "$(tree "$varied" .landin)" != "$fixed" ]; then
    echo "FAILED tree hash: an entry of the root that is left out changes it"
    trees=no
fi
#  What has no record is refused.
vary pipe; mkfifo "$varied/dir/pipe"
said=$(cd "$scratch" && "$build" --hash-tree tree-pipe 2>&1) && status=0 || status=$?
if [ "$status" -ne 1 ] || [ "${said%%:*}" != "error[RB0501]" ]; then
    echo "FAILED tree hash: a named pipe is not refused with RB0501: $said"
    trees=no
fi
[ "$trees" = ok ] || failed=$((failed + 1))
#  The store.  A small project is built several times against stores under
#  the scratch directory; each step's program adds a line to a log, so a
#  step that was kept and not run shows in the log's length.
count=$((count + 1))
stores=ok
log=$scratch/ran.log
#  planted_project DIRECTORY: two steps, the second taking the first's
#  output; the first says something on each stream.
planted_project() {
    mkdir -p "$1/notes"
    printf 'hello\n' > "$1/notes/a.txt"
    printf 'package dev701/demo\nkind library\n' > "$1/landin.package"
    {
        echo 'step upper from notes/a.txt'
        echo "    run sh -c \"echo upper >> $log; tr a-z A-Z < notes/a.txt > \$0/a.txt; echo made; echo warned >&2\" {out}"
        echo 'step count with upper'
        echo "    run sh -c \"echo count >> $log; wc -c < upper/a.txt > \$0/count; echo counted\" {out}"
    } > "$1/landin.recipe"
}
#  builds WHAT DIRECTORY STORE [ARGUMENTS...]: build there, each stream
#  kept apart in $scratch/out and $scratch/err; fail the check when the
#  build does not end with 0.
builds() {
    what=$1 directory=$2 kept_in=$3
    shift 3
    if ! (cd "$directory" && "$build" --store "$kept_in" "$@" \
        > "$scratch/out" 2> "$scratch/err"); then
        cat "$scratch/out" "$scratch/err"
        echo "FAILED store: $what: the build failed"
        stores=no
    fi
}
#  said WHAT EXPECTED: the last build's standard output is EXPECTED.
said() {
    if [ "$(cat "$scratch/out")" != "$2" ]; then
        cat "$scratch/out"
        echo "FAILED store: $1"
        stores=no
    fi
}
#  logged WHAT LINES: the log has LINES lines.
logged() {
    if [ "$(wc -l < "$log")" -ne "$2" ]; then
        cat "$log"
        echo "FAILED store: $1"
        stores=no
    fi
}
: > "$log"
planted_project "$scratch/kept"
builds "a first build" "$scratch/kept" "$scratch/store"
said "a first build does not run both steps" "step upper
made
step count
counted"
cp "$scratch/err" "$scratch/err.first"
logged "a first build does not start both programs" 2
if [ "$(cat "$scratch/kept/.landin/out/upper/a.txt")" != HELLO ] \
    || [ "$(cat "$scratch/kept/.landin/out/count/count")" != 6 ]; then
    echo "FAILED store: .landin/out does not show what the steps made"
    stores=no
fi
builds "a second build" "$scratch/kept" "$scratch/store"
said "a second build does not keep both steps and say what they said" "step upper: kept
made
step count: kept
counted"
if [ "$(cat "$scratch/err")" != warned ] \
    || ! cmp -s "$scratch/err" "$scratch/err.first"; then
    echo "FAILED store: a kept step does not write what it wrote to standard error"
    stores=no
fi
logged "a second build starts a program" 2
#  Everything in an entry is read-only.
if [ -n "$(find "$scratch/store/entries" -mindepth 1 ! -type l -perm /222)" ]; then
    find "$scratch/store/entries" -mindepth 1 ! -type l -perm /222
    echo "FAILED store: an entry can be written to"
    stores=no
fi
if [ -n "$(ls "$scratch/store/tmp")" ]; then
    ls "$scratch/store/tmp"
    echo "FAILED store: a build that ended well left something in tmp"
    stores=no
fi
#  An input changed and its output with it: both steps run.
printf 'hello there\n' > "$scratch/kept/notes/a.txt"
builds "a build after an edit" "$scratch/kept" "$scratch/store"
said "an edited input does not run the steps that depend on it" "step upper
made
step count
counted"
logged "an edited input does not start both programs" 4
#  An input changed and its output not: the first step runs, makes the
#  entry it made before, and the second is kept.
printf 'HELLO there\n' > "$scratch/kept/notes/a.txt"
builds "a build after an edit that changes no output" "$scratch/kept" "$scratch/store"
said "a step whose input is the same entry as before is not kept" "step upper
made
step count: kept
counted"
logged "an unchanged entry starts the step that takes it" 5
builds "a build with --again" "$scratch/kept" "$scratch/store" --again
said "--again does not run every step" "step upper
made
step count
counted"
logged "--again does not start both programs" 7
#  A relative --store is a path from the project.
builds "a build with a relative store" "$scratch/kept" near
if [ ! -f "$scratch/kept/near/version" ]; then
    echo "FAILED store: --store near did not make the store in the project"
    stores=no
fi
chmod -R u+w "$scratch/kept/near"
rm -rf "$scratch/kept/near"
#  `set always yes`: the step runs every time, and what takes its output
#  is kept while that is the same.
planted_project "$scratch/always"
sed -i 's/^step upper from notes\/a.txt$/&\n    set always yes/' "$scratch/always/landin.recipe"
: > "$log"
builds "a first build with an always step" "$scratch/always" "$scratch/store-always"
builds "a second build with an always step" "$scratch/always" "$scratch/store-always"
said "set always yes does not run the step every time" "step upper
made
step count: kept
counted"
logged "an always step is not started on each build, or its taker is" 3
#  A step that fails leaves no key and no entry, and what it wrote is
#  kept for a look; the next run removes that and keeps its own.
planted_project "$scratch/fails"
{
    echo 'step bad'
    # shellcheck disable=SC2016  # written into the recipe as it stands
    echo '    run sh -c "echo partial > $0/p; exit 3" {out}'
} > "$scratch/fails/landin.recipe"
status=0
(cd "$scratch/fails" && "$build" --store "$scratch/store-fails" \
    > "$scratch/out" 2>&1) || status=$?
# shellcheck disable=SC2016  # the backquotes are the message's own
if [ "$status" -ne 1 ] \
    || ! grep -q -x -F 'error[RB0403]: step `bad` failed: `sh` ended with code 3' "$scratch/out" \
    || ! grep -q -x -F 'note: what the step wrote is kept in `.landin/failed/bad`' "$scratch/out"; then
    cat "$scratch/out"
    echo "FAILED store: a failing step is not said as one"
    stores=no
fi
if [ -n "$(find "$scratch/store-fails/keys" "$scratch/store-fails/entries" -mindepth 1)" ]; then
    echo "FAILED store: a failed step left a key or an entry"
    stores=no
fi
if [ "$(cat "$scratch/fails/.landin/failed/bad/p" 2> /dev/null)" != partial ]; then
    echo "FAILED store: what a failed step wrote is not kept under .landin/failed"
    stores=no
fi
(cd "$scratch/fails" && "$build" --store "$scratch/store-fails" > /dev/null 2>&1) || true
if [ "$(find "$scratch/store-fails/tmp" -mindepth 1 -maxdepth 1 | wc -l)" -ne 1 ]; then
    echo "FAILED store: a step that fails again does not replace what it left"
    stores=no
fi
#  Two builds of the same package at once on one empty store: both end
#  well, and each step has one entry and one key.
planted_project "$scratch/twin-a"
planted_project "$scratch/twin-b"
(cd "$scratch/twin-a" && "$build" --store "$scratch/store-twin" > "$scratch/twin-a.said" 2>&1) &
first=$!
(cd "$scratch/twin-b" && "$build" --store "$scratch/store-twin" > "$scratch/twin-b.said" 2>&1) &
second=$!
together=ok
wait "$first" || together=no
wait "$second" || together=no
if [ "$together" != ok ]; then
    cat "$scratch/twin-a.said" "$scratch/twin-b.said"
    echo "FAILED store: two builds at once on one store did not both end well"
    stores=no
elif [ "$(find "$scratch/store-twin/entries" -mindepth 1 -maxdepth 1 | wc -l)" -ne 2 ] \
    || [ "$(find "$scratch/store-twin/keys" -mindepth 1 -maxdepth 1 | wc -l)" -ne 2 ] \
    || [ -n "$(ls "$scratch/store-twin/tmp")" ]; then
    find "$scratch/store-twin" -maxdepth 2
    echo "FAILED store: two builds at once did not leave one entry and one key a step"
    stores=no
fi
#  A store of another form is refused, and so is a directory that holds
#  entries and names no form.
#  refused WHAT DIRECTORY STORE: a build there ends with 1 and RB0601.
refused() {
    status=0
    (cd "$2" && "$build" --store "$3" > "$scratch/out" 2>&1) || status=$?
    if [ "$status" -ne 1 ] || ! grep -q '^error\[RB0601\]: ' "$scratch/out"; then
        cat "$scratch/out"
        echo "FAILED store: $1 is not refused with RB0601"
        stores=no
    fi
}
mkdir "$scratch/store-old"
printf 'landin-store-0\n' > "$scratch/store-old/version"
refused "a store of another form" "$scratch/kept" "$scratch/store-old"
mkdir -p "$scratch/store-odd/entries"
refused "a directory with entries and no version" "$scratch/kept" "$scratch/store-odd"
#  Without --store the store is where XDG_CACHE_HOME says, and without
#  that under HOME; with neither it is asked for.
(cd "$scratch/kept" && XDG_CACHE_HOME="$scratch/xdg" "$build" > /dev/null 2>&1) || true
(cd "$scratch/kept" && env -u XDG_CACHE_HOME HOME="$scratch/home" "$build" > /dev/null 2>&1) || true
if [ ! -f "$scratch/xdg/landin/store/version" ] \
    || [ ! -f "$scratch/home/.cache/landin/store/version" ]; then
    echo "FAILED store: the user's store is not where XDG_CACHE_HOME or HOME says"
    stores=no
fi
status=0
(cd "$scratch/kept" && env -u XDG_CACHE_HOME -u HOME "$build" > "$scratch/out" 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^error\[RB0602\]: ' "$scratch/out"; then
    cat "$scratch/out"
    echo "FAILED store: a build with nowhere for its store is not refused with RB0602"
    stores=no
fi
[ "$stores" = ok ] || failed=$((failed + 1))
#  Paths.  A step's program names files through its view; the tool shows
#  them as the project's, live and when a kept step says them again, and
#  only where the whole path is the view's.  --raw shows what was said.
count=$((count + 1))
paths=ok
mkdir -p "$scratch/paths/notes"
printf 'hello\n' > "$scratch/paths/notes/a.txt"
printf 'package dev701/demo\nkind library\n' > "$scratch/paths/landin.package"
cat > "$scratch/paths/say.sh" <<'SAY'
echo "  --> packages/dev701/demo/notes/a.txt:1:2"
echo "./packages/dev701/demo/x.ldn and $PWD/packages/dev701/demo/y.ldn"
echo "mypackages/dev701/demo/z packages/dev701/demo_more/w packages/dev701/other/v"
echo "in packages/dev701/demo: (packages/dev701/demo/)"
echo "error packages/dev701/demo/e.ldn:3" >&2
printf 'no end packages/dev701/demo/tail'
SAY
printf 'step says with packages say.sh\n    run sh say.sh\n' > "$scratch/paths/landin.recipe"
shown="  --> notes/a.txt:1:2
x.ldn and y.ldn
mypackages/dev701/demo/z packages/dev701/demo_more/w packages/dev701/other/v
in .: (./)
no end tail"
#  told WHAT FIRST ARGUMENTS...: a build in the paths project says FIRST,
#  then `shown` or, with a last argument of `raw`, what the script wrote.
told() {
    what=$1 first=$2
    shift 2
    if ! (cd "$scratch/paths" && "$build" --store "$scratch/paths-store" "$@" \
        > "$scratch/out" 2> "$scratch/err"); then
        cat "$scratch/out" "$scratch/err"
        echo "FAILED paths: $what: the build failed"
        paths=no
        return
    fi
    if [ "$(cat "$scratch/out")" != "$first
$shown" ] || [ "$(cat "$scratch/err")" != "error e.ldn:3" ]; then
        cat "$scratch/out" "$scratch/err"
        echo "FAILED paths: $what"
        paths=no
    fi
}
told "a step's paths are not shown as the project's" "step says"
told "a kept step's paths are not shown as the project's" "step says: kept"
view=$scratch/paths/.landin/steps/says/view
if ! (cd "$scratch/paths" && "$build" --store "$scratch/paths-store" --raw \
    > "$scratch/out" 2> "$scratch/err") \
    || [ "$(cat "$scratch/err")" != "error packages/dev701/demo/e.ldn:3" ] \
    || ! grep -q -x -F "./packages/dev701/demo/x.ldn and $view/packages/dev701/demo/y.ldn" "$scratch/out" \
    || ! grep -q -x -F "no end packages/dev701/demo/tail" "$scratch/out"; then
    cat "$scratch/out" "$scratch/err"
    echo "FAILED paths: --raw does not show what the program said"
    paths=no
fi
if [ -n "$refine" ]; then
    #  The same from refine itself: a warning, live and kept, and an error.
    mkdir -p "$scratch/named/cmd/warns" "$scratch/named/cmd/wrong"
    printf 'package dev701/named\nkind program\nprogram warns cmd/warns\n' \
        > "$scratch/named/landin.package"
    cat > "$scratch/named/cmd/warns/main.ldn" <<'LDN'
public main: () -> (code: i32) =
    mut zero: i32 = 0
    code = zero
end main
LDN
    cat > "$scratch/named/cmd/wrong/main.ldn" <<'LDN'
public main: () -> (code: i32) =
    code = nothing_of_that_name
end main
LDN
    {
        echo 'step warns with packages'
        echo '    run refine check --root packages packages/dev701/named/cmd/warns'
        echo 'step wrong with packages'
        echo '    run refine check --root packages packages/dev701/named/cmd/wrong'
        echo 'default warns'
    } > "$scratch/named/landin.recipe"
    for turn in first kept; do
        if ! (cd "$scratch/named" && env -u LANDIN_REFINE "$build" \
            --refine "$refine" --store "$scratch/paths-store" > "$scratch/out" 2>&1) \
            || ! grep -q -x -F '  --> cmd/warns/main.ldn:2:5' "$scratch/out" \
            || grep -q 'packages/dev701' "$scratch/out"; then
            cat "$scratch/out"
            echo "FAILED paths: refine's warning does not name the project's file ($turn build)"
            paths=no
        fi
    done
    if ! grep -q -x 'step warns: kept' "$scratch/out"; then
        cat "$scratch/out"
        echo "FAILED paths: the second build did not keep the step that warns"
        paths=no
    fi
    status=0
    (cd "$scratch/named" && env -u LANDIN_REFINE "$build" --refine "$refine" \
        --store "$scratch/paths-store" wrong > "$scratch/out" 2>&1) || status=$?
    if [ "$status" -ne 1 ] \
        || ! grep -q -x -F '  --> cmd/wrong/main.ldn:2:12' "$scratch/out" \
        || grep -q 'packages/dev701' "$scratch/out"; then
        cat "$scratch/out"
        echo "FAILED paths: refine's error does not name the project's file"
        paths=no
    fi
fi
[ "$paths" = ok ] || failed=$((failed + 1))
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
slack=384
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
    #  With the store: once a build has run each step, every build keeps
    #  them; with --again every build runs every step.
    (cd "$scratch/steps-run" && "$build" > /dev/null 2>&1) || true
    steady "read, check and keep" steps-run 2 2000
    steady "read, check and run" steps-run 2 100 --again
    #  A file is hashed in blocks: a large one takes no more memory than a
    #  small one.
    count=$((count + 1))
    mkdir "$scratch/sized"
    head -c 1048576 /dev/zero > "$scratch/sized/small"
    head -c 67108864 /dev/zero > "$scratch/sized/large"
    small=$(peak sized --hash-file small) || small=
    large=$(peak sized --hash-file large) || large=
    if [ -z "$small" ] || [ -z "$large" ]; then
        failed=$((failed + 1))
    else
        echo "memory, hashing a file: 1 MiB peaks at $small KiB, 64 MiB at $large KiB"
        if [ "$large" -gt $((small + slack)) ]; then
            echo "FAILED memory, hashing a file: memory grows with the file"
            failed=$((failed + 1))
        fi
    fi
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
