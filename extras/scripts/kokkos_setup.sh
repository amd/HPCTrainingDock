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
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus/kokkos
# Master "do this script's work at all" gate. Default 1 so kokkos is built
# by default (parity with the other extras leaf scripts); set to 0 to
# short-circuit early with NOOP_RC.
BUILD_KOKKOS=1
ROCM_VERSION=6.2.0
# Kokkos AMD GPU arch flags. Defaults are OFF; turned ON per-arch below
# from semicolon-separated AMDGPU_GFXMODEL. This cluster's gfx942 nodes
# are MI300A (APU mode), hence the _APU variant; on MI300X dGPU clusters
# this should be Kokkos_ARCH_AMD_GFX942 (no _APU). The legacy gfx900 /
# Kokkos_ARCH_VEGA90A path was removed (not present on this cluster, and
# the variable was never plumbed into the cmake call anyway).
KOKKOS_ARCH_AMD_GFX90A="OFF"
KOKKOS_ARCH_AMD_GFX942_APU="OFF"
KOKKOS_VERSION="4.7.04"
KOKKOS_PATH=/opt/rocmplus-${ROCM_VERSION}/kokkos-v${KOKKOS_VERSION}
KOKKOS_PATH_INPUT=""
# --install-path: parent dir; the script appends kokkos-v${KOKKOS_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf prior install dir + ${KOKKOS_VERSION}.lua before building.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path-no-version [ KOKKOS_PATH ] default $KOKKOS_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), KOKKOS_PATH = ROCMPLUS_PATH/kokkos-v\${KOKKOS_VERSION}"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL_INPUT ] default is autodetected "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --kokkos-version [ KOKKOS_VERSION ] default $KOKKOS_VERSION (used as git branch/tag)"
   echo "  --build-kokkos [ BUILD_KOKKOS ], set to 0 to skip Kokkos, default is $BUILD_KOKKOS"
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
      "--build-kokkos")
          shift
          BUILD_KOKKOS=${1}
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
      "--install-path-no-version")
          shift
          KOKKOS_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--kokkos-version")
          shift
          KOKKOS_VERSION=${1}
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

