#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# ── Preflight: declare and load required Lmod modules ─────────────────
# Inlined (formerly bare_system/lib/preflight.sh) so this script is
# self-contained and can be copied/run standalone. preflight_modules
# loads each module in order; on the first failure it prints the Lmod
# diagnostic and returns MISSING_PREREQ_RC=42, which the parent
# main_setup.sh re-classifies as SKIPPED rather than FAILED.
MISSING_PREREQ_RC=42
if ! type module >/dev/null 2>&1; then
   [ -r /etc/profile.d/lmod.sh ]            && . /etc/profile.d/lmod.sh
   [ -r /usr/share/lmod/lmod/init/bash ]    && . /usr/share/lmod/lmod/init/bash
fi
preflight_modules() {
   [ "$#" -eq 0 ] && return 0
   if ! type module >/dev/null 2>&1; then
      echo "ERROR: Lmod 'module' command not available; needed:$(printf ' %s' "$@")" >&2
      return ${MISSING_PREREQ_RC}
   fi
   echo "preflight: required modules:$(printf ' %s' "$@")"
   local m err
   err=$(mktemp -t preflight.XXXXXX.err 2>/dev/null || echo /tmp/preflight.$$.err)
   for m in "$@"; do
      if ! module load "${m}" 2>"${err}"; then
         echo "ERROR: required module '${m}' could not be loaded." >&2
         [ -s "${err}" ] && sed 's/^/  module> /' "${err}" >&2
         rm -f "${err}"
         return ${MISSING_PREREQ_RC}
      fi
   done
   rm -f "${err}"
   echo "preflight: all required modules loaded."
}

# Variables controlling setup process
ROCM_VERSION=6.4.3
BUILD_HIP_PYTHON=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/hip-python
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
HIP_PYTHON_PATH=/opt/rocmplus-${ROCM_VERSION}/hip-python
HIP_PYTHON_PATH_INPUT=""
HIP_PYTHON_VERSION=""    # empty -> use "${ROCM_VERSION}.*" pip wildcard (legacy default)
# --replace 1: rm -rf prior install dir + ${ROCM_VERSION}.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-hip-python [ BUILD_HIP_PYTHON ] default $BUILD_HIP_PYTHON "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ HIP_PYTHON_PATH ] default $HIP_PYTHON_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --hip-python-version [ HIP_PYTHON_VERSION ] PyPI version specifier (default: \${ROCM_VERSION}.*)"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: print this usage information"
   exit 1
}

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--build-hip-python")
          shift
          BUILD_HIP_PYTHON=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          HIP_PYTHON_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--hip-python-version")
          shift
          HIP_PYTHON_VERSION=${1}
          reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
          reset-last
          ;;
      "--keep-failed-installs")
          shift
          KEEP_FAILED_INSTALLS=${1}
          reset-last
          ;;
      "--*")
          send-error "Unsupported argument at position $((${n} + 1)) :: ${1}"
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

