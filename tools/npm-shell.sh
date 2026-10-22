#!/bin/sh
# Expose the ordinary vendored CLI without creating node_modules/.bin.
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATH="$task_root/vendor/cli/bin:$PATH"
export PATH
exec /bin/sh "$@"
