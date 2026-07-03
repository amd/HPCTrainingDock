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

# ── Nuitka version selection (PEP 695 gate) ──────────────────────────
# The historical pin (Nuitka==2.6) crashes with an AssertionError in
# nuitka/tree/ReformulationAssignmentStatements.py:buildTypeAliasNode on
# PEP 695 generic type aliases (`type X[T] = ...`), a syntax Python 3.12
# introduced. Ubuntu 24.04 ships python3.12, so the rocprof-compute
# dependency closure now contains that syntax and the onefile build aborts
# (see Nuitka issues #3469 / #3692). Nuitka 4.1.3 handles the full PEP 695
# surface (generic type aliases, generic classes/functions, and ParamSpec
# aliases -- 2.8.x fixes the alias but still asserts on ParamSpec).
#
# Ubuntu 22.04 ships python3.10, which has no PEP 695 syntax at all, so we
# keep the known-good 2.6 pin there rather than perturb a working toolchain.
# The gate is on the Ubuntu major version (>= 24.04 -> 4.1.3); every other
# distro/version keeps 2.6. This applies to BOTH the pinned requirements
# (repinned below) and the explicit `pip install nuitka==...` line.
NUITKA_VERSION="2.6"
_os_id="$(. /etc/os-release && echo "${ID:-}")"
_os_ver="$(. /etc/os-release && echo "${VERSION_ID:-}")"
if [ "${_os_id}" = "ubuntu" ] && [ -n "${_os_ver}" ] \
   && [ "$(printf '%s\n' "24.04" "${_os_ver}" | sort -V | head -n1)" = "24.04" ]; then
    NUITKA_VERSION="4.1.3"
fi
echo "[build] Nuitka version selected: ${NUITKA_VERSION} (distro=${_os_id:-?} ${_os_ver:-?}, python=$(python3 -V 2>&1))" | tee -a "$LOG"

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
    # Official release line: rocm-7.1.0+ moved the rocprofiler-compute
    # tree into the rocm-systems monorepo at `projects/rocprofiler-compute`.
    # rocm-7.0.x and older still live in the standalone repo.
    if [ "$(printf '%s\n' "7.1.0" "$ROCM_VERSION" | sort -V | head -n1)" = "7.1.0" ]; then
        echo "[build] cloning rocm-systems @ rocm-${ROCM_VERSION} (sparse subtree projects/rocprofiler-compute) ..." | tee -a "$LOG"
        git clone --no-checkout --filter=blob:none https://github.com/ROCm/rocm-systems.git 2>&1 | tail -3 | tee -a "$LOG"
        cd rocm-systems
        git sparse-checkout init --cone
        git sparse-checkout set projects/rocprofiler-compute
        git -c advice.detachedHead=false checkout "rocm-${ROCM_VERSION}" 2>&1 | tail -3 | tee -a "$LOG"
        cd projects/rocprofiler-compute
    else
        # Official standalone rocprofiler-compute repo (rocm-7.0.x and older).
        # rocprofiler-compute is tagged `rocm-<ver>` for only a subset of ROCm
        # releases: point/delta releases such as 6.3.4 have NO matching tag or
        # branch upstream (the highest rocm-6.3 tag is rocm-6.3.3, then it
        # jumps to rocm-6.4.0). `git clone --branch rocm-6.3.4` therefore fails
        # hard. Resolve the best `rocm-<major>.<minor>.<patch>` ref by walking
        # the patch level down to .0 and cloning the first one that exists, so
        # a delta release still builds against its nearest base line.
        RPC_URL="https://github.com/ROCm/rocprofiler-compute.git"
        _rpc_major="${ROCM_VERSION%%.*}"
        _rpc_tmp="${ROCM_VERSION#*.}"; _rpc_minor="${_rpc_tmp%%.*}"
        _rpc_patch="${ROCM_VERSION##*.}"
        RPC_REF=""
        case "$_rpc_patch" in
            ''|*[!0-9]*)
                # Non-standard version string: only try the exact ref.
                if git ls-remote --exit-code "$RPC_URL" "rocm-${ROCM_VERSION}" >/dev/null 2>&1; then
                    RPC_REF="rocm-${ROCM_VERSION}"
                fi
                ;;
            *)
                for _p in $(seq "$_rpc_patch" -1 0); do
                    _cand="rocm-${_rpc_major}.${_rpc_minor}.${_p}"
                    if git ls-remote --exit-code "$RPC_URL" "$_cand" >/dev/null 2>&1; then
                        RPC_REF="$_cand"
                        break
                    fi
                done
                ;;
        esac
        if [ -z "$RPC_REF" ]; then
            echo "[build] no rocm-${_rpc_major}.${_rpc_minor}.* ref (<= ${ROCM_VERSION}) exists in" | tee -a "$LOG"
            echo "[build] ${RPC_URL}; cannot build rocprof-compute for ${ROCM_VERSION}."            | tee -a "$LOG"
            echo "[build] exit 43 (soft no-op) -- no rocprof-compute overlay produced."             | tee -a "$LOG"
            exit 43
        fi
        if [ "$RPC_REF" = "rocm-${ROCM_VERSION}" ]; then
            echo "[build] cloning rocprofiler-compute @ ${RPC_REF} ..." | tee -a "$LOG"
        else
            echo "[build] rocprofiler-compute has no rocm-${ROCM_VERSION} ref; falling back to nearest base ${RPC_REF} ..." | tee -a "$LOG"
        fi
        git clone --depth 1 --branch "$RPC_REF" "$RPC_URL" 2>&1 | tail -3 | tee -a "$LOG"
        cd rocprofiler-compute
    fi
