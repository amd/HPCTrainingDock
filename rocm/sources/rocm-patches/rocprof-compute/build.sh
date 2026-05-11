#!/bin/bash
# build.sh -- reproduce a nuitka onefile binary of rocprof-compute for the
# matching ROCm version, drop it into lib/rocprof-compute.bin .
#
# Source: https://github.com/ROCm/rocprofiler-compute.git @ tag rocm-${ROCM_VERSION}
#
# This is idempotent: re-running rebuilds from a clean working directory.
# Wall time is ~30 min on an MI300A compute node; intended to be invoked
# under SLURM or on an interactive compute node, not on a login node.
#
# Auto-detects which optional subpackages are present in the upstream
# source (rocprof_compute_tui appeared in v3.2.x; absent in v3.1.x), so
# the same script works for every supported ROCm version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_NAME="$(basename "$(dirname "$SCRIPT_DIR")")"
ROCM_VERSION="${OVERLAY_NAME#rocm-patches-}"

if [[ ! "$ROCM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: could not derive ROCM_VERSION from $SCRIPT_DIR" >&2
    exit 1
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
BUILD_ROOT="$SCRIPT_DIR/build"
LOG="$BUILD_ROOT/build_${ROCM_VERSION}_${TS}.log"
WORK="$BUILD_ROOT/work_${ROCM_VERSION}_${TS}"

mkdir -p "$BUILD_ROOT" "$WORK"
echo "[build] ROCM_VERSION=$ROCM_VERSION  host=$(hostname)  start=$(date -u +%FT%TZ)" | tee "$LOG"

source /etc/profile.d/lmod.sh 2>/dev/null || true
module purge 2>/dev/null || true
module load rocm/"$ROCM_VERSION" 2>/dev/null || true

cd "$WORK"
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate

python3 -m pip install --upgrade pip 2>&1 | tail -3 | tee -a "$LOG"

echo "[build] cloning rocprofiler-compute @ rocm-${ROCM_VERSION} ..." | tee -a "$LOG"
git clone --depth 1 --branch "rocm-${ROCM_VERSION}" \
    https://github.com/ROCm/rocprofiler-compute.git 2>&1 | tail -3 | tee -a "$LOG"
cd rocprofiler-compute

python3 -m pip install nuitka==2.6 patchelf 2>&1 | tail -3 | tee -a "$LOG"
python3 -m pip install -r requirements.txt 2>&1 | tail -10 | tee -a "$LOG"

UPSTREAM_VERSION=$(cat VERSION)
UPSTREAM_SHA=$(git rev-parse HEAD)
echo "[build] upstream VERSION=$UPSTREAM_VERSION  sha=$UPSTREAM_SHA" | tee -a "$LOG"

cd src
# Write VERSION.sha to BOTH src/ (where the source convention puts it)
# and the repo root (where --include-data-files=${PROJECT_SOURCE_DIR}/VERSION*=./
# looks for it).  v3.1.x crashes hard at startup if VERSION.sha isn't
# bundled, whereas v3.2.x falls back gracefully to "unknown"; writing to
# both is required for v3.1.x and harmless for v3.2.x.
echo "$UPSTREAM_SHA" > VERSION.sha
echo "$UPSTREAM_SHA" > ../VERSION.sha
export PROJECT_SOURCE_DIR="$(pwd)/.."

# Optional: add --include-package=rocprof_compute_tui only if the subpackage
# is present (it appeared in v3.2.x; v3.1.x lacks it).
TUI_FLAGS=()
if [ -d "rocprof_compute_tui" ]; then
    TUI_FLAGS=(--include-package=rocprof_compute_tui
               --include-package-data=rocprof_compute_tui)
fi

echo "[build] running nuitka (~10-30 min) ..." | tee -a "$LOG"
python3 -m nuitka --mode=onefile --no-deployment-flag=self-execution \
    --include-data-files=${PROJECT_SOURCE_DIR}/VERSION*=./ \
    --enable-plugin=no-qt --enable-plugin=no-qt \
    --include-package=dash_svg --include-package-data=dash_svg \
    --include-package=dash_bootstrap_components \
    --include-package-data=dash_bootstrap_components \
    --include-package=plotly --include-package-data=plotly \
    --noinclude-data-files=plotly/datasets/* \
    --include-package=kaleido --include-package-data=kaleido \
    --include-package=rocprof_compute_analyze \
    --include-package-data=rocprof_compute_analyze \
    --include-package=rocprof_compute_profile \
    --include-package-data=rocprof_compute_profile \
    "${TUI_FLAGS[@]}" \
    --include-package=rocprof_compute_soc --include-package-data=rocprof_compute_soc \
    --include-package=utils --include-package-data=utils \
    rocprof-compute 2>&1 | tail -30 | tee -a "$LOG"

patchelf --remove-rpath rocprof-compute.bin

echo "[build] sanity-check --version ..." | tee -a "$LOG"
./rocprof-compute.bin --version 2>&1 | tee -a "$LOG"

mkdir -p "$SCRIPT_DIR/lib"
DEST="$SCRIPT_DIR/lib/rocprof-compute-v${UPSTREAM_VERSION}.bin"
install -m 0755 rocprof-compute.bin "$DEST"

# Make/refresh the canonical lib/rocprof-compute.bin symlink so
# install.sh picks up the fresh build instead of falling back to the
# in-distribution .exe shim.
ln -sfn "$(basename "$DEST")" "$SCRIPT_DIR/lib/rocprof-compute.bin"

echo "[build] installed $DEST" | tee -a "$LOG"
echo "[build] sha256: $(sha256sum "$DEST" | awk '{print $1}')" | tee -a "$LOG"
echo "[build] size:   $(stat -c%s "$DEST") bytes" | tee -a "$LOG"
echo "[build] DONE   ($(date -u +%FT%TZ))" | tee -a "$LOG"

deactivate
echo
echo "Next: run ./install.sh to wire the modulefile."
