#!/bin/bash

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
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_MAGMA=0
ROCM_VERSION=6.2.0
# MAGMA_VERSION holds the BARE numeric version (no leading 'v'); the
# script prepends 'v' where the upstream needs it (git tag) and uses
# the bare form everywhere else (install dir 'magma-v${VERSION}',
# modulefile '${VERSION}.lua') so we match the fftw / hdf5 / petsc
# convention. Old default was 'v2.10.0' which produced 'magma-vv2.10.0'
# and 'v2.10.0.lua' (job 8065 audit). User input is normalized below
# (strip optional leading 'v') so '--magma-version v2.10.0' still works.
MAGMA_VERSION=2.10.0
OPENBLAS_VERSION=0.3.33

# --install-path and --module-path are now both BASE directories. The
# script appends /magma-v${MAGMA_VERSION} and /openblas-v${OPENBLAS_VERSION}
# to the install base, and /magma + /openblas (unversioned dirs holding
# <version>.lua files) to the module base. Multiple magma releases
# coexist as siblings; same for openblas.
INSTALL_PATH_BASE=/opt/rocmplus-${ROCM_VERSION}
MODULE_PATH_BASE=/etc/lmod/modules/ROCmPlus
MAGMA_PATH_INPUT=""
MODULE_PATH_INPUT=""
OPENBLAS_PATH=""
# magma is multi-component (magma + optionally openblas built by the
# same script). Like openmpi_setup.sh's --replace-xpmem/--replace-ucx
# split we expose one knob per top-level install dir:
#   --replace-magma     removes <base>/magma + ${MAGMA_VERSION}.lua
#   --replace-openblas  removes <base>/openblas + ${OPENBLAS_VERSION}.lua
#                       (only meaningful if openblas would actually be
#                        rebuilt -- has no effect when the system
#                        libopenblas-dev path is taken)
# --replace is a convenience alias that flips both on and is what
# main_setup.sh threads through from --replace-existing.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
REPLACE_MAGMA=0
REPLACE_OPENBLAS=0
KEEP_FAILED_INSTALLS=0
# Tracks whether we actually built openblas in this run, so the EXIT
# trap doesn't blow away a system openblas-dev install we never touched.
_OPENBLAS_BUILT=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is autodetected"
   echo "  --build-magma [ BUILD_MAGMA ], set to 1 to build Magma, default is $BUILD_MAGMA"
   echo "  --magma-version [ MAGMA_VERSION ] default $MAGMA_VERSION"
   echo "  --openblas-version [ OPENBLAS_VERSION ] default $OPENBLAS_VERSION"
   echo "  --openblas-path [ OPENBLAS_PATH ] path to existing OpenBLAS installation, autodetected if not specified"
   echo "  --accept-system-openblas [ 0|1 ] accept system OpenBLAS at any version (skip OPENBLAS_VERSION check); default ${OPENBLAS_ACCEPT_SYSTEM:-0}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --module-path [ MODULE_PATH_BASE ] BASE dir; magma module goes in <base>/magma, openblas module (when built) in <base>/openblas; default $MODULE_PATH_BASE"
   echo "  --install-path [ INSTALL_PATH_BASE ] BASE dir; magma installs to <base>/magma-v\${MAGMA_VERSION}, openblas (when built) to <base>/openblas-v\${OPENBLAS_VERSION}; default $INSTALL_PATH_BASE"
   echo "  --replace [ 0|1 ] convenience: same as --replace-magma 1 --replace-openblas 1, default $REPLACE"
   echo "  --replace-magma [ 0|1 ] remove prior magma install + modulefile before building, default $REPLACE_MAGMA"
   echo "  --replace-openblas [ 0|1 ] remove prior built-from-source openblas install + modulefile before building, default $REPLACE_OPENBLAS"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial installs on failure, default $KEEP_FAILED_INSTALLS"
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
      "--build-magma")
          shift
          BUILD_MAGMA=${1}
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
      "--magma-version")
          shift
          # Strip optional leading 'v' so callers that pass either
          # 'v2.10.0' (old main_setup.sh default) or '2.10.0' both
          # land in the same canonical form. See MAGMA_VERSION
          # comment near the top of this file.
          MAGMA_VERSION=${1#v}
          reset-last
          ;;
      "--openblas-version")
          shift
          OPENBLAS_VERSION=${1}
          reset-last
          ;;
      "--openblas-path")
          shift
          OPENBLAS_PATH=${1}
          reset-last
          ;;
      "--accept-system-openblas")
          # Accepts an explicit value (0|1); also tolerates the bareword
          # form `--accept-system-openblas` (no value) as a synonym for 1.
          # Whatever the form, the result lands in the env var
          # OPENBLAS_ACCEPT_SYSTEM that the detection block below reads.
          if [[ $# -ge 2 && "${2}" =~ ^[01]$ ]]; then
             shift
             OPENBLAS_ACCEPT_SYSTEM=${1}
          else
             OPENBLAS_ACCEPT_SYSTEM=1
          fi
          export OPENBLAS_ACCEPT_SYSTEM
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          MAGMA_PATH_INPUT=${1}
          reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
          reset-last
          ;;
      "--replace-magma")
          shift
          REPLACE_MAGMA=${1}
          reset-last
          ;;
      "--replace-openblas")
          shift
          REPLACE_OPENBLAS=${1}
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