fi

# ------------------------------------------------------------------ #
# Site patch: guard the second amd-smi static --json call against
# empty stdout (ROCm 7.1.x only).
#
# Upstream src/rocprof_compute_soc/soc_base.py calls
#   static_data = json.loads(
#       run(["amd-smi","static","--gpu=0","--json"], exit_on_error=True))
# WITHOUT a try/except.  On this cluster's compute nodes amd-smi
# returns an empty stdout (rc=2) when invoked this way under ROCm
# 7.1.x, which crashes the entire profiler at startup with
#   json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
#
# The first amd-smi call (src/utils/specs.py:255-264) is already
# guarded the same way; this patch mirrors that style.  Upstream
# commit a7bbe0c5d2 ("Use amd-smi Python API instead of CLI",
# #1334) replaces both sites with the amdsmi Python bindings in
# rocm-7.2.x, so we narrow this patch to 7.1.x only.
#
# The fix is functional only: when amd-smi returns nothing, we
# leave self._mspec.max_mclk unset (the same behaviour as upstream
# when amd-smi reports no frequency_levels).  --no-roof workloads
# such as the HPCTrainingExamples Rocprof-compute_ROCm_*_Check
# tests do not consume max_mclk.
#
# Implemented as a python in-place rewrite (rather than a unified
# diff) so the substitution is line-number-independent and idempotent.
# ------------------------------------------------------------------ #
if [ -z "$RC_FLAVOUR" ] && [[ "$ROCM_VERSION" =~ ^7\.1\. ]]; then
    echo "[build] applying site patch (soc_base.py: guard amd-smi static json.loads) for ${ROCM_VERSION}" | tee -a "$LOG"
    python3 - <<'PYEOF' 2>&1 | tee -a "$LOG"
import sys
src = "src/rocprof_compute_soc/soc_base.py"
with open(src) as f:
    content = f.read()

OLD = (
'        # Parse json from amd-smi static --clock\n'
'        static_data = json.loads(\n'
'            run(["amd-smi", "static", "--gpu=0", "--json"], exit_on_error=True)\n'
'        )\n'
'\n'
'        # Extract GPU data\n'
'        gpu_list = (\n'
'            static_data\n'
'            if isinstance(static_data, list)\n'
'            else static_data.get("gpu_data", [])\n'
'        )\n'
'        gpu_data = gpu_list[0] if gpu_list else {}\n'
'\n'
'        frequency_levels = (\n'
'            gpu_data.get("clock", {}).get("mem", {}).get("frequency_levels")\n'
'        )\n'
'        if frequency_levels:\n'
'            # Extract max memory clock frequency\n'
'            amd_smi_mclk = frequency_levels[max(frequency_levels.keys())]\n'
'            # 100 Mhz -> 100\n'
'            self._mspec.max_mclk = amd_smi_mclk.split()[0]\n'
)

