#!/bin/bash
set -euo pipefail
cli=${1:-.build/debug/macip}
"$cli" --version
"$cli" --help >/dev/null
"$cli" a >/dev/null
"$cli" a --all | /usr/bin/grep -q '^lo0 '
"$cli" a show lo0 | /usr/bin/grep -q '127.0.0.1'
"$cli" route >/dev/null
if "$cli" --unknown >/dev/null 2>&1; then
    echo 'Unknown option was accepted' >&2; exit 1
fi
if "$cli" a show macip_nonexistent_interface >/dev/null 2>&1; then
    echo 'Unknown interface was accepted' >&2; exit 1
fi
if "$cli" -c a | LC_ALL=C /usr/bin/grep -q $'\033'; then
    echo 'Color leaked into pipe' >&2; exit 1
fi
echo 'CLI checks passed'
