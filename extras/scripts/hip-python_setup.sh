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
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
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

if [ "${REPLACE}" = "1" ]; then
   echo "[hip-python --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HIP_PYTHON_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${ROCM_VERSION}.lua"
   ${SUDO} rm -rf "${HIP_PYTHON_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${ROCM_VERSION}.lua"
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
   [ -n "${HIP_PYTHON_BUILD_DIR:-}" ] && ${SUDO:-sudo} rm -rf "${HIP_PYTHON_BUILD_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hip-python fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${HIP_PYTHON_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${ROCM_VERSION}.lua"
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

   # Derive ROCM_MODULE_NAME from the actual ROCM_PATH basename so RC
   # trees (rocm-therock-*, rocm-afar-*) match their loaded module
   # name instead of the SDK numeric. Falls back to the rocm/<version>
   # form for direct standalone invocation where ROCM_PATH is unset.
   if [[ -n "${ROCM_PATH:-}" ]]; then
      _rp_bn="${ROCM_PATH##*/}"
      ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
      unset _rp_bn
   else
      ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
   fi

   if [ -f ${CACHE_FILES}/hip-python.tgz ]; then
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

      if [ -d "$HIP_PYTHON_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${HIP_PYTHON_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p $HIP_PYTHON_PATH
      if [[ "${USER}" != "root" ]]; then
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
      python3 -m pip install --target=$HIP_PYTHON_PATH/numba-hip "numba-hip[rocm-${NUMBA_HIP_EXTRA_SUFFIX}] @ git+https://github.com/ROCm/numba-hip.git" --force-reinstall --no-cache
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

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w $HIP_PYTHON_PATH
      fi
   fi

   # Create a module file for hip-python
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

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

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
        whatis("HIP-Python with ROCm support")
        whatis(" ${_HIP_PYTHON_PROVENANCE} ")
        whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

        prereq("${ROCM_MODULE_NAME}")
        prepend_path("PYTHONPATH","$HIP_PYTHON_PATH/hip-python")
        prepend_path("PYTHONPATH","$HIP_PYTHON_PATH/numba-hip")
	setenv("NUMBA_HIP_USE_DEVICE_LIB_CACHE","0")
EOF
   unset _HIP_PYTHON_PROVENANCE

fi
