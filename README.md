# refine-build

A build tool for [Landin](https://github.com/JanHaan/Landin) packages,
written in Landin. It reads a package's description and its recipe and runs
the recipe's steps. It is a contributed command of `refine`: on PATH as
`refine-NAME`, it runs as `refine NAME`.

**Status: a prototype.** It reads and checks both files and runs steps one
after another. It fetches nothing and keeps no store: every run runs every
step again.

## Building it

```sh
./bootstrap.sh path/to/refine
.landin/bootstrap/refine-build --refine path/to/refine
```

The first line builds the tool by hand. The second has that tool build
itself from `landin.recipe`, into `.landin/steps/tool/out/refine-build`,
which is the same file byte for byte.

## Using it

Run it in a package's directory:

```sh
refine-build                 # the recipe's default steps
refine-build tool            # one step, after the steps it needs
refine-build --check         # read and check both files, run nothing
refine-build --refine PATH   # which refine a `run refine ...` line means
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

default tool
```

- Every line starts with a keyword. `run` and `set` belong to the `rule`
  or `step` before them; indentation means nothing.
- `run` is a list of words, started directly. No shell reads it.
- `{out}` is the step's own output directory, empty when the step starts.
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

Everything the tool writes is under `.landin/`.

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
| `steps/` | Views, output directories and running each step's program. |
| `files/` | Whole files, directory trees, links, and finding a program on PATH. |
| `hash/sha256/` | SHA-256, on the language alone, so that it can become a library. An integrity hash; it makes no constant-time claim. |
| `hash/file/` | A file's content hash, read in blocks. |
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

It then asks the tool to explain every code it lists, and holds that list
to `codes/codes.ldn` and to the codes the cases expect. With a refine, it
also puts the tool on PATH and runs it through `refine`: a build of this
package, `refine help`, a forwarded `refine explain` and a completion.

The script also checks memory. It repeats a whole build in one process
with `--repeat N`, an option for this test only, a few times and many
times, and fails when the many use more memory than the few. It needs GNU
`time` and says so when there is none.

SHA-256 is checked through `--hash-file PATH`, one more option for the
tests only. It is held to the FIPS 180-4 examples, to lengths around a
block's edges and to `sha256sum` on real files, read in chunks of several
sizes, and a 64 MiB file may take no more memory than a 1 MiB one. No
build uses a hash yet.

## Memory

Nothing is freed block by block. Every allocation belongs to the process,
to one build or to one step, each a region over the heap that is released
when it ends; `lifetime/lifetime.ldn` says how. A routine that allocates is
given the region it allocates from, so a build can be repeated in one
process, as a watch mode will, without the memory in use growing.

## Limits

- POSIX hosts only: links come from `platform/posix`.
- Each step is started through `env -C`, which needs GNU coreutils. The
  Landin library cannot yet start a program in another directory.
- Steps run one at a time, and all of them on every run.
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
   does nothing.

## Licence

MIT or Apache-2.0, at your option, as Landin is. See `LICENSE`.