if [ "${KOKKOS_PATH_INPUT}" != "" ]; then
   KOKKOS_PATH=${KOKKOS_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends kokkos-v${KOKKOS_VERSION} from its own default.
   # Lets main_setup.sh stay version-agnostic for kokkos.
   KOKKOS_PATH=${ROCMPLUS_PATH_INPUT}/kokkos-v${KOKKOS_VERSION}
else
   # override path in case ROCM_VERSION or KOKKOS_VERSION has been supplied as input
   KOKKOS_PATH=/opt/rocmplus-${ROCM_VERSION}/kokkos-v${KOKKOS_VERSION}
fi

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   # Stderr-silenced + `|| true`: rocminfo can fail when the SDK is built
   # against a newer glibc than the host (ROCm 7.2.3 binaries need
   # GLIBC_2.38; jammy has 2.35) and under pipefail would kill the script.
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# ── BUILD_KOKKOS=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_KOKKOS}" = "0" ]; then
   echo "[kokkos BUILD_KOKKOS=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── Sudo decisions (computed EARLY, before afar-skip/--replace) ───────
# The afar-skip + --replace blocks below rm with ${SUDO}, and the module
# write later uses its own sudo. The leaf default is SUDO=sudo, which on a
# cluster with no passwordless sudo and a user-owned install/module tree
# (this Cray) makes those blocks die on a password prompt. Probe the
# nearest existing ancestor of the install dir AND the module dir for
# user-writability and drop sudo when we own them. Mirrors the
# magma/petsc/rocshmem writability probes. EUID 0 never needs sudo.
_probe_writable() {  # $1 = path; echoes "" if writable else "sudo"
   local p="$1"
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then echo ""; return; fi
   while [ ! -e "${p}" ]; do p="$(dirname "${p}")"; done
   local t
   t=$(mktemp --tmpdir="${p}" .kokkos-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${t}" ] && [ -f "${t}" ]; then rm -f "${t}"; echo ""; else echo "sudo"; fi
}
if [ -n "${SUDO}" ]; then   # not already cleared (e.g. Singularity)
   SUDO="$(_probe_writable "${KOKKOS_PATH}")"
   if [ -z "${SUDO}" ]; then
      echo "kokkos: install tree ancestor of ${KOKKOS_PATH} is user-writable; not using sudo for install"
   else
      echo "kokkos: install tree ancestor of ${KOKKOS_PATH} not user-writable; using sudo for install"
   fi
fi
MOD_SUDO="$(_probe_writable "${MODULE_PATH}")"
# Modulefile flavor: Lmod consumes <ver>.lua; classic Tcl Environment
# Modules consumes an extensionless Tcl file. Detect Lmod via its env
# markers; default to Tcl (this Cray runs Tcl Environment Modules) so the
# module is actually loadable. Mirrors hdf5/netcdf/fftw/magma.
if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
   MODFLAVOR="lua"; MODEXT=".lua"
else
   MODFLAVOR="tcl"; MODEXT=""
fi

# ── afar SDK incompatibility detection ───────────────────────────────
# AMD's pre-release "AFAR" ROCm drops (rocm-afar-22.x, rocm-afar-7.0.5)
# are runtime-only / partial SDKs. Verified empirically on this cluster
# (audit_2026_05_06, job 8490, log_kokkos_05_06_2026.txt:96):
#
#   afar-22.1.0  $ find <ROCM_PATH> -name 'rocthrust*'
#                -> 0 matches  (no headers, no libs, no cmake config)
#   afar-22.2.0  $ same probe -> cmake config present, headers absent
#   rocm-7.2.1   $ same probe -> all present
#
# kokkos's cmake/Modules/FindTPLROCTHRUST.cmake:11 calls
# find_package(rocthrust) which fails with "Could not find a package
# configuration file provided by 'rocthrust'". Skipping here turns
# 8490-style FAILED kokkos(rc=1) into the correct SKIPPED(no-op)
# bucket on afar-22.1.0.
#
# Probe shape: gated on `${ROCM_PATH}` matching `*afar*` AND no
# rocthrust-config.cmake. Self-corrects if AMD ships rocthrust in a
# future afar drop (matches the rocm-bundled hipfort policy in
# extras/scripts/hipfort_setup.sh).
if [[ "${ROCM_PATH:-}" == *afar* ]]; then
   if [[ -z "${ROCM_PATH:-}" ]] && type module >/dev/null 2>&1; then
      module load "rocm/${ROCM_VERSION}" 2>/dev/null || true
   fi
   if [ ! -f "${ROCM_PATH}/lib/cmake/rocthrust/rocthrust-config.cmake" ]; then
      echo ""
      echo "[kokkos afar-skip] ROCM_PATH=${ROCM_PATH} is an AMD AFAR partial SDK"
      echo "                   missing : <ROCM_PATH>/lib/cmake/rocthrust/rocthrust-config.cmake"
      echo "                   kokkos requires find_package(rocthrust); cannot build on afar SDK."
      echo "                   Skipping (no source build, no cache restore)."
      echo ""
      if [ -d "${KOKKOS_PATH}" ]; then
         echo "[kokkos afar-skip] removing stale from-source install: ${KOKKOS_PATH}"
         ${SUDO} rm -rf "${KOKKOS_PATH}"
      fi
      if [ -f "${MODULE_PATH}/${KOKKOS_VERSION}.lua" ] || [ -f "${MODULE_PATH}/${KOKKOS_VERSION}" ]; then
         echo "[kokkos afar-skip] removing stale modulefile: ${MODULE_PATH}/${KOKKOS_VERSION}{.lua,} (both flavors)"
         ${SUDO} rm -f "${MODULE_PATH}/${KOKKOS_VERSION}.lua" "${MODULE_PATH}/${KOKKOS_VERSION}"
      fi
      # ── Drop a SKIPPED marker so the inventory tool can distinguish ──
      # "skipped on this SDK" from "absent / failed". See
      # bare_system/inventory_packages.py ('N' symbol -- Not possible to build on this SDK).
      _SKIP_MARKER_DIR="$(dirname "${KOKKOS_PATH}")"
      ${SUDO} mkdir -p "${_SKIP_MARKER_DIR}" 2>/dev/null || true
      if [ -d "${_SKIP_MARKER_DIR}" ]; then
         ${SUDO} tee "${_SKIP_MARKER_DIR}/kokkos.SKIPPED" >/dev/null 2>/dev/null <<MARKER_EOF || true
SKIPPED package: kokkos
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    kokkos_setup.sh (afar-skip guard)
Reason:          AFAR SDK is missing
                 <ROCM_PATH>/lib/cmake/rocthrust/rocthrust-config.cmake.
                 kokkos requires find_package(rocthrust); cannot build
                 on this SDK.
                 Self-corrects on the next sweep if AMD ships a more
                 complete AFAR drop.
MARKER_EOF
      fi
      unset _SKIP_MARKER_DIR
      exit ${NOOP_RC}
   fi
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[kokkos --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${KOKKOS_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${KOKKOS_VERSION}{.lua,} (both flavors)"
   ${SUDO} rm -rf "${KOKKOS_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${KOKKOS_VERSION}.lua" "${MODULE_PATH}/${KOKKOS_VERSION}"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${KOKKOS_PATH}" ]; then
   echo ""
   echo "[kokkos existence-check] ${KOKKOS_PATH} already installed; skipping."
   echo "                         pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

_kokkos_on_exit() {
   local rc=$?
   # attempted-but-failed marker (inventory 'F' glyph): persistent sibling
   # of the install dir that survives the rm -rf below; cleared on success.
   _fail_marker="$(dirname "${KOKKOS_PATH}")/kokkos.FAILED"
   if [ ${rc} -ne 0 ]; then
      ${SUDO} mkdir -p "$(dirname "${KOKKOS_PATH}")" 2>/dev/null || true
      ${SUDO} tee "${_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: kokkos
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    kokkos_setup.sh (EXIT-trap fail marker)
Reason:          build exited rc=${rc}; partial install wiped (see log_kokkos_*.txt).
MARKER_EOF
   else
      ${SUDO} rm -f "${_fail_marker}"
   fi
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[kokkos fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO} rm -rf "${KOKKOS_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/${KOKKOS_VERSION}.lua" "${MODULE_PATH}/${KOKKOS_VERSION}"
   elif [ ${rc} -ne 0 ]; then
      echo "[kokkos fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _kokkos_on_exit EXIT

echo ""
echo "==================================="
echo "Starting Kokkos Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_KOKKOS: $BUILD_KOKKOS"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "KOKKOS_PATH:  $KOKKOS_PATH"
echo "MODULE_PATH:  $MODULE_PATH"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "==================================="
echo ""

if [ "${BUILD_KOKKOS}" = "0" ]; then

   echo "Kokkos will not be built, according to the specified value of BUILD_KOKKOS"
   echo "BUILD_KOKKOS: $BUILD_KOKKOS"
   exit

else
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
   # Multi-pass over LOADEDMODULES. PrgEnv-amd-new loads the REAL TheRock
   # module rocm-new/<token> directly (never the rocm/ alias). On therock
   # drops that live token (e.g. rocm-new/7.13.0) differs from both the
   # ROCM_VERSION tag (therock-7.13.0) and the install-dir basename
   # (rocm-therock-7.13.0), so the actually-loaded rocm-new/* is the only
   # reliable source of the true module token. Prefer an exact ROCM_VERSION
   # match (real or alias), then any loaded rocm-new/*, then any rocm/* alias.
   # A Cray PrgEnv-amd-new shell can have several rocm modules loaded at once;
   # picking the wrong one would key the build + modulefile on the wrong SDK.
   ROCM_MODULE_NAME=""
   if [[ -n "${LOADEDMODULES:-}" ]]; then
      _OLD_IFS="${IFS}"; IFS=":"
      # Pass 1: exact requested-version match (real module or alias). For
      # numeric and afar drops the module token equals ROCM_VERSION.
      for _m in ${LOADEDMODULES}; do
         case "${_m}" in
            rocm-new/${ROCM_VERSION}|rocm/${ROCM_VERSION}) ROCM_MODULE_NAME="${_m}"; break ;;
         esac
      done
      # Pass 2: the actually-loaded TheRock real module (rocm-new/<token>),
      # which carries the correct numeric token on therock drops where the
      # ROCM_VERSION tag and the install-dir basename do not.
      if [[ -z "${ROCM_MODULE_NAME}" ]]; then
         for _m in ${LOADEDMODULES}; do
            case "${_m}" in
               rocm-new/*) ROCM_MODULE_NAME="${_m}"; break ;;
            esac
         done
      fi
      # Pass 3: a loaded rocm/ alias.
      if [[ -z "${ROCM_MODULE_NAME}" ]]; then
         for _m in ${LOADEDMODULES}; do
            case "${_m}" in
               rocm/*) ROCM_MODULE_NAME="${_m}"; break ;;
            esac
         done
      fi
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

   if [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/kokkos-v${KOKKOS_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Kokkos"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # kokkos-v${KOKKOS_VERSION}.tgz and contain a top-level
      # directory kokkos-v${KOKKOS_VERSION}/ so it lands directly
      # at ${KOKKOS_PATH} when extracted under /opt/rocmplus-X.
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/kokkos-v${KOKKOS_VERSION}.tgz
      chown -R root:root ${KOKKOS_PATH}
      ${SUDO} rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/kokkos-v${KOKKOS_VERSION}.tgz

   else
      echo ""
      echo "============================"
      echo " Building Kokkos"
      echo "============================"
      echo ""

      # (Install-path SUDO was probed early, before the afar-skip/--replace
      # blocks, via _probe_writable; it governs the install dir + make install.)
      ${SUDO} mkdir -p ${KOKKOS_PATH}

      # Parse semicolon-separated AMDGPU_GFXMODEL. main_setup.sh passes
      # multi-arch values like "gfx90a;gfx942" by design (see
      # bare_system/main_setup.sh:79); the prior strict-equality chain
      # matched none of them on this cluster and left every Kokkos_ARCH_*
      # empty, which made Kokkos 4.7's check_amd_apu() autodetection
      # fire and fail. Audited as the kokkos rc=1 cause in
      # slurm-7950-rocmplus-7.0.2.out (log_kokkos line 53). Multi-arch
      # builds are supported by Kokkos 4.5+.
      case ";${AMDGPU_GFXMODEL};" in
         *";gfx90a;"*) KOKKOS_ARCH_AMD_GFX90A="ON" ;;
      esac
      case ";${AMDGPU_GFXMODEL};" in
         *";gfx942;"*) KOKKOS_ARCH_AMD_GFX942_APU="ON" ;;
      esac

      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # Build everything (source clone + build tree) under /tmp on the
      # compute node's local disk so failed configures don't leave a
      # kokkos/ tree polluting the HPCTrainingDock checkout, and so the
      # multi-arch -> single-arch fallback below can wipe the build dir
      # cheaply. Mirrors the scorep S6.C / openmpi S7.B pattern. EXIT
      # trap covers cleanup even on `set -e` aborts.
      KOKKOS_BUILD_ROOT=$(mktemp -d -t kokkos-build.XXXXXX)
      # Plain rm (never sudo): KOKKOS_BUILD_ROOT is a user-owned /tmp dir,
      # and ${SUDO:-sudo} would re-default empty->sudo and prompt for a
      # password at end-of-run on a user-writable, no-passwordless-sudo Cray.
      trap '[ -n "${KOKKOS_BUILD_ROOT:-}" ] && rm -rf "${KOKKOS_BUILD_ROOT}"' EXIT
      cd "${KOKKOS_BUILD_ROOT}"

      git clone --branch ${KOKKOS_VERSION} https://github.com/kokkos/kokkos
      cd kokkos

      # Build dir under ${KOKKOS_BUILD_ROOT} (per-job /tmp). Owned by
      # the script user (admin) -- NOT sudo'd. See audit_2026_05_01.md
      # Issue 1: previously this was `${SUDO} mkdir build` and the
      # subsequent ${SUDO} make produced root-owned object files in
      # an admin-owned ${KOKKOS_BUILD_ROOT}, which the EXIT trap
      # (running as admin) couldn't clean up. The trap then exited
      # rc=1, the script propagated rc=1 via `set -eo pipefail`,
      # main_setup.sh marked kokkos FAILED, and KEEP_FAILED_INSTALLS=0
      # wiped the just-installed /nfsapps/.../kokkos -- a false-positive
      # failure that deleted a perfectly good install. Fixed by building
      # as admin under /tmp; only `make install` is sudo'd to write the
      # install path. Mirrors the fftw / hdf5 pattern.
      mkdir build
      cd build

      HIP_MALLOC_ASYNC_OFF=""
      if [ "$(printf '%s\n' "7.0.0" "$ROCM_VERSION" | sort -V | head -n1)" = "7.0.0" ]; then
         echo "ROCM_VERSION is >= 7.0.0"
         HIP_MALLOC_ASYNC_OFF="-DKokkos_ENABLE_IMPL_HIP_MALLOC_ASYNC=OFF"
      fi

      # Use amdclang++ instead of hipcc.  hipcc is a deprecated wrapper around
      # amdclang++ whose new offload driver produces fat binaries that CMake
      # cannot parse for CXX ABI info.  That failure left CMAKE_SIZEOF_VOID_P
      # and CMAKE_LIBRARY_ARCHITECTURE unset, which broke find_library for
      # system libs like libdl and caused a hardcoded /usr/include to leak
      # into KokkosTargets.cmake.  It also prevented FindOpenMP from setting
      # link libraries.  amdclang++ avoids all of these issues.
      #
      # cmake / make are run WITHOUT sudo -- the build tree is under
      # /tmp owned by admin (see Issue 1 in audit_2026_05_01.md).
      # SUDO_ENV is still computed for the install step below: sudo
      # strips LD_LIBRARY_PATH even with -E, so when we sudo for the
      # install (writing to /nfsapps or /shared/apps) we have to pass
      # PATH+LD_LIBRARY_PATH explicitly so the install-time link of
      # any plugins still finds the rocm runtime libs.
      SUDO_ENV=""
      if [ -n "${SUDO}" ]; then
         SUDO_ENV="${SUDO} -E env PATH=$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
      fi

      # Wrap cmake configure in a function so we can retry with reduced
      # flags if multi-arch fails. Only configure is retried -- a partial
      # build from a failed configure isn't reusable; the wipe-and-retry
      # path below ensures the second attempt sees a virgin tree.
      # BUILD_SHARED_LIBS=ON: Kokkos historically defaults to STATIC.  We
      # build SHARED so downstream consumers that resolve libraries via
      # dlopen / RPATH (python bindings, plugin systems, mixed
      # static/shared executables that need a single Kokkos symbol set)
      # can link against libkokkoscore.so.  Static-only installs were
      # detected on 2026-05-02 in job 8018: only .a archives landed in
      # /shared/apps/.../kokkos/lib (no .so).  Switching to shared has no
      # effect on correctness for purely static consumers (cmake's
      # find_package(Kokkos) honors whichever is present), and ROCm
      # itself ships shared libs, so RPATH wiring is consistent.
      kokkos_cmake_configure() {
         local gpu_targets="$1"
         cmake -DCMAKE_INSTALL_PREFIX=${KOKKOS_PATH} \
                       -DCMAKE_PREFIX_PATH=${ROCM_PATH} \
                       -DBUILD_SHARED_LIBS=ON \
                       -DKokkos_ENABLE_SERIAL=ON \
                       -DKokkos_ENABLE_HIP=ON \
                       ${HIP_MALLOC_ASYNC_OFF} \
                       -DKokkos_ENABLE_OPENMP=ON \
                       -DKokkos_ARCH_AMD_GFX90A=${KOKKOS_ARCH_AMD_GFX90A} \
                       -DKokkos_ARCH_AMD_GFX942_APU=${KOKKOS_ARCH_AMD_GFX942_APU} \
                       -DKokkos_ARCH_ZEN4=ON \
                       -DGPU_TARGETS="${gpu_targets}" \
                       -DCMAKE_CXX_COMPILER=${ROCM_PATH}/llvm/bin/amdclang++ ..
      }

      # Attempt 1: multi-arch. Some Kokkos / CMake combinations reject
      # combos that worked in prior versions; the fallback below retries
      # with only the first model from AMDGPU_GFXMODEL.
      #
      # The first attempt's stdout+stderr is filtered to demote upstream
      # "CMake Error" / "Configuring incomplete, errors occurred!"
      # text to "CMake Warning [...]" / "Configuring incomplete
      # (...)". Rationale: a failed multi-arch probe is an *expected*
      # outcome with newer Kokkos+CMake combos and is fully recovered
      # by the single-arch retry below -- it is not a build failure of
      # kokkos. The unfiltered text was tripping log-audit greps for
      # "Error|FAILED" (jobs 7975/7980), producing false-positive
      # alerts. The demotion preserves the full diagnostic content
      # and only changes the leading keyword so audit tools can
      # distinguish "kokkos multi-arch probe" from a real build error.
      # PIPESTATUS[0] holds the cmake exit code regardless of sed
      # success; sed exits 0 unless its own input is malformed.
      set +e
      kokkos_cmake_configure "${AMDGPU_GFXMODEL}" 2>&1 \
         | sed -u \
              -e 's|^CMake Error|CMake Warning [kokkos multi-arch probe; will fall back to single-arch if needed]|' \
              -e 's|^-- Configuring incomplete, errors occurred!|-- Configuring incomplete (kokkos multi-arch probe; falling back to single-arch is expected)|'
      cmake_rc=${PIPESTATUS[0]}
      set -e

      if [ ${cmake_rc} -ne 0 ]; then
         FIRST_ARCH="${AMDGPU_GFXMODEL%%;*}"
         echo ""
         echo "============================"
         echo " Multi-arch cmake WARNING (rc=${cmake_rc}, expected)"
         echo " Falling back to single-arch: ${FIRST_ARCH}"
         echo "============================"
         echo ""
         KOKKOS_ARCH_AMD_GFX90A="OFF"
         KOKKOS_ARCH_AMD_GFX942_APU="OFF"
         case "${FIRST_ARCH}" in
            gfx90a) KOKKOS_ARCH_AMD_GFX90A="ON" ;;
            gfx942) KOKKOS_ARCH_AMD_GFX942_APU="ON" ;;
            *)
               echo "ERROR: Unrecognized first arch '${FIRST_ARCH}' in" >&2
               echo "       AMDGPU_GFXMODEL='${AMDGPU_GFXMODEL}'." >&2
               exit 1
               ;;
         esac
         # Wipe the failed-configure build dir for a clean retry. cd-out,
         # rm-rf, mkdir, cd-back so cmake sees a virgin tree (CMakeCache
         # in particular taints retries if left in place). No sudo:
         # build dir is admin-owned (see "Build dir under" comment above).
         cd ..
         rm -rf build
         mkdir build
         cd build
         kokkos_cmake_configure "${FIRST_ARCH}"
      fi

      make -j
      ${SUDO_ENV} make install

      # Cleanup of ${KOKKOS_BUILD_ROOT} (source clone + build tree) is
      # handled by the EXIT trap registered above. cd to / so subsequent
      # module-file generation isn't running from a dir about to be
      # removed.
      cd /

      module unload ${ROCM_MODULE_NAME}

   fi

   # Create a module file for kokkos. Uses MOD_SUDO + MODFLAVOR/MODEXT
   # computed early (writability-probe sudo; Lua for Lmod, Tcl otherwise).
   ${MOD_SUDO} mkdir -p ${MODULE_PATH}

   # Detect the real libdir. Kokkos honors CMAKE_INSTALL_LIBDIR, which is
   # 'lib64' on RHEL-family (this Cray) and 'lib' on Debian/Ubuntu. Both
   # the shared libs (libkokkoscore.so ...) and the CMake package
   # (KokkosConfig.cmake) land there. Hardcoding /lib produced a broken
   # module on RHEL9: LD_LIBRARY_PATH and Kokkos_DIR pointed at a
   # non-existent dir, so runtime dlopen and downstream find_package(Kokkos)
   # both failed. Probe for the actual dir (covers the cached-tar branch too).
   KOKKOS_LIBDIR="lib"
   if ls "${KOKKOS_PATH}"/lib64/libkokkoscore.* >/dev/null 2>&1; then
      KOKKOS_LIBDIR="lib64"
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

   # A consumer satisfies the ROCm dependency with either the local TheRock real
   # module (rocm-new/<ver>) or its alias (rocm/<ver>). On a Cray/TheRock site
   # PrgEnv-amd-new loads BOTH names (rocm-new/<ver> directly, plus the
   # rocm/<ver> alias whose body just re-loads rocm-new -- a no-op), mirroring
   # how its internal `module load amd` leaves both amd/<ver> and amd-new/<ver>
   # loaded; a bare `module load rocm/<ver>` likewise yields both. So list BOTH
   # names in the prereq. This matters on the compute nodes' Cray PE Environment
   # Modules 3.2.11, where `prereq a b` requires ALL listed modules (AND; 3.2.11
   # has no prereq-any) -- PrgEnv-amd-new is responsible for loading both names
   # so that AND is satisfied. On Environment Modules 4.x/5.x `prereq` is ANY-of,
   # so listing both is fine there too, and rocm-new/<ver> is simply never loaded
   # on a stock site (e.g. AAC6), where rocm/<ver> alone satisfies it. Lmod uses
   # prereq_any().
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

   # The - option suppresses tabs.
   # LD_LIBRARY_PATH is now required because we build BUILD_SHARED_LIBS=ON
   # (libkokkoscore.so etc).  Harmless on a static-only install (LD_LIBRARY_PATH
   # is not consulted for .a archives). Written in the detected flavor (Lua
   # for Lmod, Tcl otherwise) so it actually loads on this Tcl-modules Cray.
   if [ "${MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${MOD_SUDO} tee ${MODULE_PATH}/${KOKKOS_VERSION}${MODEXT}
	whatis("Kokkos version ${KOKKOS_VERSION} - Performance Portability Language")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	${ROCM_PREREQ_LUA}
	prepend_path("PATH","${KOKKOS_PATH}")
	prepend_path("LD_LIBRARY_PATH","${KOKKOS_PATH}/${KOKKOS_LIBDIR}")
	setenv("Kokkos_ROOT","${KOKKOS_PATH}")
	setenv("Kokkos_DIR","${KOKKOS_PATH}/${KOKKOS_LIBDIR}/cmake/Kokkos")
	setenv("HSA_XNACK","1")
	EOF
   else
      cat <<-EOF | ${MOD_SUDO} tee ${MODULE_PATH}/${KOKKOS_VERSION}${MODEXT}
	#%Module1.0
	module-whatis "Kokkos version ${KOKKOS_VERSION} - Performance Portability Language"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_PREREQ_TCL}
	prepend-path PATH "${KOKKOS_PATH}"
	prepend-path LD_LIBRARY_PATH "${KOKKOS_PATH}/${KOKKOS_LIBDIR}"
	setenv Kokkos_ROOT "${KOKKOS_PATH}"
	setenv Kokkos_DIR "${KOKKOS_PATH}/${KOKKOS_LIBDIR}/cmake/Kokkos"
	setenv HSA_XNACK "1"
	EOF
   fi

fi