NEW = (
'        # Parse json from amd-smi static --clock.  Site patch (ROCm 7.1.x):\n'
'        # amd-smi can return empty stdout (rc=2) on some hosts; the first\n'
'        # amd-smi call in utils/specs.py:255-264 is already guarded the\n'
'        # same way.  Upstream commit a7bbe0c5d2 (#1334) replaces both call\n'
'        # sites with the amdsmi Python API in rocm-7.2.x.\n'
'        static_output = run(\n'
'            ["amd-smi", "static", "--gpu=0", "--json"], exit_on_error=True\n'
'        )\n'
'        try:\n'
'            static_data = json.loads(static_output) if static_output else None\n'
'        except json.JSONDecodeError as e:\n'
'            console_warning(\n'
'                f"Failed to parse amd-smi static output in soc_base: {e}"\n'
'            )\n'
'            static_data = None\n'
'\n'
'        if static_data is not None:\n'
'            # Extract GPU data\n'
'            gpu_list = (\n'
'                static_data\n'
'                if isinstance(static_data, list)\n'
'                else static_data.get("gpu_data", [])\n'
'            )\n'
'            gpu_data = gpu_list[0] if gpu_list else {}\n'
'\n'
'            frequency_levels = (\n'
'                gpu_data.get("clock", {}).get("mem", {}).get("frequency_levels")\n'
'            )\n'
'            if frequency_levels:\n'
'                # Extract max memory clock frequency\n'
'                amd_smi_mclk = frequency_levels[max(frequency_levels.keys())]\n'
'                # 100 Mhz -> 100\n'
'                self._mspec.max_mclk = amd_smi_mclk.split()[0]\n'
)

if NEW in content:
    print(f"[patch] {src} already patched -- no-op")
    sys.exit(0)

n = content.count(OLD)
if n != 1:
    print(f"[patch] ERROR: expected exactly 1 match in {src}, found {n}", file=sys.stderr)
    sys.exit(2)

content = content.replace(OLD, NEW)
with open(src, 'w') as f:
    f.write(content)
print(f"[patch] OK: rewrote {src}")
PYEOF
    echo "[build] site patch applied cleanly" | tee -a "$LOG"
fi

# Pin Python deps for ROCm 7.1.0+ official releases.  Mirror of the
# locked list that lived in rocm/scripts/rocm_setup.sh up to 2026-05
# (the original home of the nuitka build, now retired in favour of
# this script).  Without the pin, transitive dep drift in upstream's
# loose `requirements.txt` periodically broke the build.  No override
# for RC trees (afar-*/therock-*): they pin to arbitrary historical
# commits with their own requirements -- let upstream's req file win
# there.
if [ -z "$RC_FLAVOUR" ] \
   && [ "$(printf '%s\n' "7.1.0" "$ROCM_VERSION" | sort -V | head -n1)" = "7.1.0" ]; then
    DISTRO_ID="$(. /etc/os-release && echo "${ID:-unknown}")"
    if [ "$DISTRO_ID" = "ubuntu" ]; then
        echo "[build] pinning requirements.txt for ubuntu / ROCm $ROCM_VERSION" | tee -a "$LOG"
        mv requirements.txt requirements.txt.upstream
        cat > requirements.txt <<'EOF'
