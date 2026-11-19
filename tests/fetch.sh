#!/bin/sh
#  The checks of refine-fetch and of building with what it fetched.
#
#  Usage: tests/fetch.sh FETCH BUILD REFINE SCRATCH
#
#  No check reaches a network.  The packages are small git repositories
#  made under SCRATCH, and git is told, through GIT_CONFIG_COUNT and its
#  companions in this script's environment, that `https://example.test/`
#  is that directory.  Every check has a store of its own under SCRATCH.
#
#  It prints a line for each check that fails, and at the end
#  `fetch checks: N run, M failed`, which tests/run.sh reads.
# shellcheck disable=SC2016  # the patterns hold backquotes, not commands
set -eu
fetch=$1
build=$2
refine=$3
scratch=$4
mkdir -p "$scratch/repos"
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.file://$scratch/repos/.insteadOf"
export GIT_CONFIG_VALUE_0="https://example.test/"
export GIT_CONFIG_KEY_1="protocol.file.allow"
export GIT_CONFIG_VALUE_1="always"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.test
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z'
export GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
run=0
failed=0
#  repo NAME: an empty repository.
repo() {
    mkdir -p "$scratch/repos/$1"
    git -C "$scratch/repos/$1" init -q -b main
}
#  release NAME TAG: commit what the repository holds and tag it.
release() {
    git -C "$scratch/repos/$1" add -A
    git -C "$scratch/repos/$1" commit -q --allow-empty -m "$2"
    git -C "$scratch/repos/$1" tag "$2"
}
#  library NAME PACKAGE VALUE NEEDS...: a repository whose package has one
#  module, `part`, with a function `value` that gives VALUE, and the
#  `needs` lines given.
library() {
    name=$1 package=$2 value=$3
    shift 3
    [ -d "$scratch/repos/$name" ] || repo "$name"
    {
        echo "package $package"
        echo "kind library"
        echo "licence MIT"
        for need in "$@"; do echo "needs $need"; done
    } > "$scratch/repos/$name/landin.package"
    mkdir -p "$scratch/repos/$name/part"
    printf 'public value: () -> (n: i32) =\n    n = %s\nend value\n' "$value" \
        > "$scratch/repos/$name/part/part.ldn"
}
#  project NAME LINES...: a package directory whose description has the
#  lines given after its name and kind.
project() {
    name=$1
    shift
    mkdir -p "$scratch/$name"
    {
        echo "package test/$name"
        echo "kind library"
        for line in "$@"; do echo "$line"; done
    } > "$scratch/$name/landin.package"
}
#  fetched WHAT PROJECT [ARGUMENTS...]: the fetch there ends with 0; what
#  it said is in $scratch/said.
fetched() {
    what=$1 name=$2
    shift 2
    run=$((run + 1))
    if ! (cd "$scratch/$name" && "$fetch" --store "$scratch/store-$name" "$@" \
        > "$scratch/said" 2>&1); then
        cat "$scratch/said"
        echo "FAILED fetch: $what: the fetch failed"
        failed=$((failed + 1))
        return 1
    fi
}
#  refused WHAT PROJECT CODE [ARGUMENTS...]: the fetch there ends with 1
#  and says CODE.
refused() {
    what=$1 name=$2 code=$3
    shift 3
    run=$((run + 1))
    status=0
    (cd "$scratch/$name" && "$fetch" --store "$scratch/store-$name" "$@" \
        > "$scratch/said" 2>&1) || status=$?
    if [ "$status" -ne 1 ] || ! grep -q "^error\\[$code\\]: " "$scratch/said"; then
        cat "$scratch/said"
        echo "FAILED fetch: $what: not refused with $code"
        failed=$((failed + 1))
    fi
}
#  holds WHAT PATTERN FILE: FILE has a line that matches PATTERN.
holds() {
    run=$((run + 1))
    if ! grep -q -E "$2" "$3"; then
        cat "$3"
        echo "FAILED fetch: $1"
        failed=$((failed + 1))
    fi
}
#  lacks WHAT PATTERN FILE: FILE has no line that matches PATTERN.
lacks() {
    run=$((run + 1))
    if grep -q -E "$2" "$3"; then
        cat "$3"
        echo "FAILED fetch: $1"
        failed=$((failed + 1))
    fi
}

#  The packages: alpha at 1.0.0, 1.2.0 and 2.0.0, tagged `vN`; beta, which
#  needs alpha 1.0.0, tagged with the bare version; gamma, which needs
#  beta and alpha 1.2.0, so alpha is asked for twice.
library alpha t/alpha 1
release alpha v1.0.0
first_alpha=$(git -C "$scratch/repos/alpha" rev-parse HEAD)
library alpha t/alpha 2
release alpha v1.2.0
library alpha t/alpha 3
release alpha v2.0.0
library beta t/beta 10 "example.test/alpha 1.0.0"
release beta 1.0.0
library gamma t/gamma 100 "example.test/beta 1.0.0" "example.test/alpha 1.2.0"
release gamma v1.0.0

