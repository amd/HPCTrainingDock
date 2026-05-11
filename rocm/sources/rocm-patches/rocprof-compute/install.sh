#!/bin/bash
# install.sh -- wire up the rocprof-compute overlay for a single ROCm version.
#
# Idempotent.  Reads the ROCm version from the parent directory name
# (rocm-patches-<X.Y.Z>/rocprof-compute/install.sh) so the same script
# is dropped into every overlay unmodified.
#
# What it does:
#   1.  Resolve $ROCM_VERSION from the path.
#   2.  Ensure lib/rocprof-compute.bin exists:
#       - if it already exists (real file or symlink), leave it alone.
#       - else, if /shared/apps/ubuntu/opt/rocm-${ROCM_VERSION}/bin/rocprof-compute.exe
#         exists and runs --version successfully, create lib/rocprof-compute.bin
#         as a symlink to it (shim mode).
#       - else, refuse with a hint to run build.sh.
#   3.  Ensure bin/rocprof-compute -> ../lib/rocprof-compute.bin .
#   4.  Edit the matching Lmod modulefile
#       /shared/apps/modules/ubuntu/lmodfiles/base/rocm/${ROCM_VERSION}.lua
#       to prepend PATH with this overlay's bin/ (only if not already present).
#
# The original ROCm distribution is NOT modified; the overlay shadows
# the broken in-distribution rocprof-compute via PATH ordering.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_NAME="$(basename "$(dirname "$SCRIPT_DIR")")"     # rocm-patches-X.Y.Z
ROCM_VERSION="${OVERLAY_NAME#rocm-patches-}"

if [[ ! "$ROCM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: could not derive ROCM_VERSION from path '$SCRIPT_DIR'" >&2
    exit 1
fi

# ROCM_PATH and MODULEFILE may be overridden by env (the default values
# match the way this overlay is staged on the cluster where it was first
# developed; HPCTrainingDock's rocm_patches.sh passes its own values via
# the environment).
ROCM_PATH="${ROCM_PATH:-/shared/apps/ubuntu/opt/rocm-${ROCM_VERSION}}"
EXE="${ROCM_PATH}/bin/rocprof-compute.exe"
MODULEFILE="${MODULEFILE:-/shared/apps/modules/ubuntu/lmodfiles/base/rocm/${ROCM_VERSION}.lua}"

OVR_BIN="${SCRIPT_DIR}/bin"
OVR_LIB="${SCRIPT_DIR}/lib"

mkdir -p "$OVR_BIN" "$OVR_LIB"

echo "[install] ROCM_VERSION=$ROCM_VERSION"
echo "[install] overlay     =$SCRIPT_DIR"

# --- 1.  lib/rocprof-compute.bin ---------------------------------------------

if [ -e "$OVR_LIB/rocprof-compute.bin" ] || [ -L "$OVR_LIB/rocprof-compute.bin" ]; then
    if [ -L "$OVR_LIB/rocprof-compute.bin" ]; then
        echo "[install] lib/rocprof-compute.bin already present (symlink -> $(readlink $OVR_LIB/rocprof-compute.bin))"
    else
        echo "[install] lib/rocprof-compute.bin already present (real file, $(stat -c%s "$OVR_LIB/rocprof-compute.bin") bytes)"
    fi
elif [ -x "$EXE" ] && "$EXE" --version >/dev/null 2>&1; then
    echo "[install] using in-distribution $EXE (shim mode)"
    ln -sfn "$EXE" "$OVR_LIB/rocprof-compute.bin"
else
    cat >&2 <<MSG
ERROR: no usable rocprof-compute binary found.
  Looked for:
    - $OVR_LIB/rocprof-compute.bin   (this overlay's nuitka-rebuilt binary)
    - $EXE                            (in-distribution prebuilt binary)
  Run ./build.sh to produce a fresh nuitka onefile, then re-run install.sh.
MSG
    exit 2
fi

# --- 2.  bin/rocprof-compute -> ../lib/rocprof-compute.bin -------------------

ln -sfn ../lib/rocprof-compute.bin "$OVR_BIN/rocprof-compute"
echo "[install] bin/rocprof-compute -> ../lib/rocprof-compute.bin"

# --- 3.  modulefile prepend_path ---------------------------------------------

MARKER="rocprof-compute overlay"
PREPEND_LINE="\tprepend_path(\"PATH\", \"${SCRIPT_DIR}/bin\")"

if [ ! -f "$MODULEFILE" ]; then
    echo "WARNING: modulefile not found at $MODULEFILE; skipping prepend_path edit."
    echo "         (Run 'module use' on an alternative tree manually if needed.)"
elif grep -q "$MARKER" "$MODULEFILE"; then
    echo "[install] modulefile already wired ($MODULEFILE)"
else
    # Insert AFTER the existing 'prepend_path("PATH", pathJoin(base, "bin"))'
    # line so the overlay's bin/ lands FIRST in resolved PATH (LIFO).
    BLOCK=$(printf '\n\t-- %s\n\t-- The overlay shadows the broken in-distribution rocprof-compute\n\t-- symlink.  See:\n\t--   %s/README.md\n%s\n' \
        "$MARKER" "$SCRIPT_DIR" "$PREPEND_LINE")
    TMP=$(mktemp)
    awk -v block="$BLOCK" '
        { print }
        /^prepend_path\("PATH", pathJoin\(base, "bin"\)\)$/ && !done {
            print block
            done = 1
        }
    ' "$MODULEFILE" > "$TMP"
    sudo install -m 0644 "$TMP" "$MODULEFILE"
    rm -f "$TMP"
    echo "[install] edited modulefile $MODULEFILE"
fi

echo "[install] DONE"