astunparse==1.6.2
blinker==1.9.0
certifi==2026.1.4
charset-normalizer==3.4.4
click==8.3.1
colorlover==0.3.0
contourpy==1.3.2
cycler==0.12.1
dash==3.3.0
dash-bootstrap-components==2.0.4
dash-svg==0.0.12
dnspython==2.8.0
Flask==3.1.2
fonttools==4.61.1
greenlet==3.3.0
idna==3.11
importlib_metadata==8.7.1
itsdangerous==2.2.0
Jinja2==3.1.6
kaleido==0.2.1
kiwisolver==1.4.9
linkify-it-py==2.0.3
markdown-it-py==4.0.0
MarkupSafe==3.0.3
matplotlib==3.10.8
mdit-py-plugins==0.5.0
mdurl==0.1.2
narwhals==2.15.0
nest-asyncio==1.6.0
Nuitka==2.6
numpy==2.2.6
ordered-set==4.1.0
packaging==25.0
pandas==2.3.3
patchelf==0.17.2.4
pillow==12.1.0
platformdirs==4.5.1
plotext==5.3.2
plotille==5.0.0
plotly==6.5.1
Pygments==2.19.2
pymongo==4.16.0
pyparsing==3.3.1
python-dateutil==2.9.0
pytz==2025.2
PyYAML==6.0.3
requests==2.32.5
retrying==1.4.2
rich==14.2.0
six==1.17.0
SQLAlchemy==2.0.45
tabulate==0.9.0
textual==7.0.1
textual-fspicker==0.6.0
textual-plotext==1.0.1
tqdm==4.67.1
typing_extensions==4.15.0
tzdata==2025.3
uc-micro-py==1.0.3
urllib3==2.6.3
Werkzeug==3.1.5
zipp==3.23.0
zstandard==0.25.0
EOF
        # Repin Nuitka per the PEP 695 gate (see NUITKA_VERSION above) so the
        # `-r requirements.txt` install below doesn't downgrade back to 2.6.
        sed -i "s/^Nuitka==.*/Nuitka==${NUITKA_VERSION}/" requirements.txt
    elif [ "$DISTRO_ID" = "rhel" ] || [ "$DISTRO_ID" = "rocky" ] || [ "$DISTRO_ID" = "almalinux" ] || [ "$DISTRO_ID" = "centos" ]; then
        echo "[build] pinning requirements.txt for RHEL-family / ROCm $ROCM_VERSION" | tee -a "$LOG"
        mv requirements.txt requirements.txt.upstream
        cat > requirements.txt <<'EOF'
astunparse==1.6.2
blinker==1.9.0
certifi==2026.1.4
charset-normalizer==3.4.4
click==8.1.8
colorlover==0.3.0
contourpy==1.3.0
cycler==0.12.1
dash==3.4.0
dash-bootstrap-components==2.0.4
dash-svg==0.0.12
dnspython==2.7.0
Flask==3.1.2
fonttools==4.60.2
greenlet==3.2.4
idna==3.11
importlib_metadata==8.7.1
importlib_resources==6.5.2
itsdangerous==2.2.0
Jinja2==3.1.6
kaleido==0.2.1
kiwisolver==1.4.7
linkify-it-py==2.0.3
markdown-it-py==3.0.0
MarkupSafe==3.0.3
matplotlib==3.9.4
mdit-py-plugins==0.4.2
mdurl==0.1.2
narwhals==2.15.0
nest-asyncio==1.6.0
Nuitka==2.6
numpy==2.0.2
packaging==26.0
pandas==2.3.3
patchelf==0.17.2.4
pillow==11.3.0
platformdirs==4.4.0
plotext==5.3.2
plotille==5.0.0
plotly==6.5.2
Pygments==2.19.2
pymongo==4.16.0
pyparsing==3.3.2
python-dateutil==2.9.0.post0
pytz==2025.2
PyYAML==6.0.3
requests==2.32.5
retrying==1.4.2
rich==14.3.1
six==1.17.0
SQLAlchemy==2.0.46
tabulate==0.9.0
textual==7.5.0
textual-fspicker==0.6.0
textual-plotext==1.0.1
tqdm==4.67.1
typing_extensions==4.15.0
tzdata==2025.3
uc-micro-py==1.0.3
urllib3==2.6.3
Werkzeug==3.1.5
zipp==3.23.0
EOF
        # Repin Nuitka per the PEP 695 gate (see NUITKA_VERSION above). No-op
        # on RHEL-family today (gate only bumps Ubuntu 24.04) but keeps the two
        # pinned blocks symmetric if the gate is later widened.
        sed -i "s/^Nuitka==.*/Nuitka==${NUITKA_VERSION}/" requirements.txt
    fi
fi

python3 -m pip install "nuitka==${NUITKA_VERSION}" patchelf 2>&1 | tail -3 | tee -a "$LOG"
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