#  A chain of three, with alpha asked for at two versions: the later one.
project chain "needs example.test/gamma 1.0.0"
if fetched "a chain of three" chain; then
    holds "the chain's summary names what was added" \
        '^added t/alpha 1\.2\.0 from example\.test/alpha, [0-9]+ KiB, MIT$' "$scratch/said"
    holds "alpha is locked at the later of the two versions asked for" \
        '^package t/alpha example\.test/alpha 1\.2\.0 commit [0-9a-f]{40} tree [0-9a-f]{64}$' \
        "$scratch/chain/landin.lock"
    holds "beta's bare tag is a version" \
        '^package t/beta example\.test/beta 1\.0\.0 commit ' "$scratch/chain/landin.lock"
    holds "the lock names its form first" '^lock 2$' "$scratch/chain/landin.lock"
    run=$((run + 1))
    if [ "$(wc -l < "$scratch/chain/landin.lock")" -ne 4 ]; then
        cat "$scratch/chain/landin.lock"
        echo "FAILED fetch: the chain's lock is not its form and three packages"
        failed=$((failed + 1))
    fi
    #  A lock that is right is left as it is, byte for byte.
    cp "$scratch/chain/landin.lock" "$scratch/chain.lock"
    touch -d '2001-01-01' "$scratch/chain/landin.lock"
    if fetched "a second fetch" chain; then
        holds "a second fetch says the lock is as it has to be" \
            '^landin\.lock is as it has to be: 3 fetched, 0 local$' "$scratch/said"
        run=$((run + 1))
        if ! cmp -s "$scratch/chain.lock" "$scratch/chain/landin.lock" \
            || [ "$scratch/chain/landin.lock" -nt "$scratch/chain.lock" ]; then
            echo "FAILED fetch: a lock that was right was written again"
            failed=$((failed + 1))
        fi
    fi
    fetched "--check of a lock that serves" chain --check || true
    holds "--check says the lock serves" '^landin\.lock gives what landin\.package asks for: 3 packages for the program$' "$scratch/said"
    #  The lock on a machine whose store is empty: the commits it names are
    #  fetched, and it does not change.
    mkdir "$scratch/elsewhere"
    cp "$scratch/chain/landin.package" "$scratch/chain/landin.lock" "$scratch/elsewhere/"
    refused "--check with an empty store" elsewhere RB0205 --check
    if fetched "a fetch into an empty store" elsewhere; then
        run=$((run + 1))
        if ! cmp -s "$scratch/chain.lock" "$scratch/elsewhere/landin.lock"; then
            echo "FAILED fetch: fetching into an empty store changed the lock"
            failed=$((failed + 1))
        fi
    fi
    #  Content that is not what the lock says is refused.
    mkdir "$scratch/tampered"
    cp "$scratch/chain/landin.package" "$scratch/tampered/"
    sed 's/tree [0-9a-f]\{8\}/tree 00000000/' "$scratch/chain.lock" > "$scratch/tampered/landin.lock"
    refused "a tree other than the lock's" tampered RF0104
    #  --update chooses anew: with gamma gone alpha is asked for at 1.0.0
    #  only; the lock's 1.2.0 still serves and stays until it is updated.
    project loosened "needs example.test/alpha 1.0.0"
    cp "$scratch/chain.lock" "$scratch/loosened/landin.lock"
    cp -R "$scratch/store-chain" "$scratch/store-loosened"
    if fetched "a fetch after a need went" loosened; then
        holds "a line that still serves is kept" '^package t/alpha example\.test/alpha 1\.2\.0 ' "$scratch/loosened/landin.lock"
        holds "what nothing needs is dropped" '^dropped t/gamma$' "$scratch/said"
        lacks "a dropped package leaves the lock" 't/gamma' "$scratch/loosened/landin.lock"
    fi
    if fetched "--update of one package" loosened --update t/alpha; then
        holds "--update takes the version asked for" '^package t/alpha example\.test/alpha 1\.0\.0 ' "$scratch/loosened/landin.lock"
        holds "--update says what changed" '^changed t/alpha 1\.0\.0 from example\.test/alpha' "$scratch/said"
    fi
    refused "--update of a name the lock lacks" loosened RF0204 --update t/nothing
fi

#  A tag that moved: the lock's commit is what is fetched, whatever the
#  tag names now.
library moving t/moving 1
release moving v1.0.0
project steady "needs example.test/moving 1.0.0"
if fetched "a package whose tag will move" steady; then
    cp "$scratch/steady/landin.lock" "$scratch/steady.lock"
    library moving t/moving 2
    git -C "$scratch/repos/moving" add -A
    git -C "$scratch/repos/moving" commit -q -m "moved"
    git -C "$scratch/repos/moving" tag -f v1.0.0 > /dev/null
    chmod -R u+w "$scratch/store-steady"
    rm -rf "$scratch/store-steady"
    if fetched "a fetch after the tag moved" steady; then
        run=$((run + 1))
        if ! cmp -s "$scratch/steady.lock" "$scratch/steady/landin.lock"; then
            echo "FAILED fetch: a tag that moved changed what the lock names"
            failed=$((failed + 1))
        fi
    fi
