#!/bin/sh
#  Builds refine-build by hand, for the first time or after a change that
#  broke the build of the last one.  It does what the tool does for the
#  `tool` step of landin.recipe: places this checkout at its package path,
#  .landin/packages/dev701/refine_build, and compiles with that as the one root.
#  The tool built this way and the one it then builds from the recipe are
#  the same bytes; tests/run.sh checks that.
#  It builds refine-build only.  refine-fetch, the package's other program,
#  is built by the recipe's `fetcher` step, which the tool built here runs.
#  Usage: ./bootstrap.sh [path/to/refine]     (default: refine on PATH)
set -eu
cd "$(dirname "$0")"
refine=${1:-refine}
mkdir -p .landin/packages/dev701 .landin/bootstrap
ln -sfn ../../.. .landin/packages/dev701/refine_build
"$refine" compile --root .landin/packages \
    .landin/packages/dev701/refine_build/cmd/build -o .landin/bootstrap/refine-build
echo "built .landin/bootstrap/refine-build"