# Resolve install / module BASE dirs.
#
# Both --install-path and --module-path are now base directories; we
# append /magma-v${MAGMA_VERSION} and /openblas-v${OPENBLAS_VERSION}
# to the install base, and /magma + /openblas to the module base.
# Default INSTALL_PATH_BASE off ROCM_VERSION (which may have come in
# via --rocm-version). Back-compat: if the operator passed a legacy
# leaf path that already ends in /magma or /magma-v..., strip it so
# the version-suffixed dir doesn't get appended twice.
if [ -n "${MAGMA_PATH_INPUT}" ]; then
   INSTALL_PATH_BASE="${MAGMA_PATH_INPUT%/}"
   INSTALL_PATH_BASE="${INSTALL_PATH_BASE%/magma}"
   INSTALL_PATH_BASE="${INSTALL_PATH_BASE%/magma-v${MAGMA_VERSION}}"
else
   INSTALL_PATH_BASE=/opt/rocmplus-${ROCM_VERSION}
fi
if [ -n "${MODULE_PATH_INPUT}" ]; then
   MODULE_PATH_BASE="${MODULE_PATH_INPUT%/}"
   MODULE_PATH_BASE="${MODULE_PATH_BASE%/magma}"
fi

MAGMA_PATH="${INSTALL_PATH_BASE}/magma-v${MAGMA_VERSION}"
MAGMA_MODULE_DIR="${MODULE_PATH_BASE}/magma"
# OpenBLAS sibling paths (used by --replace-openblas and the EXIT trap;
# only ACTUALLY removed if openblas is in scope, see _OPENBLAS_BUILT below).
_MAGMA_OPENBLAS_INSTALL_DIR="${INSTALL_PATH_BASE}/openblas-v${OPENBLAS_VERSION}"
_MAGMA_OPENBLAS_MODULE_DIR="${MODULE_PATH_BASE}/openblas"

# ── BUILD_MAGMA=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_MAGMA}" = "0" ]; then
   echo "[magma BUILD_MAGMA=0] operator opt-out; skipping (no magma build, no openblas build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── --replace: remove prior installs + modulefiles BEFORE building ───
if [ "${REPLACE}" = "1" ]; then
   REPLACE_MAGMA=1
   REPLACE_OPENBLAS=1
fi
if [ "${REPLACE_MAGMA}" = "1" ]; then
   echo "[magma --replace-magma 1] removing prior magma install + modulefile if present"
   echo "  install dir: ${MAGMA_PATH}"
   echo "  modulefile:  ${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua"
   ${SUDO} rm -rf "${MAGMA_PATH}"
   ${SUDO} rm -f  "${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua"
fi
if [ "${REPLACE_OPENBLAS}" = "1" ]; then
   # Best-effort: removes any openblas install that previously lived in
   # the magma sibling slot. If the system libopenblas-dev path is taken
   # below, we won't rebuild it -- the directory just stays gone, which
   # is fine (no module pointing at it).
   echo "[magma --replace-openblas 1] removing prior built-from-source openblas install + modulefile if present"
   echo "  install dir: ${_MAGMA_OPENBLAS_INSTALL_DIR}"
   echo "  modulefile:  ${_MAGMA_OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}.lua"
   ${SUDO} rm -rf "${_MAGMA_OPENBLAS_INSTALL_DIR}"
   ${SUDO} rm -f  "${_MAGMA_OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}.lua"
fi