fi

#  Two versions with a breaking change between them.
library delta t/delta 4 "example.test/alpha 2.0.0"
release delta v1.0.0
project majors "needs example.test/gamma 1.0.0" "needs example.test/delta 1.0.0"
refused "two majors of one package" majors RF0201
holds "both askers are named" 'by `t/gamma` and at 2\.0\.0 by `t/delta`' "$scratch/said"

#  Both spellings of a tag, at different commits.
library twice t/twice 1
release twice v1.0.0
library twice t/twice 2
release twice 1.0.0
project spelled "needs example.test/twice 1.0.0"
refused "v1.0.0 and 1.0.0 at different commits" spelled RF0102

#  A version with no tag, a commit that is not there, a location that is
#  not there.
project untagged "needs example.test/alpha 9.9.9"
refused "a version without a tag" untagged RF0101
project nocommit "needs example.test/alpha commit 0123456789abcdef0123456789abcdef01234567"
refused "a commit the repository lacks" nocommit RF0103
project nowhere "needs example.test/nothing 1.0.0"
refused "a location that is not there" nowhere RF0002

#  A commit named itself.
project pinned "needs example.test/alpha commit $first_alpha"
if fetched "a commit named itself" pinned; then
    holds "a commit's line says untagged" \
        "^package t/alpha example\\.test/alpha untagged commit $first_alpha tree " "$scratch/pinned/landin.lock"
fi

#  One name at two locations: refused, unless the package being built
#  names one, which then stands in for the other, with a note.
library fork t/alpha 7
release fork v1.5.0
library other t/other 5 "example.test/fork 1.5.0"
release other v1.0.0
project clash "needs example.test/gamma 1.0.0" "needs example.test/other 1.0.0"
refused "one name at two locations" clash RF0202
project forked "needs example.test/gamma 1.0.0" "needs example.test/fork 1.5.0"
if fetched "the package being built names the fork" forked; then
    holds "a note says which location stands in" \
        '^note: `t/alpha` is taken from `example\.test/fork`, which landin\.package names, not from `example\.test/alpha`' "$scratch/said"
    holds "the lock has the fork's line" '^package t/alpha example\.test/fork 1\.5\.0 ' "$scratch/forked/landin.lock"
    holds "the lock says what the fork stands in for" '^instead example\.test/alpha t/alpha$' "$scratch/forked/landin.lock"
    fetched "--check with a stand-in" forked --check || true
fi

#  A local path: taken as it is, with no line; what it needs is fetched.
mkdir -p "$scratch/beside/part"
printf 'package t/beside\nkind library\nneeds example.test/alpha 1.0.0\n' > "$scratch/beside/landin.package"
printf 'import t/alpha/part\npublic value: () -> (n: i32) =\n    n = part.value() + 40\nend value\n' \
    > "$scratch/beside/part/part.ldn"
project near "needs ../beside"
if fetched "a local path" near; then
    holds "a local package's need is locked" '^package t/alpha example\.test/alpha 1\.0\.0 ' "$scratch/near/landin.lock"
    lacks "a local package has no line" 't/beside' "$scratch/near/landin.lock"
    holds "the local package is counted" '^wrote landin\.lock: 1 fetched, 1 local$' "$scratch/said"
fi
#  A fetched package may not need a local path.
library reaching t/reaching 1 "../beside"
release reaching v1.0.0
project reached "needs example.test/reaching 1.0.0"
refused "a fetched package that needs a local path" reached RB0206

#  The old form of a needs line says what to write.
project old "needs t/alpha 1.0.0"
refused "a needs line with a name and no location" old RB0103

#  The command's own answers: what refine asks of a contributed command.
run=$((run + 1))
if [ "$("$fetch" --describe)" != '{"format":"landin-command-1","name":"fetch","summary":"Fetch the packages a description needs and write the lock","codes":["RF"]}' ]; then
    echo "FAILED fetch: --describe"
    failed=$((failed + 1))
fi
run=$((run + 1))
if [ "$("$fetch" explain RF0101 | wc -l)" -lt 3 ] || ! "$fetch" explain | grep -q -x RF0104; then
    echo "FAILED fetch: explain"
    failed=$((failed + 1))
fi
run=$((run + 1))
if [ "$(cd "$scratch/chain" && "$fetch" --complete -- --update t/b)" != "t/beta" ] \
    || [ "$("$fetch" --complete -- --ch)" != "--check" ]; then
    echo "FAILED fetch: --complete"
    failed=$((failed + 1))
fi
run=$((run + 1))
status=0
"$fetch" --nothing > "$scratch/said" 2>&1 || status=$?
if [ "$status" -ne 2 ] || ! grep -q '^error\[RB0001\]: ' "$scratch/said"; then
    echo "FAILED fetch: an unknown option is not refused with status 2"
    failed=$((failed + 1))
fi

