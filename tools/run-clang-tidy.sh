#!/bin/bash
# clang-tidy wrapper for the pre-commit hook (see ../.pre-commit-config.yaml).
#
# Needs a compile_commands.json to do real analysis -- generated as a free
# side effect of pippinVR-Server/build-newt.sh (CMAKE_EXPORT_COMPILE_COMMANDS
# is on there), so a normal dev build already produces it. This script just
# checks it's there and fails with an actionable message if not, rather
# than a cryptic clang-tidy internal error on a fresh checkout that hasn't
# built Newt yet.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEWT_ROOT="$(dirname "${SCRIPT_DIR}")"
BUILD_DIR="${NEWT_BUILD_DIR:-${NEWT_ROOT}/../pippinVR-Server/.build/newt}"

if [ ! -f "${BUILD_DIR}/compile_commands.json" ]; then
    echo "error: no compile_commands.json at ${BUILD_DIR}" >&2
    echo "  Run pippinVR-Server/build-newt.sh once (or set NEWT_BUILD_DIR to" >&2
    echo "  an existing Newt CMake build dir), then retry the commit." >&2
    exit 1
fi

CLANG_TIDY="${CLANG_TIDY:-clang-tidy}"
if ! command -v "${CLANG_TIDY}" >/dev/null 2>&1 && [ -x /opt/homebrew/opt/llvm/bin/clang-tidy ]; then
    CLANG_TIDY=/opt/homebrew/opt/llvm/bin/clang-tidy
fi

# No --warnings-as-errors: this is the first time anything has linted this
# tree, and treating every pre-existing warning as a hard failure would
# block committing to any file that happens to already have one, for
# issues nobody touching that file right now is trying to fix. Findings
# still print to the terminal on every commit -- just not blocking.
exec "${CLANG_TIDY}" -p "${BUILD_DIR}" --checks='-*,bugprone-*,clang-analyzer-*' "$@"
