#!/bin/bash
# Build the Layer-2 rocprofiler-sdk guard tool + its self-test harness.
# Pure libc: no ROCm headers/link needed, so the .so is ROCm-version-independent.
set -euo pipefail
cd "$(dirname "$0")"

CC="${CC:-gcc}"
CFLAGS="-O2 -Wall -Wextra -Werror -fPIC"

echo ">>> building librocprof_guard.so"
$CC $CFLAGS -shared -Wl,-soname,librocprof_guard.so \
    -o librocprof_guard.so rocprof_guard.c

echo ">>> building selftest harness"
$CC -O2 -Wall -Wextra -o selftest selftest.c -ldl

echo ">>> symbol check (rocprofiler_configure must be exported, unmangled)"
nm -D --defined-only librocprof_guard.so | grep -w rocprofiler_configure \
    && echo "OK: rocprofiler_configure exported" \
    || { echo "FAIL: entry point missing"; exit 1; }

echo ">>> done: $(pwd)/librocprof_guard.so"
