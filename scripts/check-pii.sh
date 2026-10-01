#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
if [ ! -s .pii-patterns ]; then
    exit 0
fi
if git diff --cached --no-ext-diff --unified=0 -- . ':!docs/SPEC.md' | grep '^+' | grep -v '^+++' | grep -F -f .pii-patterns; then
    printf 'Staged changes match .pii-patterns\n' >&2
    exit 1
fi