# ── Existence guard (see hypre_setup.sh) ─────────────────────────────
# Multi-component: only the magma half is checked here. OpenBLAS may
# come from EITHER the system package (libopenblas-dev) OR the sibling
# install at ${_MAGMA_OPENBLAS_INSTALL_DIR}; the script decides which
# later, after evaluating the system OpenBLAS version. Mirroring the
# decision here would duplicate that logic, so we just match what
# main_setup.sh's `[[ ! -d magma-v${MAGMA_VERSION} ]]` guard did.
# Implication: if magma is on disk but the sibling openblas was wiped
# (and no system openblas), the magma modulefile's `prereq openblas/...`
# will fail at module-load time -- pass --replace-magma 1 (or --replace 1)
# to force a clean reinstall in that situation.
NOOP_RC=43
if [ -d "${MAGMA_PATH}" ]; then
   echo ""
   echo "[magma existence-check] ${MAGMA_PATH} already installed; skipping."
   echo "                        pass --replace 1 (or --replace-magma 1) to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of magma + (optionally) openblas ─────────
# Always cleans the magma install on failure. OpenBLAS is only cleaned
# if this run actually rebuilt it (_OPENBLAS_BUILT=1, set by the
# build-openblas branch below) so we never blow away a system or
# pre-existing openblas we just *consumed*. Replaces main_setup.sh
# PKG_CLEAN_*[magma]/[openblas].
_magma_on_exit() {
   local rc=$?
   # Build-dir cleanup (MAGMA_BUILD_ROOT is set later under the build
   # branches, may still be empty if this script no-op'd).
   [ -n "${MAGMA_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${MAGMA_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[magma fail-cleanup] rc=${rc}: removing partial magma install + modulefile"
      ${SUDO:-sudo} rm -rf "${MAGMA_PATH}"
      ${SUDO:-sudo} rm -f  "${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua"
      if [ "${_OPENBLAS_BUILT}" = "1" ]; then
         echo "[magma fail-cleanup] also removing partial openblas install + modulefile (this run built it)"
         ${SUDO:-sudo} rm -rf "${_MAGMA_OPENBLAS_INSTALL_DIR}"
         ${SUDO:-sudo} rm -f  "${_MAGMA_OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}.lua"
      fi
   elif [ ${rc} -ne 0 ]; then
      echo "[magma fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _magma_on_exit EXIT

echo ""
echo "==================================="
echo "Starting Magma Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_MAGMA: $BUILD_MAGMA"
echo "MAGMA_VERSION: $MAGMA_VERSION"
echo "OPENBLAS_VERSION: $OPENBLAS_VERSION"
echo "OPENBLAS_ACCEPT_SYSTEM: ${OPENBLAS_ACCEPT_SYSTEM:-0}"
echo "INSTALL_PATH_BASE: $INSTALL_PATH_BASE"
echo "MODULE_PATH_BASE: $MODULE_PATH_BASE"
echo "MAGMA_PATH: $MAGMA_PATH"
echo "MAGMA_MODULE_DIR: $MAGMA_MODULE_DIR"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "==================================="
echo ""

if [ "${BUILD_MAGMA}" = "0" ]; then

   echo "Magma will not be built, according to the specified value of BUILD_MAGMA"
   echo "BUILD_MAGMA: $BUILD_MAGMA"
   exit

else

   # don't use sudo if user has write access to install path
   if [ -d "$MAGMA_PATH" ]; then
      if [ -w ${MAGMA_PATH} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" "amdclang" )
   preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

   ## OpenBLAS resolution.
   ##
   ## Build OpenBLAS from source as the default path. Only TWO override
   ## cases skip the build:
   ##
   ##   (A) --openblas-path PATH or --accept-system-openblas:
   ##       operator-explicit opt-in to use an existing copy.
   ##
   ##   (B) The system libopenblas-dev version exactly matches the
   ##       requested OPENBLAS_VERSION (deterministic match -- otherwise
   ##       our pinned version would silently degrade to whatever the
   ##       distro shipped, which is the bug audited in
   ##       logs_05_02_2026/rocm-7.2.1_8016/log_magma_05_02_2026.txt:7).
   ##
   ## When we build OpenBLAS we install it at INSTALL_PATH_BASE/openblas
   ## (sibling of magma) and create a standalone openblas modulefile.
   ## The magma modulefile then `load("openblas")` so the OPENBLAS_*
   ## env vars come from a single source of truth. When we reuse a
   ## system or operator-supplied OpenBLAS we inline the env vars in
   ## the magma modulefile because no openblas module exists.
   OPENBLAS_BUILD=1

   # _probe_system_openblas_version: print the system libopenblas-dev
   # patch-level version (e.g. "0.3.20"), or empty on failure.
   # Prefers dpkg-query on Debian/Ubuntu (deterministic); falls back to
   # parsing the SOVERSION of the resolved /usr/lib*/libopenblas.so for
   # RHEL-family hosts.
   _probe_system_openblas_version() {
      local v
      v=$(dpkg-query -W -f='${Version}' libopenblas-dev 2>/dev/null \
            | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
      if [ -n "${v}" ]; then echo "${v}"; return; fi
      local libdir
      for libdir in /usr/lib64 /usr/lib /usr/lib/x86_64-linux-gnu /usr/local/lib /usr/local/lib64; do
         if [ -f "${libdir}/libopenblas.so" ]; then
            basename "$(readlink -f "${libdir}/libopenblas.so")" \
               | sed -nE 's/.*r?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'
            return
         fi
      done
   }

   # _find_system_openblas_root: print the install prefix that owns the
   # system libopenblas.so (e.g. "/usr"), or empty if none is found.
   # Defined as the parent of the libdir that contains libopenblas.so.
   _find_system_openblas_root() {
      local libdir
      for libdir in /usr/lib64 /usr/lib /usr/lib/x86_64-linux-gnu /usr/local/lib /usr/local/lib64; do
         if [ -f "${libdir}/libopenblas.so" ]; then
            case "${libdir}" in
               /usr/lib/x86_64-linux-gnu) echo "/usr"; return ;;
               /usr/lib|/usr/lib64)        echo "/usr"; return ;;
               /usr/local/lib|/usr/local/lib64) echo "/usr/local"; return ;;
            esac
         fi
      done
   }

   # ── Override A: operator-explicit opt-in ──
   if [ -n "${OPENBLAS_PATH}" ]; then
      if ls ${OPENBLAS_PATH}/lib/libopenblas.* 1>/dev/null 2>&1; then
         echo "Using OpenBLAS at ${OPENBLAS_PATH} (--openblas-path; no version check)"
         OPENBLAS_BUILD=0
      else
         echo "WARNING: --openblas-path=${OPENBLAS_PATH} contains no libopenblas; falling through to build"
         OPENBLAS_PATH=""
      fi
   elif [ "${OPENBLAS_ACCEPT_SYSTEM:-0}" = "1" ]; then
      sysroot=$(_find_system_openblas_root)
      if [ -n "${sysroot}" ]; then
         OPENBLAS_PATH="${sysroot}"
         OPENBLAS_BUILD=0
         sysver=$(_probe_system_openblas_version)
         echo "Using system OpenBLAS ${sysver:-<unknown>} at ${OPENBLAS_PATH} (--accept-system-openblas; no version check)"
      else
         echo "WARNING: --accept-system-openblas set but no system OpenBLAS found; will build from source"
      fi
   fi

   # ── Override B: system libopenblas-dev exactly matches request ──
   if [ "${OPENBLAS_BUILD}" = "1" ]; then
      sysver=$(_probe_system_openblas_version)
      if [ -n "${sysver}" ] && [ "${sysver}" = "${OPENBLAS_VERSION}" ]; then
         OPENBLAS_PATH=$(_find_system_openblas_root)
         OPENBLAS_BUILD=0
         echo "System libopenblas-dev ${sysver} matches OPENBLAS_VERSION; using ${OPENBLAS_PATH}"
      else
         echo "System libopenblas-dev=${sysver:-<absent>} != requested ${OPENBLAS_VERSION}; will build from source"
      fi
   fi

   if [ "${OPENBLAS_BUILD}" = "1" ]; then
      echo ""
      echo "============================"
      echo " Building OpenBLAS ${OPENBLAS_VERSION}"
      echo "============================"
      echo ""

      # Versioned openblas install dir (sibling of the versioned magma
      # install). Tracked by _MAGMA_OPENBLAS_INSTALL_DIR computed up
      # near the --replace block; recompute literally here to keep the
      # local read self-explanatory.
      OPENBLAS_PATH="${INSTALL_PATH_BASE}/openblas-v${OPENBLAS_VERSION}"
      # Mark openblas as in-scope for fail-cleanup -- the _magma_on_exit
      # trap will rm -rf this path + the matching modulefile if the
      # script exits non-zero, but ONLY because we're about to write to
      # it. A system-libopenblas-dev path leaves _OPENBLAS_BUILT=0 and
      # the trap leaves the system install untouched.
      _OPENBLAS_BUILT=1

      ${SUDO} mkdir -p ${OPENBLAS_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${OPENBLAS_PATH}
      fi

      # Per-job throwaway build dir; replaces a fixed `cd /tmp;
      # rm -rf openblas_build` pattern that would race with -- and
      # clobber -- any other concurrent magma/openblas build on the
      # same node. NOTE: build-dir cleanup is consolidated into the
      # _magma_on_exit trap installed earlier (so the same EXIT
      # handler also fail-cleans the magma + openblas installs).
      MAGMA_BUILD_ROOT=$(mktemp -d -t magma-build.XXXXXX)
      cd "${MAGMA_BUILD_ROOT}"
      mkdir openblas_build && cd openblas_build
      curl -LO https://github.com/OpenMathLib/OpenBLAS/archive/refs/tags/v${OPENBLAS_VERSION}.tar.gz
      tar xf v${OPENBLAS_VERSION}.tar.gz
      cd OpenBLAS-${OPENBLAS_VERSION}/
      make -j MAKE_NB_JOBS=0 ARCH=x86_64 TARGET=ZEN USE_LOCKING=1 USE_OPENMP=1 USE_THREAD=1 RANLIB=ranlib libs netlib shared
      make install PREFIX=${OPENBLAS_PATH} MAKE_NB_JOBS=0 ARCH=x86_64 TARGET=ZEN USE_LOCKING=1 USE_OPENMP=1 USE_THREAD=1 RANLIB=ranlib

      # trap handles cleanup of ${MAGMA_BUILD_ROOT}/openblas_build

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${OPENBLAS_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${OPENBLAS_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${OPENBLAS_PATH}
      fi

      # Create a standalone openblas modulefile. Lives at the symmetric
      # MODULE_PATH_BASE/openblas dir so users can `module load openblas`
      # directly, and so the magma module (below) can `load("openblas")`
      # to get OPENBLAS_PATH / LD_LIBRARY_PATH from a single source of
      # truth instead of duplicating the env block. We set OPENBLAS_PATH
      # plus the three common aliases (HOME, ROOT, DIR) so downstream
      # CMake consumers (PyTorch's BLAS=OpenBLAS path, future ginkgo,
      # spack-installed packages) all find it under whatever convention
      # they use.
      OPENBLAS_MODULE_DIR="${MODULE_PATH_BASE}/openblas"
      ${SUDO} mkdir -p "${OPENBLAS_MODULE_DIR}"
      cat <<-EOF | ${SUDO} tee "${OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}.lua"
	whatis("OpenBLAS ${OPENBLAS_VERSION} (built from source as a magma dependency)")
	setenv("OPENBLAS_PATH","${OPENBLAS_PATH}")
	setenv("OPENBLAS_HOME","${OPENBLAS_PATH}")
	setenv("OPENBLAS_ROOT","${OPENBLAS_PATH}")
	setenv("OPENBLAS_DIR","${OPENBLAS_PATH}")
	prepend_path("LD_LIBRARY_PATH","${OPENBLAS_PATH}/lib")
	prepend_path("LIBRARY_PATH","${OPENBLAS_PATH}/lib")
	prepend_path("CPATH","${OPENBLAS_PATH}/include")
	prepend_path("PKG_CONFIG_PATH","${OPENBLAS_PATH}/lib/pkgconfig")
	EOF
   fi

   if [ -n "${OPENBLAS_PATH}" ]; then
      export LD_LIBRARY_PATH=${OPENBLAS_PATH}/lib:${LD_LIBRARY_PATH}
   fi

   echo ""
   echo "============================"
   echo " Building Magma ${MAGMA_VERSION}"
   echo "============================"
   echo ""

   ${SUDO} mkdir -p ${MAGMA_PATH}
   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod -R a+w ${MAGMA_PATH}
   fi

   CMAKE_PREFIX_PATHS="${ROCM_PATH}"
   if [ -n "${OPENBLAS_PATH}" ]; then
      CMAKE_PREFIX_PATHS="${OPENBLAS_PATH};${ROCM_PATH}"
   fi

   # MAGMA_BUILD_ROOT was created in the openblas-build branch above
   # when OPENBLAS_BUILD=1; create one now if the openblas branch
   # was skipped (cached or already-installed openblas). The
   # _magma_on_exit trap (installed near the top of the script) handles
   # cleanup either way -- it inspects ${MAGMA_BUILD_ROOT:-} at exit.
   if [ -z "${MAGMA_BUILD_ROOT:-}" ]; then
      MAGMA_BUILD_ROOT=$(mktemp -d -t magma-build.XXXXXX)
   fi
   cd "${MAGMA_BUILD_ROOT}"
   mkdir magma_build && cd magma_build
   # Magma upstream tags are 'v<MAJ>.<MIN>.<MIC>' (e.g. v2.10.0); we
   # store MAGMA_VERSION as the bare numeric form, so prepend 'v' here.
   git clone https://github.com/icl-utk-edu/magma.git -b v${MAGMA_VERSION}
   cd magma
   echo -e "BACKEND = hip\nFORT = true\nGPU_TARGET = ${AMDGPU_GFXMODEL}" > make.inc
   make -f make.gen.hipMAGMA -j
   make generate
   mkdir build && cd build

   cmake \
      -DCMAKE_INSTALL_PREFIX=${MAGMA_PATH} \
      -DCMAKE_BUILD_TYPE=Release \
      -DMAGMA_ENABLE_HIP=ON \
      -DGPU_TARGET=${AMDGPU_GFXMODEL} \
      -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_CXX_COMPILER=${ROCM_PATH}/bin/hipcc \
      -DCMAKE_Fortran_COMPILER=gfortran \
      -DBLA_VENDOR=OpenBLAS \
      -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATHS}" \
      ..

   make -j
   make install

   # trap handles cleanup of ${MAGMA_BUILD_ROOT}

   export LD_LIBRARY_PATH=${MAGMA_PATH}/lib:${LD_LIBRARY_PATH}

   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find ${MAGMA_PATH} -type f -execdir chown root:root "{}" +
      ${SUDO} find ${MAGMA_PATH} -type d -execdir chown root:root "{}" +
   fi

   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod go-w ${MAGMA_PATH}
   fi

   # Create a module file for magma
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MAGMA_MODULE_DIR}

   # The - option suppresses tabs
   #
   # MAGMA_PATH is the project-internal convention used by the
   # HPCTrainingDock setup scripts. MAGMA_HOME, MAGMA_ROOT, and
   # MAGMA_DIR are aliases for downstream consumers that use
   # different naming conventions:
   #   - MAGMA_HOME : honored by PyTorch's cmake/Modules/FindMAGMA.cmake
   #                  HINTS, and by many other CMake consumers.
   #   - MAGMA_ROOT : the modern CMake convention (find_package looks
   #                  up <Pkg>_ROOT).
   #   - MAGMA_DIR  : Spack's convention, also commonly hand-rolled.
   # Setting all four here makes the magma module the single source
   # of truth for "where is magma installed", so downstream packages
   # (pytorch_setup.sh, future ginkgo, future user code) never have
   # to hardcode the path or re-export under a different name.
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua
	whatis("Magma version ${MAGMA_VERSION} for AMD hardware")

	prereq("rocm/${ROCM_VERSION}")
	load("amdclang")
	setenv("MAGMA_PATH","${MAGMA_PATH}")
	setenv("MAGMA_HOME","${MAGMA_PATH}")
	setenv("MAGMA_ROOT","${MAGMA_PATH}")
	setenv("MAGMA_DIR","${MAGMA_PATH}")
	prepend_path("LD_LIBRARY_PATH","${MAGMA_PATH}/lib")
EOF

   # OpenBLAS env: when we built it (OPENBLAS_BUILD=1) a standalone
   # openblas modulefile already exists, so just `load("openblas")`
   # for a single source of truth. When we reused a system or
   # operator-supplied OpenBLAS, no module exists, so inline the
   # OPENBLAS_PATH/LD_LIBRARY_PATH exports directly in the magma
   # module to keep downstream consumers (pytorch's BLAS=OpenBLAS
   # path, etc.) working.
   if [ "${OPENBLAS_BUILD}" = "1" ]; then
      echo 'load("openblas")' | ${PKG_SUDO_MOD} tee -a ${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua
   elif [ -n "${OPENBLAS_PATH}" ]; then
      cat <<-EOF | ${PKG_SUDO_MOD} tee -a ${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua
	setenv("OPENBLAS_PATH","${OPENBLAS_PATH}")
	prepend_path("LD_LIBRARY_PATH","${OPENBLAS_PATH}/lib")
EOF
   fi

fi