if [ "${HIP_PYTHON_PATH_INPUT}" != "" ]; then
   HIP_PYTHON_PATH=${HIP_PYTHON_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   HIP_PYTHON_PATH=/opt/rocmplus-${ROCM_VERSION}/hip-python
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is ${ROCM_VERSION}.lua to match the
# `tee ${MODULE_PATH}/${ROCM_VERSION}.lua` write below.
# ── BUILD_HIP_PYTHON=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_HIP_PYTHON}" = "0" ]; then
   echo "[hip-python BUILD_HIP_PYTHON=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── Early sudo decision (see mpi4py_setup.sh) ───────────────────────
# Determine whether privilege escalation is needed BEFORE the --replace
# block and EXIT trap (both rm install/module paths via ${SUDO}). When the
# operator owns a writable install tree (e.g. a user-writable
# /shareddata/opt) no sudo is needed -- and forcing it would hit a password
# prompt that fails on a node where the user has no sudo. Probe the nearest
# EXISTING ancestor of HIP_PYTHON_PATH (the leaf dir does not exist yet).
# The build branch re-affirms this below.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _probe="${HIP_PYTHON_PATH}"
   while [ ! -e "${_probe}" ]; do _probe="$(dirname "${_probe}")"; done
   # Real write test (mktemp), NOT `[ -w ]`: on NFS `-w` is a LYING probe --
   # it reported "writable" on the compute node for a root:root 0755 tree
   # where actual writes / rm fail (the exact failure mode netcdf_setup.sh
   # warns about). Mirrors the rocshmem PKG_SUDO_MOD mktemp probe.
   _wtest=$(mktemp --tmpdir="${_probe}" .hip-python-write-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_wtest}" ] && [ -f "${_wtest}" ]; then
      rm -f "${_wtest}"
      SUDO=""
      echo "install path ancestor ${_probe} is writable (probe succeeded); not using sudo"
   else
      echo "install path ancestor ${_probe} not user-writable (probe failed); using sudo"
   fi
   unset _wtest
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[hip-python --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HIP_PYTHON_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${ROCM_VERSION}{,.lua}"
   ${SUDO} rm -rf "${HIP_PYTHON_PATH}"
   # Remove both flavors (Lmod .lua and Tcl no-extension).
   ${SUDO} rm -f  "${MODULE_PATH}/${ROCM_VERSION}.lua" "${MODULE_PATH}/${ROCM_VERSION}"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${HIP_PYTHON_PATH}" ]; then
   echo ""
   echo "[hip-python existence-check] ${HIP_PYTHON_PATH} already installed; skipping."
   echo "                             pass --replace 1 to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (HIP_PYTHON_BUILD_DIR, set
# under BUILD_HIP_PYTHON=1) + fail-cleanup. Replaces inline build-dir
# `trap '... rm HIP_PYTHON_BUILD_DIR ...' EXIT` later in the script.
_hip_python_on_exit() {
   local rc=$?
   # ${SUDO} verbatim (NOT ${SUDO:-sudo}): once the build decides the tree is
   # operator-writable it sets SUDO="" , and these cleanups must then run
   # WITHOUT sudo (else an empty value resurrects a failing password prompt
   # on every exit). SUDO is always set (default "sudo" at top of script).
   [ -n "${HIP_PYTHON_BUILD_DIR:-}" ] && ${SUDO} rm -rf "${HIP_PYTHON_BUILD_DIR}"
   # attempted-but-failed marker (inventory 'F' glyph): persistent sibling
   # of the install dir that survives the rm -rf below; cleared on success.
   _fail_marker="$(dirname "${HIP_PYTHON_PATH}")/hip-python.FAILED"
   if [ ${rc} -ne 0 ]; then
      ${SUDO} mkdir -p "$(dirname "${HIP_PYTHON_PATH}")" 2>/dev/null || true
      ${SUDO} tee "${_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: hip-python
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    hip-python_setup.sh (EXIT-trap fail marker)
Reason:          build exited rc=${rc}; partial install wiped (see log_hip-python_*.txt).
MARKER_EOF
   else
      ${SUDO} rm -f "${_fail_marker}"
   fi
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hip-python fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO} rm -rf "${HIP_PYTHON_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/${ROCM_VERSION}.lua" "${MODULE_PATH}/${ROCM_VERSION}"
   elif [ ${rc} -ne 0 ]; then
      echo "[hip-python fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _hip_python_on_exit EXIT

echo ""
echo "==================================="
echo "Starting HIP-Python Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_HIP_PYTHON: $BUILD_HIP_PYTHON"
echo "HIP_PYTHON_PATH: $HIP_PYTHON_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

if [ "${BUILD_HIP_PYTHON}" = "0" ]; then

   echo "HIP-Python will not be built, according to the specified value of BUILD_HIP_PYTHON"
   echo "BUILD_HIP_PYTHON: $BUILD_HIP_PYTHON"
   exit

else
   # Per-job throwaway scratch dir under /tmp (or $TMPDIR if Slurm
   # set one). Replaces a bare `cd /tmp` followed by a fixed
   # `hip-python-build` venv path — concurrent rocm-version jobs
   # would race on /tmp/hip-python-build (deactivate of one and
   # `rm -rf hip-python-build` of the other could nuke an in-flight
   # pip install). Only `pip install --target=$HIP_PYTHON_PATH`
   # writes hit NFS. EXIT trap handles cleanup of the build venv.
   HIP_PYTHON_BUILD_DIR=$(mktemp -d -t hip-python-build.XXXXXX)
   # NOTE: build-dir cleanup is consolidated into _hip_python_on_exit
   # installed above (so the same EXIT handler also does fail-cleanup
   # of any partial install / modulefile).
   cd "${HIP_PYTHON_BUILD_DIR}"

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

   # Derive the rocm modulefile token to (re-)load. Three sources, in
   # decreasing order of authority:
   #   1. LMOD's LOADEDMODULES: the literal modulefile name currently
   #      loaded (e.g. rocm/therock-afar-23.2.1). Only source that
   #      handles the therock-afar dual scheme where install dir is
   #      rocm-therock-afar-<NUMERIC> but the module is keyed on the
   #      release tag (rocm/therock-afar-<RELEASE>).
   #   2. ROCM_PATH basename: install-dir basename minus the `rocm-`
   #      prefix. Correct for regular releases + afar (install-dir
   #      basename == module name) but wrong for therock-afar.
   #   3. rocm/${ROCM_VERSION}: standalone-invocation fallback when
   #      neither LOADEDMODULES nor ROCM_PATH is populated.
   ROCM_MODULE_NAME=""
   if [[ -n "${LOADEDMODULES:-}" ]]; then
      _OLD_IFS="${IFS}"; IFS=":"
      for _m in ${LOADEDMODULES}; do
         case "${_m}" in
            rocm/*) ROCM_MODULE_NAME="${_m}"; break ;;
         esac
      done
      IFS="${_OLD_IFS}"; unset _OLD_IFS _m
   fi
   if [[ -z "${ROCM_MODULE_NAME}" ]]; then
      if [[ -n "${ROCM_PATH:-}" ]]; then
         _rp_bn="${ROCM_PATH##*/}"
         ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
         unset _rp_bn
      else
         ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
      fi
   fi

   if [ -f "${CACHE_FILES}/hip-python.tgz" ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HIP-Python"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/hip-python
      cd /opt/rocmplus-${ROCM_VERSION}
      #${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/hip-python.tgz
      #chown -R root:root /opt/rocmplus-${ROCM_VERSION}/hip-python
      #${SUDO} chmod og-w /opt/rocmplus-${ROCM_VERSION}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/hip-python.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building HIP-Python"
      echo "============================"
      echo " HIP_PYTHON_PATH is $HIP_PYTHON_PATH"
      echo ""


      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── PyPI version selection: handle missing wheels for ROCM_VERSION ─
      # hip-python on test.pypi.org is published per upstream ROCm release
      # (e.g. 5.4.3.x, ..., 6.3.0.x, 6.3.1.x, 6.3.2.x, 6.3.3.x, 6.4.0.x,
      # ..., 7.2.2.562.43). The publication is sparse: not every ROCm
      # point release gets a wheel (e.g. 6.3.4 was skipped, slurm 8492
      # 2026-05-06; therock-23.x SDKs are pre-release and never get one).
      #
      # Three policies, in priority order:
      #   1. --hip-python-version <spec> -- operator override, used as-is.
      #   2. therock-* SDKs (ROCM_PATH matches *therock*): pick the
      #      LATEST published hip-python. ABI is forward-compatible
      #      (hip-python dlopen's libamdhip64 at runtime via the rocm
      #      module's LD_LIBRARY_PATH, no DT_NEEDED ABI lock), so a
      #      7.2.2.x wheel running against a 7.12.0 therock SDK works.
      #   3. Numbered SDKs (rocm-X.Y.Z): probe PyPI; if at least one
      #      "${ROCM_VERSION}.*" wheel exists, use the legacy wildcard
      #      and let pip pick the highest match (no behaviour change).
      #      If NONE match (e.g. 6.3.4 has no 6.3.4.x wheel), fall
      #      back to the NEAREST-LOWER published version on the same
      #      major.minor lineage (6.3.4 -> 6.3.3.540.31). Nearest-
      #      lower is preferred over latest because the 6.3.x runtime
      #      ABI is much closer to a 6.3.x wheel than a 7.x wheel.
      #
      # Without this fallback:
      #   - therock-23.1.0 (slurm 8372, 2026-05-05): "pip install
      #     hip-python==7.12.0.*" -> No matching distribution found.
      #   - 6.3.4 (slurm 8492, 2026-05-06): "pip install
      #     hip-python==6.3.4.*" -> same error.
      #
      # If the network probe fails (CI or air-gapped builds), preserve
      # the safe behaviour: exit MISSING_PREREQ_RC=42 so main_setup.sh
      # buckets the package as SKIPPED instead of FAILED.
      if [[ -z "${HIP_PYTHON_VERSION}" ]]; then
         echo ""
         echo "[hip-python pypi-probe] ROCM_PATH=${ROCM_PATH:-<unset>}"
         echo "                        ROCM_VERSION=${ROCM_VERSION}"
         echo "                        probing test.pypi.org for matching hip-python wheel..."
         _hp_choice=$(python3 - "${ROCM_VERSION}" "${ROCM_PATH:-}" <<'PY' 2>/dev/null
import json, sys, urllib.request
target = sys.argv[1]
rocm_path = sys.argv[2] if len(sys.argv) > 2 else ""
is_therock = "therock" in rocm_path
def vkey(v):
    return tuple(int(p) if p.isdigit() else 0 for p in v.split('.'))
try:
    data = json.loads(urllib.request.urlopen(
        'https://test.pypi.org/pypi/hip-python/json', timeout=30).read())
    versions = sorted(data.get('releases', {}).keys(), key=vkey)
    if not versions:
        sys.exit(1)
    if is_therock:
        # therock: latest published wheel (forward-compat dlopen ABI)
        print("LATEST", versions[-1])
    else:
        # numbered SDK: prefer exact-match prefix `${ROCM_VERSION}.`
        prefix = target + "."
        exact = [v for v in versions if v.startswith(prefix)]
        if exact:
            # at least one match exists; emit WILDCARD so caller uses
            # the legacy `${ROCM_VERSION}.*` spec and lets pip resolve
            print("WILDCARD", "")
        else:
            # no match: pick nearest-LOWER published version
            target_key = vkey(target)
            lower = [v for v in versions if vkey(v) <= target_key]
            if not lower:
                sys.exit(2)  # no lower version exists either
            print("NEAREST_LOWER", lower[-1])
except Exception:
    sys.exit(1)
PY
)
         _hp_rc=$?
         if [ ${_hp_rc} -ne 0 ] || [ -z "${_hp_choice}" ]; then
            echo ""
            echo "[hip-python pypi-probe] FAILED (rc=${_hp_rc}: network down? proxy? no lower version?)"
            echo "                        cannot determine an installable hip-python version."
            echo "                        Skipping with rc=${MISSING_PREREQ_RC} (MISSING-PREREQ)."
            echo "                        To force, pass --hip-python-version <spec>"
            echo "                        (e.g. --hip-python-version 7.2.2.562.43)."
            echo ""
            exit ${MISSING_PREREQ_RC}
         fi
         _hp_mode="${_hp_choice%% *}"
         _hp_ver="${_hp_choice#* }"
         case "${_hp_mode}" in
            LATEST)
               HIP_PYTHON_VERSION="${_hp_ver}"
               echo "                        therock SDK -> LATEST published wheel: ${HIP_PYTHON_VERSION}"
               ;;
            WILDCARD)
               echo "                        exact match exists -> using legacy wildcard ${ROCM_VERSION}.*"
               ;;
            NEAREST_LOWER)
               HIP_PYTHON_VERSION="${_hp_ver}"
               echo "                        no exact match -> NEAREST-LOWER wheel: ${HIP_PYTHON_VERSION}"
               echo "                        (rationale: 6.3.x runtime ABI is closer to a 6.3.x wheel than to 7.x)"
               ;;
            *)
               echo "                        WARNING: unexpected probe output: ${_hp_choice}"
               echo "                        Skipping with rc=${MISSING_PREREQ_RC}."
               exit ${MISSING_PREREQ_RC}
               ;;
         esac
         echo ""
         unset _hp_choice _hp_rc _hp_mode _hp_ver
      fi

      # ── Derive numba-hip extras name ────────────────────────────────
      # numba-hip's pyproject.toml exposes per-rocm-release optional
      # dependency groups named `rocm-X-Y-Z` (HYPHENS, three numeric
      # components only -- e.g. `rocm-7-2-2`, NOT `rocm-7-2-2-562-43`).
      # Verified 2026-05-06 against the dev branch
      # (https://raw.githubusercontent.com/ROCm/numba-hip/dev/pyproject.toml).
      #
      # The legacy line used `numba-hip[rocm-${ROCM_VERSION}]` (DOTS),
      # which is a latent bug across all rocm versions: pip silently
      # treats an unknown extra as a no-op so the install succeeded
      # but pulled NO hip-python / hip-python-as-cuda / rocm-llvm-python
      # transitive deps under numba-hip. We're re-installing those by
      # name above so the runtime impact was nil, but it leaves
      # `numba-hip[rocm-X-Y-Z]` machinery unexercised.
      #
      # Pick the X-Y-Z extras suffix from whichever version we're
      # actually installing: the user override, the therock fallback,
      # or the rocm SDK numeric (in that priority order). Truncate to
      # 3 components since the extras only ship that granularity.
      NUMBA_HIP_VERSION_BASE="${HIP_PYTHON_VERSION:-${ROCM_VERSION}}"
      NUMBA_HIP_EXTRA_SUFFIX="$(echo "${NUMBA_HIP_VERSION_BASE}" \
         | awk -F. '{ printf "%s-%s-%s", $1, $2, $3 }')"

      export HIP_PYTHON_INSTALL_USE_HIP=1
      export ROCM_HOME=${ROCM_PATH}
      export HIPCC=${ROCM_HOME}/bin/hipcc
      export HCC_AMDGPU_ARCH=${AMDGPU_GFXMODEL}

      # SUDO was already decided by the early-probe block above (writable
      # ancestor -> ""). Honor it instead of re-probing the not-yet-created
      # leaf dir (which always forced sudo).
      ${SUDO} mkdir -p $HIP_PYTHON_PATH
      if [ -n "${SUDO}" ] && [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $HIP_PYTHON_PATH
      fi
      python3 -m venv hip-python-build
      source hip-python-build/bin/activate
      python3 -m pip install pip --upgrade
      HIP_PYTHON_PIP_SPEC="${HIP_PYTHON_VERSION:-${ROCM_VERSION}.*}"
      echo "Installing hip-python with PyPI spec: ${HIP_PYTHON_PIP_SPEC}"
      echo "Installing numba-hip with extras suffix: rocm-${NUMBA_HIP_EXTRA_SUFFIX}"
      python3 -m pip install --target=$HIP_PYTHON_PATH/hip-python -i https://test.pypi.org/simple "hip-python==${HIP_PYTHON_PIP_SPEC}" --force-reinstall --no-cache
      python3 -m pip install --target=$HIP_PYTHON_PATH/hip-python -i https://test.pypi.org/simple "hip-python-as-cuda==${HIP_PYTHON_PIP_SPEC}" --force-reinstall --no-cache
      python3 -m pip config set global.extra-index-url https://test.pypi.org/simple
      # numba-hip + numba namespace collision (two-pass install) ─────────
      # numba-hip overlays the `numba` namespace (it ships numba/hip/...)
      # while its dependency numba 0.60.0 ships numba/core, numba/np, ...
      # into the SAME --target dir. A single resolved pip install lets one
      # clobber the other (whichever pip writes "second" wins, the other's
      # files are dropped) -- so you end up with EITHER numba/core XOR
      # numba/hip, never both. Symptoms seen in the wild:
      #   - no --upgrade: numba/hip lands, numba/core is SKIPPED
      #     ("Target directory numba already exists") -> `from numba import
      #     hip` dies with "No module named 'numba.core'".
      #   - with --upgrade in one pass: numba/core lands but numba/hip is
      #     gone -> "No module named 'numba.hip'".
      # Fix: two passes. Pass 1 resolves + installs all deps (lands stock
      # numba => numba/core, llvmlite, numpy, rocm-llvm-python, ...).
      # Pass 2 re-lays ONLY numba-hip's own files (numba/hip) with
      # --no-deps --upgrade so it overlays the existing numba/ dir without
      # re-pulling/clobbering stock numba. Result: numba/core + numba/hip
      # coexist and `from numba import hip` works.
      # ── numba-hip install: venv-merge-then-copy (NOT pip --target) ─────
      # numba-hip overlays the `numba` namespace: it ships numba/hip/...,
      # while its dependency numba (0.60.0) ships numba/core, numba/np, ...
      # Both must live in the SAME numba/ dir for `from numba import hip`
      # to work (numba/hip/hipdrv does `from numba.core import config`).
      # pip's --target mode CANNOT merge two distributions into one shared
      # top-level dir -- any --target install/--upgrade/--force-reinstall
      # of a package owning part of numba/ wipes the WHOLE numba/ dir, so
      # you always end up with numba/core XOR numba/hip, never both
      # (verified empirically on this stack; this is the pre-existing bug
      # that left numba.hip / numba.core unimportable). A real
      # site-packages merges them correctly. So install numba-hip + deps
      # into the BUILD VENV (no --target) and copy the merged tree into the
      # install dir.
      python3 -m pip install "numba-hip[rocm-${NUMBA_HIP_EXTRA_SUFFIX}] @ git+https://github.com/ROCm/numba-hip.git" --force-reinstall --no-cache
      _VENV_SITE="$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
      ${SUDO} mkdir -p "$HIP_PYTHON_PATH/numba-hip"
      # Copy everything pip produced EXCEPT the venv's own packaging
      # tooling. cp -a preserves the merged numba/ (core + hip together)
      # plus numba's runtime deps (llvmlite, numpy, rocm-llvm-python, ...).
      ( cd "${_VENV_SITE}" && for _e in *; do
           case "${_e}" in
              pip|pip-*|setuptools|setuptools-*|pkg_resources|wheel|wheel-*|_distutils_hack|distutils-precedence.pth|__pycache__) continue ;;
           esac
           ${SUDO} cp -a "${_e}" "$HIP_PYTHON_PATH/numba-hip/"
        done )
      unset _VENV_SITE
      deactivate
      # hip-python-build venv lives under HIP_PYTHON_BUILD_DIR
      # (under /tmp) and is removed by the EXIT trap above.
      # ── Shebang rewrite ────────────────────────────────────────────
      # pip console_script wrappers under numba-hip/bin (numba, f2py,
      # numpy-config) get baked with `#!${HIP_PYTHON_BUILD_DIR}/
      # hip-python-build/bin/python3` because pip --target invokes
      # the venv's python. The /tmp build dir vanishes with the EXIT
      # trap, breaking any direct call to numba afterwards. Same root
      # cause + same fix as pytorch_setup.sh / cupy_setup.sh (see
      # bare_system/fix_python_venv_shebangs.sh + audit 2026-05-07:
      # 75 broken numba-hip wrappers across 25 installs).
      # /usr/bin/env python3 works because the hip-python modulefile
      # prepends ${HIP_PYTHON_PATH}/numba-hip onto PYTHONPATH, so
      # `from numba ...` resolves under the system python3 once
      # `module load hip-python` is in effect.
      for _hp_bin in ${HIP_PYTHON_PATH}/numba-hip/bin ${HIP_PYTHON_PATH}/hip-python/bin; do
         [ -d "${_hp_bin}" ] || continue
         ${SUDO} find "${_hp_bin}" -maxdepth 1 -type f \
            -exec sed -i '1s|^#!.*python3.*$|#!/usr/bin/env python3|' {} + 2>/dev/null || true
      done
      unset _hp_bin
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find $HIP_PYTHON_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $HIP_PYTHON_PATH -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} chmod go-w $HIP_PYTHON_PATH
      fi
   fi

   # Create a module file for hip-python
   #
   # Modulefile-write sudo: probe the nearest existing ancestor of
   # MODULE_PATH for writability (mirrors the install-path early-probe).
   # When the operator owns a writable module tree (e.g. /shareddata/modules)
   # no sudo is used; otherwise fall back to sudo.
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      PKG_SUDO_MOD=""
   else
      _mprobe="${MODULE_PATH}"
      while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
      # Real write test (mktemp), NOT `[ -w ]` -- NFS -w lies (see above).
      _mtest=$(mktemp --tmpdir="${_mprobe}" .hip-python-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         PKG_SUDO_MOD=""
      else
         PKG_SUDO_MOD="sudo"
      fi
      unset _mprobe _mtest
   fi
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # ── Modulefile flavor: Lua (Lmod) vs Tcl (classic Environment Modules) ─
   # Lmod consumes <name>.lua; classic Tcl `environment-modules` consumes an
   # extensionless Tcl file. Detect Lmod via its env markers; default to Tcl
   # when Lmod is absent (this site runs Tcl Environment Modules 3.2.11).
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      _MODFILE="${MODULE_PATH}/${ROCM_VERSION}.lua"
      _MODFLAVOR="lua"
   else
      _MODFILE="${MODULE_PATH}/${ROCM_VERSION}"
      _MODFLAVOR="tcl"
   fi

   # Provenance: capture this leaf script's git state for the modulefile
   # whatis() line below. Uses LEAF_SCRIPT_PATH (absolute path captured
   # at the top of this script before any cd) so this works even after
   # the script has cd'd into a temp build dir. Self-contained: falls
   # back to "unknown" when run from a stripped-of-.git context (Docker
   # layer, release tarball, or git binary missing).
   LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
   LEAF_SCRIPT_COMMIT=unknown
   LEAF_SCRIPT_DIRTY=unknown
   _leaf_dir="$(dirname "${LEAF_SCRIPT_PATH}")"
   if [ -d "${_leaf_dir}" ] && command -v git >/dev/null 2>&1 \
      && git -C "${_leaf_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _commit="$(git -C "${_leaf_dir}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
      [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"
      unset _commit
      if [ -n "$(git -C "${_leaf_dir}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ]; then
         LEAF_SCRIPT_DIRTY=dirty
      else
         LEAF_SCRIPT_DIRTY=clean
      fi
   fi
   unset _leaf_dir

   # Provenance: which actual PyPI version we landed on. Useful for
   # therock builds where the spec ends up not matching ROCM_VERSION.
   _HIP_PYTHON_PROVENANCE="hip-python wheel ${HIP_PYTHON_PIP_SPEC:-(unknown)} (numba-hip extras: rocm-${NUMBA_HIP_EXTRA_SUFFIX:-?})"

   # A consumer satisfies the ROCm dependency with either the local TheRock
   # real module (rocm-new/<ver>) or its alias (rocm/<ver>): PrgEnv-amd-new
   # loads rocm-new directly, while a bare `module load rocm/<ver>` pulls it
   # in under the alias name. Tcl `prereq` with several names is satisfied if
   # ANY is loaded; Lmod's equivalent is prereq_any(). Non-rocm module names
   # are emitted unchanged.
   # AAC7 gate: the rocm-new/<ver> alias is only meaningful on a TheRock /
   # PrgEnv-amd-new site (AAC7), where rocm-new is a real modulefile. On a
   # stock site (e.g. AAC6) only rocm/<ver> exists, so widening the prereq
   # to rocm-new would reference a phantom module name -- gate it on whether
   # a rocm-new modulefile is actually discoverable on MODULEPATH. When it is
   # not, emit the original plain prereq("rocm/<ver>").
   rocm_new_available() {
      local _d _OIFS="${IFS}"; IFS=":"
      for _d in ${MODULEPATH:-}; do
         if [ -d "${_d}/rocm-new" ]; then IFS="${_OIFS}"; return 0; fi
      done
      IFS="${_OIFS}"; return 1
   }
   _RPV="${ROCM_MODULE_NAME##*/}"
   case "${ROCM_MODULE_NAME}" in
      rocm/*|rocm-new/*)
         ROCM_PREREQ_TCL="rocm-new/${_RPV} rocm/${_RPV}"
         ROCM_PREREQ_LUA="prereq_any(\"rocm-new/${_RPV}\", \"rocm/${_RPV}\")"
         ;;
      *)
         ROCM_PREREQ_TCL="${ROCM_MODULE_NAME}"
         ROCM_PREREQ_LUA="prereq(\"${ROCM_MODULE_NAME}\")"
         ;;
   esac
   unset _RPV

   # The - option suppresses leading tabs in the heredoc body.
   if [ "${_MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${_MODFILE}
	whatis("HIP-Python with ROCm support")
	whatis(" ${_HIP_PYTHON_PROVENANCE} ")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	${ROCM_PREREQ_LUA}
	prepend_path("PYTHONPATH","$HIP_PYTHON_PATH/hip-python")
	prepend_path("PYTHONPATH","$HIP_PYTHON_PATH/numba-hip")
	setenv("NUMBA_HIP_USE_DEVICE_LIB_CACHE","0")
EOF
   else
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${_MODFILE}
	#%Module1.0
	module-whatis "HIP-Python with ROCm support"
	module-whatis " ${_HIP_PYTHON_PROVENANCE} "
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_PREREQ_TCL}
	prepend-path PYTHONPATH $HIP_PYTHON_PATH/hip-python
	prepend-path PYTHONPATH $HIP_PYTHON_PATH/numba-hip
	setenv NUMBA_HIP_USE_DEVICE_LIB_CACHE 0
EOF
   fi
   unset _MODFILE _MODFLAVOR _HIP_PYTHON_PROVENANCE ROCM_PREREQ_TCL ROCM_PREREQ_LUA

fi
