#!/bin/bash
# build.sh -- reproduce a nuitka onefile binary of rocprof-compute for the
# matching ROCm version, drop it into lib/rocprof-compute.bin .
#
# Two source-pinning modes:
#
#   (1) Official release line (ROCM_VERSION matches X.Y.Z):
#       upstream pin = git tag `rocm-${ROCM_VERSION}` on
#       https://github.com/ROCm/rocprofiler-compute.git
#
#   (2) Release-candidate flavours (ROCM_VERSION matches therock-*|afar-*):
#       upstream pin = the commit SHA recorded in
#       ${ROCM_PATH}/libexec/rocprofiler-compute/VERSION.sha
#       (so the rebuild reproduces, byte-for-byte intent, what the
#        .deb shipped with that RC tree was built from).
#       If VERSION.sha is missing or empty we exit 43 (the convention
#       rocm_patches.sh uses for soft no-op): we will NOT guess a
#       commit, because the .deb may have been built from an unmerged
#       branch we cannot identify.
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

# Accept either an official release (X.Y.Z) or an RC flavour
# (therock-X.Y.Z, afar-X.Y.Z, etc). The dash-prefixed family name is
# what distinguishes the two pinning modes below.
if [[ ! "$ROCM_VERSION" =~ ^([a-z]+-)?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: could not derive ROCM_VERSION from $SCRIPT_DIR" >&2
    exit 1
fi

# RC trees go through the VERSION.sha path; everything else uses the
# `rocm-${ROCM_VERSION}` upstream tag.
RC_FLAVOUR=""
if [[ "$ROCM_VERSION" =~ ^(therock|afar)- ]]; then
    RC_FLAVOUR="${ROCM_VERSION%%-*}"
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
BUILD_ROOT="$SCRIPT_DIR/build"
LOG="$BUILD_ROOT/build_${ROCM_VERSION}_${TS}.log"
WORK="$BUILD_ROOT/work_${ROCM_VERSION}_${TS}"

mkdir -p "$BUILD_ROOT" "$WORK"
echo "[build] ROCM_VERSION=$ROCM_VERSION  host=$(hostname)  start=$(date -u +%FT%TZ)" | tee "$LOG"
if [ -n "$RC_FLAVOUR" ]; then
    echo "[build] RC flavour: $RC_FLAVOUR (upstream pin from VERSION.sha)" | tee -a "$LOG"
fi

source /etc/profile.d/lmod.sh 2>/dev/null || true
module purge 2>/dev/null || true
module load rocm/"$ROCM_VERSION" 2>/dev/null || true

# For RC trees we need ROCM_PATH (set by the module load above, or
# injectable via env from rocm_patches.sh) to find VERSION.sha.
if [ -n "$RC_FLAVOUR" ]; then
    : "${ROCM_PATH:=/shared/apps/ubuntu/opt/rocm-${ROCM_VERSION}}"
    SHA_FILE="${ROCM_PATH}/libexec/rocprofiler-compute/VERSION.sha"
    if [ ! -f "$SHA_FILE" ]; then
        echo "[build] no VERSION.sha at ${SHA_FILE}; cannot pin upstream commit for RC tree." | tee -a "$LOG"
        echo "[build] exit 43 (soft no-op) -- no rocprof-compute overlay will be produced." | tee -a "$LOG"
        exit 43
    fi
    PIN_SHA="$(tr -d '[:space:]' < "$SHA_FILE")"
    if [ -z "$PIN_SHA" ]; then
        echo "[build] VERSION.sha is empty at ${SHA_FILE}; cannot pin upstream commit." | tee -a "$LOG"
        echo "[build] exit 43 (soft no-op) -- no rocprof-compute overlay will be produced." | tee -a "$LOG"
        exit 43
    fi
    echo "[build] VERSION.sha pin: ${PIN_SHA}" | tee -a "$LOG"
fi

cd "$WORK"
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate

python3 -m pip install --upgrade pip 2>&1 | tail -3 | tee -a "$LOG"

if [ -n "$RC_FLAVOUR" ]; then
    # Commit-pinned clone for RC trees.  VERSION.sha on RC trees ships
    # an abbreviated SHA (e.g. `bc96f0a`, `167a9576`) which git's
    # fetch-by-sha rejects (it requires full 40-char SHAs).  We do a
    # FULL clone with all remote branches/tags fetched -- the
    # rocprofiler-compute repo is small (~30 MB blobs) -- and then use
    # `git rev-parse --verify` to resolve the short SHA against the
    # local object DB.
    #
    # Empirical finding (2026-05): some RC .debs were built from
    # internal AMD branches whose commits are NEVER pushed to
    # github.com/ROCm/rocprofiler-compute.  This affects every
    # afar-22.x and therock-23.x tree on this cluster: the VERSION.sha
    # they ship is reachable from no public ref, and the GitHub
    # commits API returns 422 (Unprocessable) for those SHAs.
    # Strictly per the cluster policy "if we cannot identify the
    # upstream commit reliably, do not build", we treat unresolvable
    # SHAs as a soft no-op (exit 43) -- same as a missing VERSION.sha.
    echo "[build] cloning rocprofiler-compute (full clone, commit-pinned to ${PIN_SHA}) ..." | tee -a "$LOG"
    git clone https://github.com/ROCm/rocprofiler-compute.git 2>&1 | tail -5 | tee -a "$LOG"
    cd rocprofiler-compute
    # Pull every remote ref so commits on per-release branches are
    # reachable from the local repo.  --no-write-fetch-head keeps
    # subsequent rev-parse from getting confused by FETCH_HEAD.
    git fetch --all --tags 2>&1 | tail -3 | tee -a "$LOG"
    echo "[build] resolving short SHA ${PIN_SHA} against local object DB ..." | tee -a "$LOG"
    if FULL_SHA=$(git rev-parse --verify --quiet "${PIN_SHA}^{commit}" 2>/dev/null); then
        echo "[build] resolved: ${FULL_SHA}" | tee -a "$LOG"
        git -c advice.detachedHead=false checkout "$FULL_SHA" 2>&1 | tail -3 | tee -a "$LOG"
    else
        echo "[build] could NOT resolve ${PIN_SHA} in any public ref of"     | tee -a "$LOG"
        echo "[build] github.com/ROCm/rocprofiler-compute (likely built"     | tee -a "$LOG"
        echo "[build] from an internal AMD branch not pushed upstream)."     | tee -a "$LOG"
        echo "[build] Strictly applying the 'if no VERSION.sha resolvable,"  | tee -a "$LOG"
        echo "[build]                       do not build' policy:"           | tee -a "$LOG"
        echo "[build] exit 43 (soft no-op) -- no rocprof-compute overlay"    | tee -a "$LOG"
        echo "[build] will be produced for ${ROCM_VERSION}."                 | tee -a "$LOG"
        exit 43
    fi
else
    echo "[build] cloning rocprofiler-compute @ rocm-${ROCM_VERSION} ..." | tee -a "$LOG"
    git clone --depth 1 --branch "rocm-${ROCM_VERSION}" \
        https://github.com/ROCm/rocprofiler-compute.git 2>&1 | tail -3 | tee -a "$LOG"
    cd rocprofiler-compute
fi

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
