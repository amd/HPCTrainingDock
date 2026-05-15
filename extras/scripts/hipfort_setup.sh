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
MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/hipfort_from_source
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
BUILD_HIPFORT=0
ROCM_VERSION=6.2.0
HIPFORT_PATH="/opt/rocmplus-${ROCM_VERSION}/hipfort"
HIPFORT_PATH_INPUT=""
FC_COMPILER=gfortran
HIPFORT_VERSION=""    # empty -> use rocm-${ROCM_VERSION} branch (legacy default)
# --replace 1: rm -rf prior install dir + ${ROCM_VERSION}.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is $AMDGPU_GFXMODEL"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --hipfort-version [ HIPFORT_VERSION ] git branch/tag to clone (default: rocm-\${ROCM_VERSION})"
   echo "  --build-hipfort [ BUILD_HIPFORT ], set to 1 to build hipfort, default is $BUILD_HIPFORT"
   echo "  --fc-compiler [FC_COMPILER: gfortran|amdflang-new|cray-ftn], default is $FC_COMPILER"
   echo "  --install-path [ HIPFORT_PATH ], default is $HIPFORT_PATH"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: this usage information"
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
      "--build-hipfort")
          shift
          BUILD_HIPFORT=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
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
          HIPFORT_PATH_INPUT=${1}
          reset-last
          ;;
      "--fc-compiler")
          shift
          FC_COMPILER=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--hipfort-version")
          shift
          HIPFORT_VERSION=${1}
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

