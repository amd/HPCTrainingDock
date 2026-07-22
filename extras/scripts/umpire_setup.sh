#!/bin/bash

# Absolute path to this script, captured before any cd (used for the
# modulefile git-provenance line).
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# Load each listed module in order; on the first miss print the Lmod
# diagnostic and return MISSING_PREREQ_RC=42 (main_setup.sh treats that
# as SKIPPED rather than FAILED).
MISSING_PREREQ_RC=42
if ! type module >/dev/null 2>&1; then
   [ -r /etc/profile.d/lmod.sh ]         && . /etc/profile.d/lmod.sh
   [ -r /usr/share/lmod/lmod/init/bash ] && . /usr/share/lmod/lmod/init/bash
fi
preflight_modules() {
   [ "$#" -eq 0 ] && return 0
   if ! type module >/dev/null 2>&1; then
      echo "ERROR: Lmod 'module' command not available; needed:$(printf ' %s' "$@")" >&2
      return ${MISSING_PREREQ_RC}
   fi
   local m err
   err=$(mktemp -t preflight.XXXXXX.err 2>/dev/null || echo /tmp/preflight.$$.err)
   for m in "$@"; do
      if ! module load "${m}" 2>"${err}"; then
         echo "ERROR: required module '${m}' could not be loaded." >&2
         [ -s "${err}" ] && sed 's/^/  module> /' "${err}" >&2
         rm -f "${err}"; return ${MISSING_PREREQ_RC}
      fi
   done
   rm -f "${err}"
}

# Umpire is built with HIP, so it is ROCm-version-dependent and installs
# under the per-ROCm rocmplus tree (unlike miniconda3). UMPIRE_VERSION is
# the bare numeric version; the upstream git tag is v${UMPIRE_VERSION}.
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus/umpire
BUILD_UMPIRE=1
ROCM_VERSION=6.2.0
UMPIRE_VERSION="6.0.0"
UMPIRE_PATH=/opt/rocmplus-${ROCM_VERSION}/umpire-v${UMPIRE_VERSION}
UMPIRE_PATH_INPUT=""
ROCMPLUS_PATH_INPUT=""   # parent dir; script appends umpire-v${UMPIRE_VERSION}
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"
[ -f /.singularity.d/Singularity ] && SUDO=""

usage()
{
   echo "Usage:"
   echo "  WARNING: --install-path-no-version and --module-path dirs must already exist (write-permission check)"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path-no-version [ UMPIRE_PATH ] default $UMPIRE_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; UMPIRE_PATH = ROCMPLUS_PATH/umpire-v\${UMPIRE_VERSION}"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL_INPUT ] default autodetected"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --umpire-version [ UMPIRE_VERSION ] default $UMPIRE_VERSION (git tag v\${UMPIRE_VERSION})"
   echo "  --build-umpire [ 0|1 ] set 0 to skip, default $BUILD_UMPIRE"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: print this usage information"
   exit 1
}

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--build-umpire")             shift; BUILD_UMPIRE=${1}; reset-last ;;
      "--help")                     usage ;;
      "--module-path")              shift; MODULE_PATH=${1}; reset-last ;;
      "--install-path-no-version")  shift; UMPIRE_PATH_INPUT=${1}; reset-last ;;
      "--install-path")             shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--amdgpu-gfxmodel")          shift; AMDGPU_GFXMODEL_INPUT=${1}; reset-last ;;
      "--rocm-version")             shift; ROCM_VERSION=${1}; reset-last ;;
      "--umpire-version")           shift; UMPIRE_VERSION=${1#v}; reset-last ;;   # strip optional leading 'v'
      "--replace")                  shift; REPLACE=${1}; reset-last ;;
      "--keep-failed-installs")     shift; KEEP_FAILED_INSTALLS=${1}; reset-last ;;
      "--*")                        send-error "Unsupported argument at position $((${n} + 1)) :: ${1}" ;;
      *)                            last ${1} ;;
   esac
   n=$((${n} + 1)); shift
done

