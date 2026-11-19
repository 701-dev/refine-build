# refine-build

A build tool for [Landin](https://github.com/JanHaan/Landin) packages,
written in Landin. It reads a package's description and its recipe and runs
the recipe's steps. It is a contributed command of `refine`: on PATH as
`refine-NAME`, it runs as `refine NAME`.

**Status: a prototype.** It reads and checks both files, runs steps one
after another and keeps what each made in a store, so a step whose program
and inputs are what they were is not run again. It fetches nothing.

## Building it

```sh
./bootstrap.sh path/to/refine
.landin/bootstrap/refine-build --refine path/to/refine
```

The first line builds the tool by hand. The second has that tool build
itself from `landin.recipe`; `.landin/out/tool/refine-build` is then the
same file byte for byte. Run the second line again and it runs nothing:
both steps are kept.

## Using it

Run it in a package's directory:

```sh
refine-build                 # the recipe's default steps
refine-build tool            # one step, after the steps it needs
refine-build --check         # read and check both files, run nothing
refine-build --refine PATH   # which refine a `run refine ...` line means
refine-build --store PATH    # which store keeps what the steps made
refine-build --again         # run every step, whatever the store keeps
refine-build --raw           # pass on what a step's program says as it is
refine-build explain RB0102  # what a code means; `explain` alone lists them
```

It ends with 0 when every step did, with 1 when a file is wrong or a step
failed, and with 2 for a command line it does not understand.

A refusal starts with its code, `error[RB0102]: landin.recipe:4: ...`, as
Landin's own do, and `explain` says more about each.

## Under `refine`

`refine` runs a `refine-NAME` it finds on PATH as `refine NAME`, after
asking it to describe itself. The tool answers what that takes:

| Asked | Answer |
|---|---|
| `--describe` | One JSON object in Landin's `landin-command-1`: the name `build`, the line `refine help` shows, and the code prefix `RB`. |
| `--help` | Its help, which `refine help NAME` shows. |
| `explain CODE` | What the code means. `refine explain RB0102` is forwarded here, since the tool claims `RB`. |
| `--complete -- WORD...` | How the last word could end, one a line: an option, a code after `explain`, or a step of the recipe in the directory. |

`refine` names itself to a command it runs in `LANDIN_REFINE`, and that is
the refine a `run refine ...` line means. `--refine PATH` overrides it, and
run by its own name the tool takes the first `refine` on PATH.

**`refine build` does not work yet.** `refine` reserves the word `build`
and dispatches nothing under it: it answers "build is reserved for future
project orchestration". Until that changes, run the tool by its own name.
The tests reach it through the dispatcher under another name, `bld`.

## The description: `landin.package`

Data only; nothing in it is executed.

```
package  dev701/refine_build       -- owner/name; both become directories
kind     program                    -- or library
licence  MIT
program  refine-build  cmd/build    -- an executable and the module it starts in
needs    owner/name  2.3.1          -- another package, and its least version
uses     owner/name  0.4.0          -- a tool for the recipe
```

`needs` and `uses` are read and checked, and a build with either is
refused, since nothing fetches a package yet.

## The recipe: `landin.recipe`

```
rule compile
    run  refine compile --root packages packages/dev701/refine_build/{entry} -o {out}/{name}

step tool  compile  with packages
    set  entry  cmd/build
    set  name   refine-build

step notes  from doc/notes.txt
    run  cp {in} {out}
    set  always yes

default tool
```

- Every line starts with a keyword. `run` and `set` belong to the `rule`
  or `step` before them; indentation means nothing.
- A step names a rule after its own name, or it names none and has a `run`
  line of its own, as `notes` has. No rule is called `from` or `with`.
- `run` is a list of words, started directly. No shell reads it.
- `{out}` is the step's own output directory, empty when the step starts.
  When the program ends with 0, it becomes the step's entry in the store.
  `{in}` is the step's `from` inputs, each as a word. `{name}` is what
  `set name` gave, the step's before the rule's. `{{` and `}}` are braces.
- An input is `packages`, another step's name, or a path in the project.
  `from` inputs are what `{in}` names; `with` inputs are only made visible.
- A step's program runs in the step's view: a directory that holds each
  input under the input's own name. `packages` holds this package, and
  later what it needs, each at `owner/name`, ready to be a `--root`.
- The first word of `run` is the program: `refine` is the calling refine,
  a word with a `/` is a path in the view, anything else is found on PATH.
- A word in double quotes may hold spaces and takes Landin's escapes. A
  word that is exactly `--` starts a comment, so `--root` is a word.
- `set always yes` under a step is the tool's own: the step runs on every
  build. A step that flashes a board or asks a clock wants it.
- A step's program reads nothing from standard input.
- What the program says is passed on a line at a time, and a path it names
  through its view, `packages/owner/name/cmd/build/main.ldn:10:34`, is
  shown as the project's, `cmd/build/main.ldn:10:34`, for a kept step too.
  `--raw` passes everything on as the program said it. Paths into the
  library and into a step's `{out}` stay as they are.

In the project, everything the tool writes is under `.landin/`:

| Path | What it is |
|---|---|
| `.landin/out/STEP` | A link to what the step made, in the store. |
| `.landin/steps/STEP/view` | What the step's program saw. |
| `.landin/failed/STEP` | A link to what a step wrote before it failed, until it runs again. |
| `.landin/packages` | This package under its `owner/name`. |

## The store

What a step makes is kept by content, per user, in
`$XDG_CACHE_HOME/landin/store`, or `$HOME/.cache/landin/store` without
that variable, or where `--store PATH` says.

| In the store | What it is |
|---|---|
| `version` | The store's form, `landin-store-1`. A store of another form is refused. |
| `entries/HASH/` | One output: a directory tree named by its content hash, read-only. |
| `keys/KEY` | The entry a step made and what its program wrote, under the step's key. |
| `tmp/` | Outputs being written. Nothing here is ever taken for an entry. |
| `lock` | Held while an output is renamed into `entries` or a key into `keys`, and never while a step runs. |

A step's key is the SHA-256 of what its program is, the words it is given
and the content of each input. Before a step runs, the tool makes its key:

- **The store knows the key and has the entry:** nothing runs. The tool
  says `step NAME: kept`, writes what the program wrote then to the same
  two streams, and points `.landin/out/NAME` at the entry.
- **Otherwise the step runs.** Its output is hashed and becomes an entry,
  and the key is written. An output that is already an entry is dropped,
  so a step that makes what it made before keeps every step after it.
- **A step that fails stores nothing.** What it wrote stays in `tmp`, and
  `.landin/failed/NAME` points at it.

What a program is: for `refine`, what `refine version --json` says of its
source, mode and dirtiness, and the content of the library it names; for
any other program, the content of its executable file. An input is a
step's entry, a file's or directory's content, or for `packages` the whole
checkout without `.landin` and the version control's directory.

`store/store.ldn` and `steps/keys.ldn` give both forms exactly.

Everything in a store can be made again, so it may be removed whole. Its
entries are read-only: `chmod -R u+w` it first.

## What is here

| Path | What it is |
|---|---|
| `landin.package`, `landin.recipe` | This package's own description and recipe. |
| `cmd/build/` | The `refine-build` program: the command line, and the order of work. |
| `text/lines/` | The reader for keyword-first line files. |
| `text/strings/` | Byte strings: copies and comparisons. |
| `codes/` | The codes of the tool's refusals and what each means, in one place. |
| `lifetime/` | How long memory lives: the regions of the process, one build and one step. |
| `description/` | Reading and checking `landin.package`. |
| `recipe/` | Reading and checking `landin.recipe`, placeholders, the steps' order. |
| `steps/` | Views, a step's key, running its program, passing on what it says, and keeping or taking what the store has. |
| `store/` | The store: entries by content, keys, and the lock. |
| `files/` | Whole files, directory trees, links, and finding a program on PATH. |
| `hash/sha256/` | SHA-256, on the language alone, so that it can become a library. An integrity hash; it makes no constant-time claim. |
| `hash/file/` | A file's content hash, read in blocks. |
| `hash/tree/` | A directory tree's content hash, and the form it is made from. |
| `report/` | What the tool says on standard error. |
| `tests/` | Small projects and the script that runs the tool over them. |
| `bootstrap.sh` | Builds the tool by hand. |

Modules import each other by their full name, `dev701/refine_build/text/lines`,
so the checkout has to appear at `dev701/refine_build` under a root. The link
`.landin/packages/dev701/refine_build` does that.

## Testing it

```sh
tests/run.sh .landin/bootstrap/refine-build path/to/refine
```

Each case under `tests/cases` is a project; the script compares what the
tool says and how it ends with the case's `expected`. With a refine given,
a further check has the tool build itself and compares the two executables.

The store is checked with a small project built against stores of its
own: a second build starts no program, an edit runs what depends on it, an
output that did not change keeps the step that takes it, a kept step says
what it said, `always` and `--again` run, a failed step leaves no key and
no entry, two builds at once leave one entry a step, entries are
read-only, and a store of another form is refused. No test touches the
user's store.

Paths are checked with a program that names files through its view in
every form, and with refine's own warning and error: the project's path
shows on a first build and on a kept one, a path that only contains the
view's is left alone, and `--raw` shows what was said.

It then asks the tool to explain every code it lists, and holds that list
to `codes/codes.ldn` and to the codes the cases expect. With a refine, it
also puts the tool on PATH and runs it through `refine`: a build of this
package, `refine help`, a forwarded `refine explain` and a completion.

The script also checks memory. It repeats a whole build in one process
with `--repeat N`, an option for this test only, a few times and many
times, and fails when the many use more memory than the few. It needs GNU
`time` and says so when there is none.

The hashes are checked through `--hash-file PATH` and `--hash-tree PATH`,
two more options for the tests only. SHA-256 is held to the FIPS 180-4
examples, to lengths around a block's edges and to `sha256sum` on real
files, read in chunks of several sizes, and a 64 MiB file may take no more
memory than a 1 MiB one.

The tree hash is held to a hash written in the script, which
`tests/tree_hash.py` makes again from the form that `hash/tree/tree.ldn`
documents. A tree made in another order has to hash the same; a changed
content, name, execute bit or link target and an added empty directory
each have to change it.

## Hashes

The store stands on two hashes. A
file's content hash is the SHA-256 of its bytes. A tree's is the SHA-256
of one record for everything under its root, in the byte order of the
paths: what it is, its path, and for a file the length and SHA-256 of its
content, for a link its target. Times, owners and permission bits other
than the owner's execute bit do not count, and an empty directory does.
`hash/tree/tree.ldn` gives the form exactly.

## Memory

Nothing is freed block by block. Every allocation belongs to the process,
to one build or to one step, each a region over the heap that is released
when it ends; `lifetime/lifetime.ldn` says how. A step that is kept has a
region as one that runs has: its key file and what it says again live
there. A routine that allocates is
given the region it allocates from, so a build can be repeated in one
process, as a watch mode will, without the memory in use growing.

## Limits

- POSIX hosts only: links come from `platform/posix`.
- Each step is started through `env -C`, which needs GNU coreutils. The
  Landin library cannot yet start a program in another directory.
- Steps run one at a time.
- A line of a program's output longer than 8,192 bytes is passed on in
  pieces, and a path cut by a piece's end is not made the project's. What
  a program writes without a line end shows when the line ends or the
  program does.
- A step's key does not cover everything a program can depend on, so the
  store keeps a step in these cases although it would make something else:
  - the assembler and the linker `refine` finds on PATH have changed;
  - a shared library a program loads has changed;
  - a variable of the environment has changed, which every step is given
    whole;
  - a file the program reads outside its view has changed.
  `--again` runs everything.
- `packages` is the whole checkout, so an edit to any file of it, a README
  included, runs every step that takes `packages`.
- Two builds at once in one project directory are not guarded against each
  other: they share `.landin/`. Two projects on one store are.
- Nothing removes what the store no longer needs, nor what a build that was
  killed left in `tmp`.
- It is built and tested with a development build of `refine` from Landin's
  main branch. No released `refine` has been tried.

## The goalpost

This package is its own first user. It is done with a stage when the tool,
run in this directory, does that stage's part of the two files:

1. Reads `landin.package` and `landin.recipe` and refuses what is wrong in
   them. **Done.**
2. Builds the `packages` view and runs the `tool` and `checked` steps,
   giving the same `refine-build` that `bootstrap.sh` gives. **Done.**
3. Keeps each step's output in a store keyed by its inputs, so a second run
   does nothing. **Done.**

## Licence

MIT or Apache-2.0, at your option, as Landin is. See `LICENSE`.