if [ "${HIPFORT_PATH_INPUT}" != "" ]; then
   HIPFORT_PATH=${HIPFORT_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   HIPFORT_PATH=/opt/rocmplus-${ROCM_VERSION}/hipfort
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is ${ROCM_VERSION}.lua to match the
# `tee ${MODULE_PATH}/${ROCM_VERSION}.lua` write below.
# ── BUILD_HIPFORT=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_HIPFORT}" = "0" ]; then
   echo "[hipfort BUILD_HIPFORT=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[hipfort --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HIPFORT_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${ROCM_VERSION}.lua"
   ${SUDO} rm -rf "${HIPFORT_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${ROCM_VERSION}.lua"
fi

# ── rocm-bundled hipfort detection ───────────────────────────────────
# Starting with ROCm 6.3, the rocm SDK ships hipfort built-in. Verified
# on this cluster (2026-05-06) two SDK layouts coexist:
#
#   STANDARD layout (rocm-6.3.x..7.2.x, afar-22.x):
#     ${ROCM_PATH}/include/hipfort/
#     ${ROCM_PATH}/lib/libhipfort-{amdgcn,nvptx}.a
#     ${ROCM_PATH}/lib/cmake/hipfort/hipfort-config.cmake (+ targets)
#
#   THEROCK layout (rocm-therock-23.1.0 / 23.2.0):
#     ${ROCM_PATH}/lib/llvm/include/hipfort/
#     ${ROCM_PATH}/lib/llvm/lib/libhipfort-{amdgcn,nvptx}.a
#     ${ROCM_PATH}/lib/llvm/lib/cmake/hipfort/...
#   This is what the canonical user-facing
#   /shared/apps/modules/.../rocm-therock-23.1.0/hipfort/23.1.0.lua
#   passthrough modulefile points at (`local base = "<ROCM_PATH>/lib/llvm"`).
#
# When the SDK already has hipfort, building our own from source is
#   (a) wasteful (~1 min CPU + ~50 MB disk per rocm version),
#   (b) ABI-risky (rocm's bundled headers/libs are the canonical pair
#       and our from-source build may pull a newer/older hipfort tag),
#   (c) confusing for users (two libhipfort-amdgcn.a on disk).
#
# Policy (per user request 2026-05-06): when bundled, do NOT emit a
# from-source modulefile. Users get hipfort transparently via the
# `rocm/<v>` module's includes/libs / via the canonical
# rocm-<v>/hipfort/<v>.lua passthrough modulefile created by
# rocm_setup.sh. A `hipfort_from_source/<v>` modulefile would falsely
# advertise a separate from-source install that doesn't exist.
#
# This block:
#   1. cleans up any stale from-source install + modulefile left by a
#      prior sweep that ran before this guard existed,
#   2. exits NOOP_RC=43 immediately so main_setup.sh marks hipfort as
#      DESELECTED (rocm-bundled) rather than FAILED.
#
# Override with --hipfort-version <branch> to force a from-source
# build anyway (e.g. to test a newer hipfort against an older rocm).
NOOP_RC=43
if [[ -z "${HIPFORT_VERSION}" ]]; then
   # Need ROCM_PATH for the probe. main_setup.sh's run_and_log path
   # already loads `rocm/${ROCM_VERSION}` before invoking us, so
   # ROCM_PATH is normally set. Fall back to an in-place rocm module
   # load when run standalone.
   if [[ -z "${ROCM_PATH:-}" ]] && type module >/dev/null 2>&1; then
      module load "rocm/${ROCM_VERSION}" 2>/dev/null || true
   fi
   # Detect either the STANDARD layout (under ${ROCM_PATH}) or the
   # THEROCK layout (under ${ROCM_PATH}/lib/llvm). The first match
   # wins and its base path is reported in the [rocm-bundled] message.
   _hipfort_bundled_base=""
   if [[ -n "${ROCM_PATH:-}" ]]; then
      for _cand in "${ROCM_PATH}" "${ROCM_PATH}/lib/llvm"; do
         if [ -d "${_cand}/include/hipfort" ] \
            && [ -f "${_cand}/lib/libhipfort-amdgcn.a" ]; then
            _hipfort_bundled_base="${_cand}"
            break
         fi
      done
      unset _cand
   fi
   if [[ -n "${_hipfort_bundled_base}" ]]; then
      echo ""
      echo "[hipfort rocm-bundled] hipfort is shipped with this rocm SDK"
      echo "                       base    : ${_hipfort_bundled_base}"
      echo "                       include : ${_hipfort_bundled_base}/include/hipfort"
      echo "                       libs    : ${_hipfort_bundled_base}/lib/libhipfort-{amdgcn,nvptx}.a"
      echo "                       cmake   : ${_hipfort_bundled_base}/lib/cmake/hipfort"
      echo "                       Skipping from-source build AND from-source modulefile."
      echo "                       Users get hipfort via the rocm/<v> module already."
      echo "                       (override with --hipfort-version <branch> to force)"
      echo ""
      # Idempotent cleanup of any stale from-source install + module
      # left behind by a prior sweep that ran before this guard existed.
      if [ -d "${HIPFORT_PATH}" ]; then
         echo "[hipfort rocm-bundled] removing stale from-source install: ${HIPFORT_PATH}"
         ${SUDO} rm -rf "${HIPFORT_PATH}"
      fi
      if [ -f "${MODULE_PATH}/${ROCM_VERSION}.lua" ]; then
         echo "[hipfort rocm-bundled] removing stale modulefile: ${MODULE_PATH}/${ROCM_VERSION}.lua"
         ${SUDO} rm -f "${MODULE_PATH}/${ROCM_VERSION}.lua"
      fi
      # ── Drop a BUNDLED marker so the inventory tool can distinguish ──
      # "bundled in the SDK (use ROCm's copy)" from "absent / failed".
      # The marker lands as a sibling of the (intentionally absent)
      # install dir, i.e. directly under the rocmplus-${PREFIX}-${NUMERIC}/
      # root, named hipfort.BUNDLED. Best-effort: never aborts the script.
      # See bare_system/inventory_packages.py ('B' symbol).
      _BUNDLED_MARKER_DIR="$(dirname "${HIPFORT_PATH}")"
      ${SUDO} mkdir -p "${_BUNDLED_MARKER_DIR}" 2>/dev/null || true
      if [ -d "${_BUNDLED_MARKER_DIR}" ]; then
         ${SUDO} tee "${_BUNDLED_MARKER_DIR}/hipfort.BUNDLED" >/dev/null 2>/dev/null <<MARKER_EOF || true
BUNDLED package: hipfort
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    hipfort_setup.sh (rocm-bundled guard)
Reason:          hipfort is shipped with this ROCm SDK at
                 ${_hipfort_bundled_base:-${ROCM_PATH}}.
                 No separate from-source build or modulefile is needed.
                 Users get hipfort via the rocm/<v> module's includes/libs
                 (and the canonical rocm-<v>/hipfort/<v>.lua passthrough
                 modulefile created by rocm_setup.sh).
                 To force a from-source build, pass --hipfort-version <branch>.
MARKER_EOF
      fi
      unset _BUNDLED_MARKER_DIR
      unset _hipfort_bundled_base
      exit ${NOOP_RC}
   fi
   unset _hipfort_bundled_base
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
if [ -d "${HIPFORT_PATH}" ]; then
   echo ""
   echo "[hipfort existence-check] ${HIPFORT_PATH} already installed; skipping."
   echo "                          pass --replace 1 to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

_hipfort_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hipfort fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${HIPFORT_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${ROCM_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[hipfort fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _hipfort_on_exit EXIT

echo ""
echo "==================================="
echo "Starting Hipfort Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HIPFORT: $BUILD_HIPFORT"
echo "MODULE_PATH: $MODULE_PATH"
echo "HIPFORT_PATH: $HIPFORT_PATH"
echo "FC_COMPILER: $FC_COMPILER"
echo "==================================="
echo ""

if [ "${BUILD_HIPFORT}" = "0" ]; then

   echo "Hipfort will not be built, according to the specified value of BUILD_HIPFORT"
   echo "BUILD_HIPFORT: $BUILD_HIPFORT"
   exit

else
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

   if [ -f ${CACHE_FILES}/hipfort.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Hipfort"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/hipfort.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/hipfort
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/hipfort.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building Hipfort"
      echo "============================"
      echo ""

      # don't use sudo if user has write access to install path
      if [ -w ${HIPFORT_PATH} ]; then
         SUDO=""
      fi

      if  [ "${BUILD_HIPFORT}" = "1" ]; then

         REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" )
         # Conditional dep: amdflang-new is needed only when building
         # against that compiler (added below if FC_COMPILER selects it).
         if [ "${FC_COMPILER:-}" = "amdflang-new" ]; then
            REQUIRED_MODULES+=( "amdflang-new" )
         fi
         preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

         # ── therock SDK guard ─────────────────────────────────────────
         # The hipfort github repo publishes per-rocm-release branches
         # (rocm-7.0.0, rocm-7.0.1, ..., rocm-7.2.2). therock is a
         # release-candidate SDK whose ROCM_VERSION numeric (e.g. 7.12.0
         # for therock-23.1.0, 7.13.0 for therock-23.2.0) DOES NOT have
         # a matching upstream branch. Without this guard, the
         # `git clone --branch rocm-7.12.0 https://github.com/ROCm/hipfort.git`
         # below aborts immediately with `Remote branch rocm-7.12.0 not
         # found in upstream origin` and the whole run is marked FAILED
         # (slurm 8372, 2026-05-05 on therock-23.1.0). An operator who
         # knows a branch/tag that works (e.g. develop, master, or an
         # older rocm-7.x.y) can override via --hipfort-version <branch>.
         # Otherwise we exit MISSING_PREREQ_RC=42 so the package shows
         # up cleanly as SKIPPED (missing prereq) in main_setup.sh's
         # per-package summary instead of FAILED.
         if [[ -n "${ROCM_PATH:-}" && "${ROCM_PATH}" == *therock* && -z "${HIPFORT_VERSION}" ]]; then
            echo ""
            echo "[hipfort therock-guard] ROCM_PATH=${ROCM_PATH}"
            echo "                         no upstream hipfort branch matches therock SDK numerics"
            echo "                         (e.g. rocm-7.12.0 / rocm-7.13.0 don't exist on github)."
            echo "                         Skipping with rc=${MISSING_PREREQ_RC} (MISSING-PREREQ)."
            echo "                         To force, pass --hipfort-version <branch-or-tag>"
            echo "                         (e.g. --hipfort-version develop -- verify upstream first"
            echo "                         at https://github.com/ROCm/hipfort/branches)."
            echo ""
            exit ${MISSING_PREREQ_RC}
         fi

         if [ -d "$HIPFORT_PATH" ]; then
            # don't use sudo if user has write access to install path
            if [ -w ${HIPFORT_PATH} ]; then
               SUDO=""
            else
               echo "WARNING: using an install path that requires sudo"
            fi
         else
            # if install path does not exist yet, the check on write access will fail
            echo "WARNING: using sudo, make sure you have sudo privileges"
         fi

         ${SUDO} mkdir -p ${HIPFORT_PATH}

         # Per-job throwaway build dir under /tmp (or $TMPDIR if
         # Slurm set one). Replaces a clone into ${PWD}/hipfort
         # which is the shared NFS HPCTrainingDock checkout —
         # concurrent rocm-version jobs would race on that path.
         # Only `make install` writes hit NFS via -DHIPFORT_INSTALL_DIR.
         HIPFORT_BUILD_DIR=$(mktemp -d -t hipfort-build.XXXXXX)
         trap '[ -n "${HIPFORT_BUILD_DIR:-}" ] && ${SUDO:-sudo} rm -rf "${HIPFORT_BUILD_DIR}"' EXIT
         cd "${HIPFORT_BUILD_DIR}"

         HIPFORT_BRANCH="${HIPFORT_VERSION:-rocm-${ROCM_VERSION}}"
         echo "Cloning hipfort branch/tag: ${HIPFORT_BRANCH}"
         git clone --branch "${HIPFORT_BRANCH}" https://github.com/ROCm/hipfort.git
         cd hipfort

         mkdir build && cd build

         if [ "${FC_COMPILER}" = "gfortran" ]; then
            cmake -DHIPFORT_INSTALL_DIR=${HIPFORT_PATH} ..
         elif [ "${FC_COMPILER}" = "amdflang-new" ]; then
            # amdflang-new was already loaded by preflight above.
            cmake -DHIPFORT_INSTALL_DIR=${HIPFORT_PATH} -DHIPFORT_COMPILER=$FC -DHIPFORT_COMPILER_FLAGS="-ffree-form -cpp" ..
         elif [ "${FC_COMPILER}" = "cray-ftn" ]; then
            cmake -DHIPFORT_INSTALL_DIR=$HIPFORT_PATH -DHIPFORT_BUILD_TYPE=RELEASE -DHIPFORT_COMPILER=$(which ftn) -DHIPFORT_COMPILER_FLAGS="-ffree -eT" -DHIPFORT_AR=$(which ar) -DHIPFORT_RANLIB=$(which ranlib) ..
         else
            echo " ERROR: requested compiler is not currently among the available options "
            echo " Please choose one among: gfortran (default), amdflang-new, cray-ftn "
            exit 1
         fi

         # Parallel build then install. `make install` alone re-runs the
         # serial build dependency graph; splitting it lets cmake fan
         # out across cores. (S6 audit follow-up: hipfort was building
         # one Fortran source at a time, ~4 minutes wall, when nproc
         # cores were idle.)
         #
         # Build runs WITHOUT sudo: the build tree is under /tmp owned
         # by admin. The previous `${SUDO} make -j` produced root-owned
         # files in admin-owned ${HIPFORT_BUILD_DIR}, the EXIT trap
         # (admin) couldn't clean them, the trap exited rc=1, the
         # script propagated rc=1, main_setup.sh marked hipfort FAILED,
         # and KEEP_FAILED_INSTALLS=0 then wiped /nfsapps/.../hipfort/
         # despite the install having succeeded -- a false-positive
         # failure in every job in the 2026-04-30 chain (Issue 1 in
         # audit_2026_05_01.md). Mirrors the fftw / hdf5 pattern:
         # build as user, sudo only the install.
         MAKE_JOBS=$(nproc)
         make -j ${MAKE_JOBS}
         ${SUDO} make install

         # HIPFORT_BUILD_DIR (under /tmp, contains the hipfort
         # source clone) is removed by the EXIT trap above.

      fi

   fi

   # Create a module file for hipfort
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

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis(" hipfort module ")
	whatis(" this hipfort build has been compiled with: $FC_COMPILER. ")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	prereq("${ROCM_MODULE_NAME}")
	local fc_compiler = "${FC_COMPILER}"
	if fc_compiler == "amdflang-new" then
		load("amdflang-new")
	end
	append_path("LD_LIBRARY_PATH","${HIPFORT_PATH}/lib")
	setenv("LIBS","-L${HIPFORT_PATH}/lib -lhipfort-amdgcn.a")
	setenv("HIPFORT_PATH","${HIPFORT_PATH}")
	setenv("HIPFORT_LIB","${HIPFORT_PATH}/lib")
	setenv("HIPFORT_INC","${HIPFORT_PATH}/include/hipfort")
	prepend_path("PATH","${HIPFORT_PATH}/bin")
EOF

fi