#  Through refine, as the contributed command it is: `refine fetch`.
mkdir -p "$scratch/bin"
cp "$fetch" "$scratch/bin/refine-fetch"
run=$((run + 1))
if ! (cd "$scratch/chain" && PATH="$scratch/bin:$PATH" "$refine" fetch \
    --store "$scratch/store-chain" --check > "$scratch/said" 2>&1) \
    || ! grep -q '^landin\.lock gives what' "$scratch/said"; then
    cat "$scratch/said"
    echo "FAILED fetch: \`refine fetch\` does not run the command"
    failed=$((failed + 1))
fi
run=$((run + 1))
if ! PATH="$scratch/bin:$PATH" "$refine" explain RF0101 2> /dev/null | grep -q -x RF0101; then
    echo "FAILED fetch: \`refine explain RF0101\` is not forwarded"
    failed=$((failed + 1))
fi

#  A fetch gives back all it took: many in one process take no more
#  memory than a few.  `--repeat N` is for this check only.
if env time -f %M true > /dev/null 2>&1; then
    run=$((run + 1))
    (cd "$scratch/chain" && env time -f %M -o "$scratch/peak" "$fetch" \
        --store "$scratch/store-chain" --repeat 3 > /dev/null 2>&1) || true
    few=$(tail -n 1 "$scratch/peak")
    (cd "$scratch/chain" && env time -f %M -o "$scratch/peak" "$fetch" \
        --store "$scratch/store-chain" --repeat 300 > /dev/null 2>&1) || true
    many=$(tail -n 1 "$scratch/peak")
    echo "memory, fetch with a lock that is right: 3 peak at $few KiB, 300 at $many KiB"
    if [ "$many" -gt $((few + 384)) ]; then
        echo "FAILED fetch: memory grows with the number of fetches"
        failed=$((failed + 1))
    fi
fi

#  Building with what was fetched.  adder needs alpha and imports it;
#  the program needs adder and alpha, at an earlier version than adder
#  does, and ends with what the two give: 2 from alpha 1.2.0, twice.
repo adder
printf 'package t/adder\nkind library\nneeds example.test/alpha 1.2.0\n' \
    > "$scratch/repos/adder/landin.package"
mkdir -p "$scratch/repos/adder/adder"
printf 'import t/alpha/part\n\npublic plus: (n: i32) -> (r: i32) =\n    r = n + part.value()\nend plus\n' \
    > "$scratch/repos/adder/adder/adder.ldn"
release adder v1.0.0
#  program NAME IMPORTS RESULT LINES...: a package directory with a program
#  whose `main` imports IMPORTS, a `;`-separated list, and ends with
#  RESULT, and a description with LINES.
program() {
    name=$1 imports=$2 result=$3
    shift 3
    mkdir -p "$scratch/$name/cmd/app"
    {
        echo "package test/$name"
        echo "kind program"
        echo "program app cmd/app"
        for line in "$@"; do echo "$line"; done
    } > "$scratch/$name/landin.package"
    {
        echo "$imports" | tr ';' '\n' | sed 's/^/import /'
        echo
        echo 'public main: () -> (code: i32) ='
        echo "    code = $result"
        echo 'end main'
    } > "$scratch/$name/cmd/app/main.ldn"
}
#  built WHAT PROJECT [ARGUMENTS...]: the build there ends with 0; its
#  output is in $scratch/said.
built() {
    what=$1 name=$2
    shift 2
    run=$((run + 1))
    if ! (cd "$scratch/$name" && "$build" --refine "$refine" \
        --store "$scratch/store-$name" "$@" > "$scratch/said" 2>&1); then
        cat "$scratch/said"
        echo "FAILED build: $what: the build failed"
        failed=$((failed + 1))
        return 1
    fi
}
#  unbuilt WHAT PROJECT CODE: the build there ends with 1 and says CODE.
unbuilt() {
    run=$((run + 1))
    status=0
    (cd "$scratch/$2" && "$build" --refine "$refine" \
        --store "$scratch/store-$2" > "$scratch/said" 2>&1) || status=$?
    if [ "$status" -ne 1 ] || ! grep -q "^error\\[$3\\]: " "$scratch/said"; then
        cat "$scratch/said"
        echo "FAILED build: $1: not refused with $3"
        failed=$((failed + 1))
    fi
}
#  ends WHAT PROGRAM STATUS: PROGRAM ends with STATUS.
ends() {
    run=$((run + 1))
    status=0
    "$2" || status=$?
    if [ "$status" -ne "$3" ]; then
        echo "FAILED build: $1: ended with $status, not $3"
        failed=$((failed + 1))
    fi
}
compile='    run refine compile --root packages packages/test/NAME/cmd/app -o {out}/app'
program uses2 "t/adder/adder;t/alpha/part" "adder.plus(part.value())" \
    "needs example.test/adder 1.0.0" "needs example.test/alpha 1.0.0"
