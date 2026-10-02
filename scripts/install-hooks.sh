#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
hooks=$(git rev-parse --git-path hooks)
mkdir -p "$hooks"
cp scripts/pre-commit "$hooks/pre-commit"
chmod +x "$hooks/pre-commit"