if [ "${UMPIRE_PATH_INPUT}" != "" ]; then
   UMPIRE_PATH=${UMPIRE_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   UMPIRE_PATH=${ROCMPLUS_PATH_INPUT}/umpire-v${UMPIRE_VERSION}
else
   UMPIRE_PATH=/opt/rocmplus-${ROCM_VERSION}/umpire-v${UMPIRE_VERSION}
fi

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi

NOOP_RC=43
if [ "${BUILD_UMPIRE}" = "0" ]; then
   echo "[umpire BUILD_UMPIRE=0] operator opt-out; skipping."
   exit ${NOOP_RC}
fi

# Drop sudo when the install / module tree is user-writable (no
# passwordless sudo on this Cray). EUID 0 never needs it.
_probe_writable() {  # $1 = path; echoes "" if writable else "sudo"
   local p="$1"
   [ "${EUID:-$(id -u)}" -eq 0 ] && { echo ""; return; }
   while [ ! -e "${p}" ]; do p="$(dirname "${p}")"; done
   local t; t=$(mktemp --tmpdir="${p}" .umpire-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${t}" ] && [ -f "${t}" ]; then rm -f "${t}"; echo ""; else echo "sudo"; fi
}
[ -n "${SUDO}" ] && SUDO="$(_probe_writable "${UMPIRE_PATH}")"
MOD_SUDO="$(_probe_writable "${MODULE_PATH}")"

# Modulefile flavor: Lua for Lmod, extensionless Tcl otherwise.
if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
   MODFLAVOR="lua"; MODEXT=".lua"
else
   MODFLAVOR="tcl"; MODEXT=""
fi

# AFAR (partial) SDKs ship no hip cmake config; Umpire needs
# find_package(hip), so skip cleanly there.
if [[ "${ROCM_PATH:-}" == *afar* ]] && [ ! -f "${ROCM_PATH}/lib/cmake/hip/hip-config.cmake" ]; then
   echo "[umpire afar-skip] ${ROCM_PATH} lacks hip-config.cmake; cannot build. Skipping."
   ${SUDO} rm -rf "${UMPIRE_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${UMPIRE_VERSION}.lua" "${MODULE_PATH}/${UMPIRE_VERSION}"
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[umpire --replace 1] removing prior install + modulefile"
   ${SUDO} rm -rf "${UMPIRE_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${UMPIRE_VERSION}.lua" "${MODULE_PATH}/${UMPIRE_VERSION}"
fi

if [ -d "${UMPIRE_PATH}" ]; then
   echo "[umpire existence-check] ${UMPIRE_PATH} already installed; skipping (--replace 1 to rebuild)."
   exit ${NOOP_RC}
fi

# On failure: wipe the partial install (unless --keep-failed-installs 1)
# and clean the temp build dir. Always removes the temp build dir.
_umpire_on_exit() {
   local rc=$?
   [ -n "${UMPIRE_BUILD_ROOT:-}" ] && rm -rf "${UMPIRE_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[umpire fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO} rm -rf "${UMPIRE_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/${UMPIRE_VERSION}.lua" "${MODULE_PATH}/${UMPIRE_VERSION}"
   fi
   return ${rc}
}
trap _umpire_on_exit EXIT

echo ""
echo "==================================="
echo "Starting Umpire Install with"
echo "ROCM_VERSION:    $ROCM_VERSION"
echo "UMPIRE_VERSION:  $UMPIRE_VERSION"
echo "UMPIRE_PATH:     $UMPIRE_PATH"
echo "MODULE_PATH:     $MODULE_PATH"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "==================================="
echo ""

# Resolve the rocm modulefile token to (re-)load: prefer a loaded
# rocm/${ROCM_VERSION}, then any loaded rocm/*, then ROCM_PATH basename,
# then rocm/${ROCM_VERSION}.
ROCM_MODULE_NAME=""
if [[ -n "${LOADEDMODULES:-}" ]]; then
   _OLD_IFS="${IFS}"; IFS=":"
   for _m in ${LOADEDMODULES}; do
      [ "${_m}" = "rocm/${ROCM_VERSION}" ] && { ROCM_MODULE_NAME="${_m}"; break; }
   done
   if [[ -z "${ROCM_MODULE_NAME}" ]]; then
      for _m in ${LOADEDMODULES}; do
         case "${_m}" in rocm/*) ROCM_MODULE_NAME="${_m}"; break ;; esac
      done
   fi
   IFS="${_OLD_IFS}"; unset _OLD_IFS _m
fi
if [[ -z "${ROCM_MODULE_NAME}" ]]; then
   if [[ -n "${ROCM_PATH:-}" ]]; then
      _rp_bn="${ROCM_PATH##*/}"; ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"; unset _rp_bn
   else
      ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
   fi
fi

echo "============================"
echo " Building Umpire"
echo "============================"

# Compiler selection. On a Cray PE use the cc/CC/ftn wrappers (the PrgEnv
# already provides HIP). Off Cray, load the rocm SDK plus a Fortran-capable
# AMD compiler module (amdflang-new, else amdclang), which export CXX/CC/FC.
if [[ -n "$CRAYPE_VERSION" || -f /etc/cray-release ]]; then
   [ -z "$CXX" ] && export CXX=$(which CC)
   [ -z "$CC" ]  && export CC=$(which cc)
   [ -z "$FC" ]  && export FC=$(which ftn)
else
   preflight_modules "${ROCM_MODULE_NAME}" || exit $?
   module load amdflang-new >/dev/null 2>&1 || module load amdclang
fi

# Build under /tmp (per-job) so failed configures don't pollute the
# checkout and concurrent sweeps don't race; EXIT trap cleans it up.
UMPIRE_BUILD_ROOT=$(mktemp -d -t umpire-build.XXXXXX)
cd "${UMPIRE_BUILD_ROOT}"

# Recursive shallow clone with retry (BLT/camp/fmt submodules required;
# the LLNL mirror occasionally drops the first connect).
for attempt in 1 2 3; do
   if git clone --recursive --depth 1 --shallow-submodules \
        --branch v${UMPIRE_VERSION} \
        https://github.com/LLNL/Umpire.git Umpire_source; then
      break
   fi
   echo "git clone attempt $attempt failed, retrying in 5s..."
   rm -rf Umpire_source; sleep 5
done
cd Umpire_source

# ROCm-build patches: camp's hip.hpp uses the old hipMemoryType field
# name (renamed to 'type'); the Fortran CMakeLists use PGI '-Mfree'
# (amdflang/gfortran spell it '-ffree-form'). Guarded so upstream layout
# changes don't abort under set -e.
sed -i 's/memoryType/type/g' src/tpl/umpire/camp/include/camp/resource/hip.hpp 2>/dev/null || true
for f in examples/cookbook/CMakeLists.txt \
         examples/tutorial/fortran/CMakeLists.txt \
         src/umpire/interface/c_fortran/CMakeLists.txt \
         tests/integration/interface/fortran/CMakeLists.txt; do
   sed -i 's/Mfree/ffree-form/g' "$f" 2>/dev/null || true
done

mkdir -p build && cd build

${SUDO} mkdir -p ${UMPIRE_PATH}
[[ "${USER}" != "root" ]] && ${SUDO} chmod -R a+w ${UMPIRE_PATH}

cmake -DCMAKE_INSTALL_PREFIX=${UMPIRE_PATH} \
      -DROCM_ROOT_DIR=${ROCM_PATH} \
      -DHIP_ROOT_DIR=${ROCM_PATH}/hip \
      -DHIP_PATH=${ROCM_PATH}/llvm/bin \
      -DENABLE_HIP=On \
      -DENABLE_OPENMP=Off \
      -DENABLE_CUDA=Off \
      -DENABLE_MPI=Off \
      -DCMAKE_CXX_COMPILER=$CXX \
      -DCMAKE_C_COMPILER=$CC \
      -DCMAKE_Fortran_COMPILER=$FC \
      -DCMAKE_HIP_ARCHITECTURES=$AMDGPU_GFXMODEL \
      -DAMDGPU_TARGETS=$AMDGPU_GFXMODEL \
      -DGPU_TARGETS=$AMDGPU_GFXMODEL \
      -DBLT_CXX_STD=c++20 \
      -DUMPIRE_ENABLE_IPC_SHARED_MEMORY=On \
      -DENABLE_FORTRAN=On \
      -DENABLE_TESTS=Off \
      ../

make -j 16
${SUDO} make install
cd /   # EXIT trap removes ${UMPIRE_BUILD_ROOT}

if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find ${UMPIRE_PATH} -type f -execdir chown root:root "{}" +
   ${SUDO} find ${UMPIRE_PATH} -type d -execdir chown root:root "{}" +
   ${SUDO} chmod go-w ${UMPIRE_PATH}
fi

if [[ -z "$CRAYPE_VERSION" && ! -f /etc/cray-release ]]; then
   module unload ${ROCM_MODULE_NAME} || true
fi

# --- Modulefile ---
${MOD_SUDO} mkdir -p ${MODULE_PATH}

# Real libdir (lib64 on RHEL-family, lib on Debian/Ubuntu).
UMPIRE_LIBDIR="lib"
ls "${UMPIRE_PATH}"/lib64/libumpire.* >/dev/null 2>&1 && UMPIRE_LIBDIR="lib64"

# Provenance: this leaf script's git commit for the modulefile whatis().
LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
LEAF_SCRIPT_COMMIT=unknown; LEAF_SCRIPT_DIRTY=unknown
_leaf_dir="$(dirname "${LEAF_SCRIPT_PATH}")"
if [ -d "${_leaf_dir}" ] && command -v git >/dev/null 2>&1 \
   && git -C "${_leaf_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
   _commit="$(git -C "${_leaf_dir}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
   [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"; unset _commit
   [ -n "$(git -C "${_leaf_dir}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ] \
      && LEAF_SCRIPT_DIRTY=dirty || LEAF_SCRIPT_DIRTY=clean
fi
unset _leaf_dir

# ROCm prereq: accept rocm-new/<ver> or rocm/<ver> (PrgEnv-amd-new loads
# the -new flavor).
_RPV="${ROCM_MODULE_NAME##*/}"
case "${ROCM_MODULE_NAME}" in
   rocm/*|rocm-new/*)
      ROCM_PREREQ_TCL="rocm-new/${_RPV} rocm/${_RPV}"
      ROCM_PREREQ_LUA="prereq_any(\"rocm-new/${_RPV}\", \"rocm/${_RPV}\")" ;;
   *)
      ROCM_PREREQ_TCL="${ROCM_MODULE_NAME}"
      ROCM_PREREQ_LUA="prereq(\"${ROCM_MODULE_NAME}\")" ;;
esac
unset _RPV

# The - option suppresses leading tabs.
if [ "${MODFLAVOR}" = "lua" ]; then
   cat <<-EOF | ${MOD_SUDO} tee ${MODULE_PATH}/${UMPIRE_VERSION}${MODEXT}
	whatis("Umpire version ${UMPIRE_VERSION} - Memory management library for HPC")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	${ROCM_PREREQ_LUA}
	setenv("UMPIRE_PATH","${UMPIRE_PATH}")
	prepend_path("PATH","${UMPIRE_PATH}/bin")
	prepend_path("LD_LIBRARY_PATH","${UMPIRE_PATH}/${UMPIRE_LIBDIR}")
	prepend_path("CPATH","${UMPIRE_PATH}/include")
	setenv("umpire_ROOT","${UMPIRE_PATH}")
	setenv("umpire_DIR","${UMPIRE_PATH}/${UMPIRE_LIBDIR}/cmake/umpire")
	EOF
else
   cat <<-EOF | ${MOD_SUDO} tee ${MODULE_PATH}/${UMPIRE_VERSION}${MODEXT}
	#%Module1.0
	module-whatis "Umpire version ${UMPIRE_VERSION} - Memory management library for HPC"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_PREREQ_TCL}
	setenv UMPIRE_PATH "${UMPIRE_PATH}"
	prepend-path PATH "${UMPIRE_PATH}/bin"
	prepend-path LD_LIBRARY_PATH "${UMPIRE_PATH}/${UMPIRE_LIBDIR}"
	prepend-path CPATH "${UMPIRE_PATH}/include"
	setenv umpire_ROOT "${UMPIRE_PATH}"
	setenv umpire_DIR "${UMPIRE_PATH}/${UMPIRE_LIBDIR}/cmake/umpire"
	EOF
fi