printf 'step app with packages\n%s\n' "$compile" | sed 's/NAME/uses2/' > "$scratch/uses2/landin.recipe"
unbuilt "a build with needs and no lock" uses2 RB0203
holds "the refusal says what to run" 'run `refine fetch`' "$scratch/said"
if fetched "what the program needs" uses2 && built "a program with two packages" uses2; then
    ends "the program takes alpha at the later version, through both" "$scratch/uses2/.landin/out/app/app" 4
    built "a second build with packages" uses2 || true
    holds "a second build with packages keeps the step" '^step app: kept$' "$scratch/said"
    #  The store elsewhere lacks the entries: the build says to fetch.
    mkdir "$scratch/moved"
    cp -R "$scratch/uses2/cmd" "$scratch/uses2/landin.package" "$scratch/uses2/landin.recipe" \
        "$scratch/uses2/landin.lock" "$scratch/moved/"
    unbuilt "a build whose store lacks a locked package" moved RB0205
    #  The description asks for more than the lock gives.
    sed -i 's/alpha 1\.0\.0/alpha 2.0.0/' "$scratch/moved/landin.package"
    rm -rf "$scratch/store-moved"
    cp -R "$scratch/store-uses2" "$scratch/store-moved"
    unbuilt "a build whose lock is behind the description" moved RB0204
fi
#  An import of a package that is only brought along is refused.
program leaning "t/adder/adder;t/alpha/part" "adder.plus(part.value())" \
    "needs example.test/adder 1.0.0"
printf 'step app with packages\n%s\n' "$compile" | sed 's/NAME/leaning/' > "$scratch/leaning/landin.recipe"
if fetched "what the leaning program needs" leaning; then
    unbuilt "an import of a package that is not listed" leaning RB0207
    holds "the import's file and line are named" \
        '^error\[RB0207\]: cmd/app/main\.ldn:2: `import t/alpha/part` is a module of `t/alpha`' "$scratch/said"
fi
#  A local package is built with, as it is, and an edit to it is seen.
program nearby "t/beside/part" "part.value()" "needs ../beside"
printf 'step app with packages\n%s\n' "$compile" | sed 's/NAME/nearby/' > "$scratch/nearby/landin.recipe"
if fetched "what the local package needs" nearby && built "a program with a local package" nearby; then
    ends "the local package's module is used" "$scratch/nearby/.landin/out/app/app" 41
    sed -i 's/+ 40/+ 50/' "$scratch/beside/part/part.ldn"
    built "a build after the local package changed" nearby || true
    holds "an edit to a local package runs the step" '^step app$' "$scratch/said"
    ends "the edit is in the program" "$scratch/nearby/.landin/out/app/app" 51
fi

#  A tool: a package the description uses, whose program writes a module
#  that a later step compiles with.
repo gen
mkdir -p "$scratch/repos/gen/cmd/gen"
printf 'package t/gen\nkind program\nprogram gen cmd/gen\n' > "$scratch/repos/gen/landin.package"
cat > "$scratch/repos/gen/cmd/gen/main.ldn" <<'END'
-- gen DIRECTORY... FILE: makes the directories and writes a module to FILE.

import core/io
import core/text
import hosted/blocking

public main: () -> (code: i32) =
    host := blocking.new()
    code = 1
    count: usize = io.argument_count(host)
    return when count == 0
    for at in usize(0)..<count - 1 do
        made: text.host_string = io.argument_at(host, at) else (problem)
            _ = problem
            return
        end
        io.make_directory(host, made) else (problem)
            _ = problem
            return
        end
    end for
    path: text.host_string = io.argument_at(host, count - 1) else (problem)
        _ = problem
        return
    end
    written: io.file = io.open_write(host, path) else (problem)
        _ = problem
        return
    end
    io.write(host, written, "public value: () -> (n: i32) =\n    n = 30\nend value\n") else none
    io.close(host, written) else none
    io.write(host, io.out(host), "generated\n") else none
    code = 0
end main
END
release gen v1.0.0
program tooled "test/tooled/generated" "generated.value()" "uses example.test/gen 1.0.0"
cat > "$scratch/tooled/landin.recipe" <<'END'
step made
    run gen {out}/test {out}/test/tooled {out}/test/tooled/generated {out}/test/tooled/generated/generated.ldn
step app with packages made
    run refine compile --root packages --root made packages/test/tooled/cmd/app -o {out}/app
END
if fetched "the tool" tooled; then
    holds "a package that is only used is a tool in the lock" '^tool t/gen example\.test/gen 1\.0\.0 ' "$scratch/tooled/landin.lock"
    if built "a recipe that runs a tool" tooled; then
        holds "the tool is made first" '^tool t/gen$' "$scratch/said"
        ends "the generated module is in the program" "$scratch/tooled/.landin/out/app/app" 30
        built "a second build with a tool" tooled || true
        run=$((run + 1))
        if [ "$(cat "$scratch/said")" != "tool t/gen: kept
step made: kept
generated
step app: kept" ]; then
            cat "$scratch/said"
            echo "FAILED build: a second build does not keep the tool and both steps"
            failed=$((failed + 1))
        fi
        #  The package being built changed: the tool is not made again.
        echo '-- a note' >> "$scratch/tooled/cmd/app/main.ldn"
        built "a build after the program changed" tooled || true
        holds "a change to the package keeps the tool" '^tool t/gen: kept$' "$scratch/said"
        holds "a change to the package runs its step" '^step app$' "$scratch/said"
    fi
fi
#  A tool is a program of its own: its packages are chosen apart.  mul3
#  needs alpha 2.0.0 and writes a module that gives ten times what alpha
#  gives it, 30; mul2 needs alpha 1.2.0 and writes 20.  The program needs
#  alpha 1.0.0, a breaking change away from mul3's, and adds what alpha
#  gives it, 1.
#  multiplier NAME ALPHA: a tool `NAME`, in the repository NAME, that needs
#  alpha at the version ALPHA.
multiplier() {
    repo "$1"
    mkdir -p "$scratch/repos/$1/cmd/$1"
    printf 'package t/%s\nkind program\nprogram %s cmd/%s\nneeds example.test/alpha %s\n' \
        "$1" "$1" "$1" "$2" > "$scratch/repos/$1/landin.package"
    sed '/^import core\/io$/i import t/alpha/part' "$scratch/repos/gen/cmd/gen/main.ldn" \
        | sed 's/"public value: () -> (n: i32) =\\n    n = 30\\nend value\\n"/texts[usize(part.value())]/' \
        > "$scratch/repos/$1/cmd/$1/main.ldn"
    cat >> "$scratch/repos/$1/cmd/$1/main.ldn" <<'END'

texts: [4][]u8 = ["public value: () -> (n: i32) =\n    n = 0\nend value\n",
                  "public value: () -> (n: i32) =\n    n = 10\nend value\n",
                  "public value: () -> (n: i32) =\n    n = 20\nend value\n",
                  "public value: () -> (n: i32) =\n    n = 30\nend value\n"]
END
    release "$1" v1.0.0
}
multiplier mul3 2.0.0
multiplier mul2 1.2.0
program apart "test/apart/three;test/apart/two;t/alpha/part" "three.value() + two.value() + part.value()" \
    "needs example.test/alpha 1.0.0" "uses example.test/mul3 1.0.0" "uses example.test/mul2 1.0.0"
cat > "$scratch/apart/landin.recipe" <<'END'
step made3
    run mul3 {out}/test {out}/test/apart {out}/test/apart/three {out}/test/apart/three/three.ldn
step made2
    run mul2 {out}/test {out}/test/apart {out}/test/apart/two {out}/test/apart/two/two.ldn
step app with packages made3 made2
    run refine compile --root packages --root made3 --root made2 packages/test/apart/cmd/app -o {out}/app
END
if fetched "a program and two tools, each with its own alpha" apart; then
    holds "the summary says whose a tool's package is" \
        '^added for the tool t/mul3: t/alpha 2\.0\.0 from example\.test/alpha, [0-9]+ KiB, MIT$' "$scratch/said"
    holds "the summary names a tool as one" '^added the tool t/mul3 1\.0\.0 from example\.test/mul3' "$scratch/said"
    holds "the program's alpha is its own" '^package t/alpha example\.test/alpha 1\.0\.0 ' "$scratch/apart/landin.lock"
    holds "a tool's alpha is another major" '^for t/mul3 package t/alpha example\.test/alpha 2\.0\.0 ' "$scratch/apart/landin.lock"
    holds "the other tool's alpha is its own too" '^for t/mul2 package t/alpha example\.test/alpha 1\.2\.0 ' "$scratch/apart/landin.lock"
    run=$((run + 1))
    if [ "$(cut -d' ' -f1-3 "$scratch/apart/landin.lock")" != "lock 2
package t/alpha example.test/alpha
tool t/mul2 example.test/mul2
for t/mul2 package
tool t/mul3 example.test/mul3
for t/mul3 package" ]; then
        cat "$scratch/apart/landin.lock"
        echo "FAILED fetch: the lock's lines are not the program's and then each tool's"
        failed=$((failed + 1))
    fi
    cp "$scratch/apart/landin.lock" "$scratch/apart.lock"
    if fetched "a second fetch with tools" apart; then
        run=$((run + 1))
        if ! cmp -s "$scratch/apart.lock" "$scratch/apart/landin.lock"; then
            echo "FAILED fetch: a lock with tools that was right was written again"
            failed=$((failed + 1))
        fi
    fi
    fetched "--check with tools" apart --check || true
    holds "--check counts the program's packages" 'asks for: 1 packages for the program$' "$scratch/said"
    holds "--check names each tool and its packages" '^the tool t/mul3: 1 packages of its own$' "$scratch/said"
    if built "a program and tools with different versions of one package" apart; then
        ends "each has its own alpha: 30 and 20 from the tools, 1 for the program" \
            "$scratch/apart/.landin/out/app/app" 51
        run=$((run + 1))
        if [ -e "$scratch/apart/.landin/tools/t/mul3/packages/t/alpha/landin.package" ] \
            && [ "$(find "$scratch/apart/.landin/packages/t" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] \
            && ! cmp -s "$scratch/apart/.landin/packages/t/alpha/part/part.ldn" \
                "$scratch/apart/.landin/tools/t/mul3/packages/t/alpha/part/part.ldn"; then
            :
        else
            echo "FAILED build: the program's packages and a tool's are not held apart"
            failed=$((failed + 1))
        fi
        built "a second build with two tools" apart || true
        holds "a second build keeps a tool" '^tool t/mul3: kept$' "$scratch/said"
        holds "a second build keeps the program's step" '^step app: kept$' "$scratch/said"
    fi
    #  A lock of the form before tools were chosen apart is not misread.
    mkdir "$scratch/earlier"
    cp -R "$scratch/apart/cmd" "$scratch/apart/landin.package" "$scratch/apart/landin.recipe" "$scratch/earlier/"
    cp -R "$scratch/store-apart" "$scratch/store-earlier"
    { echo "lock 1"; grep -E '^(package|tool) ' "$scratch/apart.lock"; } > "$scratch/earlier/landin.lock"
    unbuilt "a build with a lock of the earlier form" earlier RB0204
    holds "the refusal of an earlier lock says what to run" 'lock 1.*run `refine fetch`' "$scratch/said"
    refused "--check of a lock of the earlier form" earlier RB0204 --check
    if fetched "a fetch over a lock of the earlier form" earlier; then
        holds "a note says the lock is written anew" '^note: landin\.lock is of the form `lock 1`' "$scratch/said"
        run=$((run + 1))
        if ! cmp -s "$scratch/apart.lock" "$scratch/earlier/landin.lock"; then
            echo "FAILED fetch: a lock of the earlier form was not written anew as it has to be"
            failed=$((failed + 1))
        fi
    fi
fi
#  A tool is taken as it declares: what the program names does not reach
#  into it.  The program names the fork of alpha; mul2 still gets alpha.
program unswayed "test/unswayed/two;t/alpha/part" "two.value() + part.value()" \
    "needs example.test/fork 1.5.0" "uses example.test/mul2 1.0.0"
cat > "$scratch/unswayed/landin.recipe" <<'END'
step made2
    run mul2 {out}/test {out}/test/unswayed {out}/test/unswayed/two {out}/test/unswayed/two/two.ldn
step app with packages made2
    run refine compile --root packages --root made2 packages/test/unswayed/cmd/app -o {out}/app
END
if fetched "a program that names a fork and uses a tool" unswayed; then
    holds "the tool's package is from where the tool says" \
        '^for t/mul2 package t/alpha example\.test/alpha 1\.2\.0 ' "$scratch/unswayed/landin.lock"
    lacks "nothing stands in among the tool's packages" '^for t/mul2 instead' "$scratch/unswayed/landin.lock"
    if built "a program with a fork and a tool without it" unswayed; then
        ends "the program has the fork's 7, the tool wrote 20" "$scratch/unswayed/.landin/out/app/app" 27
    fi
fi
#  Vendoring: copies of what the lock names, as plain files in the project.
#  A PATH with no git in it, for building from the copies alone.
without_git=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r directory; do
    [ -x "$directory/git" ] || printf '%s:' "$directory"
done)
without_git=${without_git%:}
if PATH="$without_git" command -v git > /dev/null 2>&1 \
    || ! PATH="$without_git" command -v env > /dev/null 2>&1; then
    echo "no PATH without git could be made here; the copies are built with git in reach"
    without_git=$PATH
fi
#  alone WHAT PROJECT: the build there, with a store that holds nothing and
#  no git, ends with 0.
alone() {
    run=$((run + 1))
    if ! (cd "$scratch/$2" && PATH="$without_git" "$build" --refine "$refine" \
        --store "$scratch/store-$2" > "$scratch/said" 2>&1); then
        cat "$scratch/said"
        echo "FAILED build: $1: the build failed"
        failed=$((failed + 1))
        return 1
    fi
}
if fetched "vendoring a program's packages" uses2 --vendor; then
    holds "vendoring says what it wrote" '^vendored t/adder 1\.0\.0 to vendor/t/adder$' "$scratch/said"
    holds "vendoring counts" '^vendor holds 2 packages: 2 written, 0 removed$' "$scratch/said"
    holds "the list names each copy and its tree" '^holds t/alpha [0-9a-f]{64}$' "$scratch/uses2/vendor/landin.vendor"
    run=$((run + 1))
    if [ ! -w "$scratch/uses2/vendor/t/alpha/part/part.ldn" ] || [ -e "$scratch/uses2/vendor/t/alpha/.git" ]; then
        echo "FAILED fetch: a vendored copy is not plain files that can be written"
        failed=$((failed + 1))
    fi
    #  The keys are the same from the store and from the copies.
    built "a build after vendoring" uses2 || true
    holds "a build after vendoring keeps the step" '^step app: kept$' "$scratch/said"
    if fetched "vendoring again" uses2 --vendor; then
        holds "copies that are right are left" '^vendor holds 2 packages: 0 written, 0 removed$' "$scratch/said"
    fi
    #  Elsewhere: the copies, the lock, an empty store and no git.
    mkdir "$scratch/vended"
    cp -R "$scratch/uses2/cmd" "$scratch/uses2/vendor" "$scratch/uses2/landin.package" \
        "$scratch/uses2/landin.recipe" "$scratch/uses2/landin.lock" "$scratch/vended/"
    if alone "a build from the copies, with an empty store and no git" vended; then
        ends "the program built from the copies" "$scratch/vended/.landin/out/app/app" 4
    fi
    #  A copy that was edited is not what the lock names.
    echo '-- edited' >> "$scratch/vended/vendor/t/alpha/part/part.ldn"
    unbuilt "a build with an edited copy" vended RB0209
    holds "the refusal names both hashes" 'hashes to [0-9a-f]{64}, and the lock says [0-9a-f]{64}' "$scratch/said"
    holds "the refusal says both ways on" 'refine-fetch --vendor.*local path' "$scratch/said"
    if fetched "vendoring over an edited copy" vended --vendor; then
        holds "the edited copy is written anew" '^vendored t/alpha 1\.2\.0 to vendor/t/alpha$' "$scratch/said"
        lacks "the copy that was right is left" '^vendored t/adder' "$scratch/said"
        alone "a build after the copy was written anew" vended || true
    fi
fi
#  After an update only what changed is written, and what the lock no
#  longer names is removed.
project shifting "needs example.test/gamma 1.0.0"
if fetched "vendoring a chain" shifting --vendor; then
    project shifting "needs example.test/beta 1.0.0"
    mkdir -p "$scratch/shifting/vendor/mine/thing"
    echo kept > "$scratch/shifting/vendor/mine/thing/file"
    if fetched "an update with vendoring" shifting --update --vendor; then
        holds "the changed package is written" '^vendored t/alpha 1\.0\.0 to vendor/t/alpha$' "$scratch/said"
        lacks "the unchanged package is not written" '^vendored t/beta' "$scratch/said"
        holds "the dropped package is removed" '^removed vendor/t/gamma$' "$scratch/said"
        holds "the counts say so" '^vendor holds 2 packages: 1 written, 1 removed$' "$scratch/said"
        holds "what refine-fetch did not write is said" '^note: `vendor/mine` is not a copy refine-fetch wrote, and is left as it is' "$scratch/said"
        run=$((run + 1))
        if [ -e "$scratch/shifting/vendor/t/gamma" ] || [ ! -f "$scratch/shifting/vendor/mine/thing/file" ] \
            || grep -q gamma "$scratch/shifting/vendor/landin.vendor"; then
            echo "FAILED fetch: vendoring after an update left gamma or took what was not its own"
            failed=$((failed + 1))
        fi
    fi
fi
#  Something where a copy goes that the list does not have is not touched.
project inway "needs example.test/alpha 1.0.0"
mkdir -p "$scratch/inway/vendor/t/alpha"
echo mine > "$scratch/inway/vendor/t/alpha/file"
refused "vendoring over what it did not write" inway RF0301 --vendor
run=$((run + 1))
if [ "$(cat "$scratch/inway/vendor/t/alpha/file")" != mine ]; then
    echo "FAILED fetch: vendoring touched what it did not write"
    failed=$((failed + 1))
fi
#  Tools are vendored apart, each with its own packages, and build from
#  the copies.
if fetched "vendoring tools" apart --vendor; then
    holds "a tool's package is under the tool" \
        '^vendored t/alpha 2\.0\.0 to vendor/for-tools/t/mul3/t/alpha$' "$scratch/said"
    holds "a tool itself is under its own name there" \
        '^vendored t/mul3 1\.0\.0 to vendor/for-tools/t/mul3/t/mul3$' "$scratch/said"
    holds "the program's package is on its own" '^vendored t/alpha 1\.0\.0 to vendor/t/alpha$' "$scratch/said"
    built "a build after vendoring tools" apart || true
    holds "the tool is kept after vendoring" '^tool t/mul3: kept$' "$scratch/said"
    holds "the step is kept after vendoring" '^step app: kept$' "$scratch/said"
    mkdir "$scratch/vapart"
    cp -R "$scratch/apart/cmd" "$scratch/apart/vendor" "$scratch/apart/landin.package" \
        "$scratch/apart/landin.recipe" "$scratch/apart/landin.lock" "$scratch/vapart/"
    if alone "tools built from the copies, with an empty store and no git" vapart; then
        ends "the program and both tools, from the copies" "$scratch/vapart/.landin/out/app/app" 51
    fi
fi
#  A package that is used and gives no program.
program toolless "core/io" "0" "uses example.test/alpha 1.0.0"
printf 'step app with packages\n%s\n' "$compile" | sed 's/NAME/toolless/' > "$scratch/toolless/landin.recipe"
if fetched "a library that is used" toolless; then
    unbuilt "a tool with no program" toolless RB0208
fi

echo "fetch checks: $run run, $failed failed"
[ "$failed" -eq 0 ]
