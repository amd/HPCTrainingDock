#!/bin/bash
#
# run_rocm_craywrap_install.sh -- AAC7-side "extract + Cray-module" step for a
# NUMERIC ROCm tree that was built elsewhere (e.g. the almalinux-9.6 docker
# build produced on AAC6 in the sh5_cpx_admin_long queue) and transferred over.
#
# The numeric docker pipeline (run_rocm_build.sh) emits Lmod/numeric-shaped
# modulefiles, NOT the Cray PrgEnv-amd-new ecosystem. On the Cray login node
# (AAC7, no Docker) we therefore:
#   1. extract the staged tree tarball into ${TOP_INSTALL_PATH}/rocm-<ver>,
#   2. write a base rocm/<ver> modulefile (classic Tcl on Cray),
#   3. emit per-package amdclang/hipfort/opencl modulefiles,
#   4. emit rocm-<ver>.pc (pkg-config for the craype cc/CC/ftn wrappers), and
#   5. emit the PrgEnv-amd-new/<pe>-<ver> ecosystem,
# i.e. the SAME treatment run_rocm_therock_install.sh gives a TheRock tarball,
# so a transferred numeric build behaves "like 7.13.0" under the Cray wrappers.
#
# This is the numeric-tree analogue of run_rocm_therock_install.sh --local-tarball
# (which handles the distro-agnostic TheRock/AFAR tarballs). It reuses the same
# leaf_modulefile_helpers.sh emitters.
#
# The staged tarball may expand either FLAT (bin/, lib/, llvm/ at depth 0) or
# under a single wrapper dir (e.g. rocm-7.2.3/); both are handled.

set -eo pipefail

LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

: ${ROCM_VERSION:=""}
: ${LOCAL_TARBALL_INPUT:=""}
: ${AMDGPU_FAMILY:="gfx94X-dcgpu"}    # informational (provenance comment only)
: ${TOP_INSTALL_PATH:="/nfsapps/opt"}
: ${TOP_MODULE_PATH:="/nfsapps/modules"}
: ${REPLACE_EXISTING:="0"}
: ${KEEP_FAILED_INSTALLS:="0"}
# WORLD_READABLE: 1 = make install + module trees group/other readable (o+rX)
# for a shared location (e.g. /shareddata); 0 = leave as-is; "auto" (default) =
# enable iff TOP_INSTALL_PATH is NOT under $HOME.
: ${WORLD_READABLE:="auto"}
: ${NO_SUDO:=""}
: ${CRAY_SYSTEM:=""}
: ${PE_VERSION:=""}
# Build the from-source AMD-LLVM MPICH wrappers PrgEnv-amd-new auto-loads.
: ${BUILD_MPICH_WRAPPERS:="1"}
# MPI family the PrgEnv-amd-new layers on: mpich (default) builds+loads the
# wrappers; openmpi skips them (OpenMPI ships an amdflang-compatible mpi.mod).
: ${MPI_FAMILY:="mpich"}
SUDO="sudo"

chown_root() { [ "${NO_SUDO}" = "1" ] && return 0; sudo chown "$@"; }
make_dir_root() {
   if [ "${NO_SUDO}" = "1" ]; then mkdir -p "$1"; else sudo install -d -o root -g root -m 0755 "$1"; fi
}

usage() {
   cat <<EOF
Usage: $0 [opts]
  --rocm-version VER        numeric ROCm version of the staged tree (e.g. 7.2.3). REQUIRED.
  --local-tarball PATH      .tar.gz of the built rocm tree to extract. REQUIRED.
  --amdgpu-family FAM       informational provenance tag; default ${AMDGPU_FAMILY}
  --top-install-path PATH   SDK extract destination; default ${TOP_INSTALL_PATH}
  --top-module-path  PATH   module root; default ${TOP_MODULE_PATH}
  --replace-existing 0|1    overwrite existing rocm-<ver> + modulefiles (default ${REPLACE_EXISTING})
  --keep-failed-installs 0|1 keep partial artifacts on failure (default ${KEEP_FAILED_INSTALLS})
  --no-sudo 0|1             force sudo-free (default: auto-detect a writable install parent)
  --cray-modules            force Cray classic Tcl modules + PrgEnv-amd-new ecosystem
                            (auto-detected on Cray PE hosts otherwise)
  --pe-version VER          stock PrgEnv-amd version the PrgEnv-amd-new wraps (Cray only;
                            default: auto-detect the highest PrgEnv-amd)
  --build-mpich-wrappers 0|1 build+emit the from-source AMD-LLVM MPICH wrappers
                            PrgEnv-amd-new auto-loads (Cray only; default ${BUILD_MPICH_WRAPPERS})
  --mpi-family mpich|openmpi MPI family the PrgEnv-amd-new uses; openmpi skips the
                            mpich wrappers (build + load block). Default ${MPI_FAMILY}
  --help
EOF
   exit 1
}

send-error() { usage; echo -e "\nError: ${@}" >&2; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--rocm-version")         shift; ROCM_VERSION=${1};         reset-last ;;
      "--local-tarball")        shift; LOCAL_TARBALL_INPUT=${1};  reset-last ;;
      "--amdgpu-family")        shift; AMDGPU_FAMILY=${1};        reset-last ;;
      "--top-install-path")     shift; TOP_INSTALL_PATH=${1};     reset-last ;;
      "--top-module-path")      shift; TOP_MODULE_PATH=${1};      reset-last ;;
      "--replace-existing")     shift; REPLACE_EXISTING=${1};     reset-last ;;
      "--keep-failed-installs") shift; KEEP_FAILED_INSTALLS=${1}; reset-last ;;
      "--no-sudo")              shift; NO_SUDO=${1};              reset-last ;;
      "--cray-modules")         CRAY_SYSTEM=1;                    reset-last ;;
      "--pe-version")           shift; PE_VERSION=${1};           reset-last ;;
      "--build-mpich-wrappers") shift; BUILD_MPICH_WRAPPERS=${1}; reset-last ;;
      "--mpi-family")           shift; MPI_FAMILY=${1};          reset-last ;;
      "--help"|"-h")            usage ;;
      *)                        last ${1} ;;
   esac
   shift
done

[[ -z "${ROCM_VERSION}" ]]       && send-error "--rocm-version is required"
[[ -z "${LOCAL_TARBALL_INPUT}" ]] && send-error "--local-tarball is required"
if [[ ! "${ROCM_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
   send-error "--rocm-version must be X.Y or X.Y.Z (got '${ROCM_VERSION}')"
fi
if [[ ! -f "${LOCAL_TARBALL_INPUT}" ]]; then
   send-error "--local-tarball '${LOCAL_TARBALL_INPUT}' does not exist"
fi
LOCAL_TARBALL="$(cd "$(dirname "${LOCAL_TARBALL_INPUT}")" && pwd -P)/$(basename "${LOCAL_TARBALL_INPUT}")"

MODULE_DIR="${TOP_MODULE_PATH}/base/rocm"
INSTALL_DIR="${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}"

# ---------------- Phase 0: skip-if-installed -------------------------
if [[ -d "${INSTALL_DIR}" && "${REPLACE_EXISTING}" != "1" ]]; then
   echo "[$(date)] SKIP rocm-${ROCM_VERSION}: ${INSTALL_DIR} already exists"
   echo "         Pass --replace-existing 1 to re-extract."
   exit 0
fi

# ---------------- Resolve sudo + Cray flavor -------------------------
INSTALL_PARENT="${TOP_INSTALL_PATH%/*}"
if [ -z "${NO_SUDO}" ]; then
   if [ -w "${INSTALL_PARENT}" ] 2>/dev/null \
      || { [ ! -e "${INSTALL_PARENT}" ] && [ -w "$(dirname "${INSTALL_PARENT}")" ] 2>/dev/null; }; then
      NO_SUDO=1
   else
      NO_SUDO=0
   fi
fi
[ "${NO_SUDO}" = "1" ] && SUDO="" || SUDO="sudo"
if [ -z "${CRAY_SYSTEM}" ]; then
   if [ -d /opt/cray/pe ] || [ -f /etc/cray-release ] || [ -n "${CRAYPE_VERSION:-}" ]; then
      CRAY_SYSTEM=1
   else
      CRAY_SYSTEM=0
   fi
fi
echo "[craywrap] NO_SUDO=${NO_SUDO}  CRAY_SYSTEM=${CRAY_SYSTEM}  (sudo='${SUDO}')"

if [ "${CRAY_SYSTEM}" = "1" ]; then
   MODULE_FILE="${MODULE_DIR}/${ROCM_VERSION}"
else
   MODULE_FILE="${MODULE_DIR}/${ROCM_VERSION}.lua"
fi

if [ "${NO_SUDO}" != "1" ]; then
   if ! sudo -n test -w "${INSTALL_PARENT}" 2>/dev/null; then
      sudo mount -o remount,rw "${INSTALL_PARENT}" 2>/dev/null || true
   fi
fi
if [ "${NO_SUDO}" = "1" ] && [ ! -w "${INSTALL_PARENT}" ]; then
   echo "ERROR: ${INSTALL_PARENT} is not writable by $(id -un) on $(hostname); aborting." >&2
   exit 1
fi
for d in "${TOP_INSTALL_PATH}" "${TOP_MODULE_PATH}" "${MODULE_DIR}"; do
   [ -d "${d}" ] || { echo "Creating missing ${d}"; make_dir_root "${d}"; }
done

STAGING_DIR="${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}.staging.$$"

# ---------------- --replace-existing cleanup ------------------------
if [[ "${REPLACE_EXISTING}" == "1" ]]; then
   [[ -d "${INSTALL_DIR}" ]] && { echo "[--replace-existing 1] removing ${INSTALL_DIR}"; ${SUDO} rm -rf "${INSTALL_DIR}"; }
   [[ -f "${MODULE_FILE}" ]] && { echo "[--replace-existing 1] removing ${MODULE_FILE}"; ${SUDO} rm -f "${MODULE_FILE}"; }
fi

# ---------------- EXIT-trap fail-cleanup ----------------------------
PROMOTED_INSTALL=0
_craywrap_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[craywrap fail-cleanup] rc=${rc}: removing staging + partial install"
      ${SUDO} rm -rf "${STAGING_DIR}" 2>/dev/null || true
      [ "${PROMOTED_INSTALL}" = "1" ] && ${SUDO} rm -rf "${INSTALL_DIR}" 2>/dev/null || true
      [ -n "${MODULE_FILE}" ] && ${SUDO} rm -f "${MODULE_FILE}" 2>/dev/null || true
   fi
   return ${rc}
}
trap _craywrap_on_exit EXIT

# ---------------- Phase 2: extract staged tree ----------------------
echo "============================================================"
echo "  Phase 2: extract ${LOCAL_TARBALL} -> ${STAGING_DIR}"
echo "============================================================"
${SUDO} rm -rf "${STAGING_DIR}"
make_dir_root "${STAGING_DIR}"
# Accept .tar.gz / .tgz / .tar.bz2 transparently (-a infers compression).
${SUDO} tar --no-same-owner -xapf "${LOCAL_TARBALL}" -C "${STAGING_DIR}"

# Locate the tree root: FLAT (bin/ at depth 0) or a single wrapper subdir.
SOURCE_DIR=""
if ${SUDO} test -d "${STAGING_DIR}/bin" || ${SUDO} test -d "${STAGING_DIR}/lib" \
   || ${SUDO} test -f "${STAGING_DIR}/.info/version"; then
   SOURCE_DIR="${STAGING_DIR}"
   echo "Tree layout: FLAT"
else
   _subs=()
   while IFS= read -r -d $'\0' _d; do _subs+=("${_d}"); done \
      < <(${SUDO} find "${STAGING_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
   if [[ ${#_subs[@]} -eq 1 ]]; then
      SOURCE_DIR="${_subs[0]}"
      echo "Tree layout: WRAPPER ('${SOURCE_DIR##*/}')"
   fi
   unset _subs _d
fi
if [[ -z "${SOURCE_DIR}" ]]; then
   echo "ERROR: could not locate the ROCm tree root in ${STAGING_DIR}" >&2
   ${SUDO} ls -la "${STAGING_DIR}" 2>&1 | sed 's/^/       /' || true
   exit 1
fi

# Prefer the authoritative .info/version if the tree carries one.
ROCM_NUMERIC="${ROCM_VERSION}"
if ${SUDO} test -f "${SOURCE_DIR}/.info/version" 2>/dev/null; then
   _iv="$(${SUDO} cut -f1 -d- "${SOURCE_DIR}/.info/version" 2>/dev/null || true)"
   if [[ -n "${_iv}" && "${_iv}" != "${ROCM_VERSION}" ]]; then
      echo "NOTE: .info/version reports ${_iv}; using it over --rocm-version ${ROCM_VERSION}."
      ROCM_NUMERIC="${_iv}"
   fi
   unset _iv
fi

# ---------------- Phase 4: promote to final install dir -------------
echo "============================================================"
echo "  Phase 4: promote -> ${INSTALL_DIR}"
echo "============================================================"
if [[ -d "${INSTALL_DIR}" ]]; then
   [[ "${REPLACE_EXISTING}" == "1" ]] && ${SUDO} rm -rf "${INSTALL_DIR}" \
      || { echo "ERROR: ${INSTALL_DIR} exists; pass --replace-existing 1" >&2; exit 1; }
fi
if [[ "${SOURCE_DIR}" == "${STAGING_DIR}" ]]; then
   ${SUDO} mv "${STAGING_DIR}" "${INSTALL_DIR}"
else
   ${SUDO} mv "${SOURCE_DIR}" "${INSTALL_DIR}"
   ${SUDO} rmdir "${STAGING_DIR}" 2>/dev/null || true
fi
PROMOTED_INSTALL=1
chown_root -R root:root "${INSTALL_DIR}"
${SUDO} chmod 755 "${INSTALL_DIR}"
echo "Installed: ${INSTALL_DIR}"

# ---------------- Phase 5: base modulefile --------------------------
LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
LEAF_SCRIPT_COMMIT=unknown
LEAF_SCRIPT_DIRTY=unknown
_leaf_dir="$(dirname "${LEAF_SCRIPT_PATH}")"
if [ -d "${_leaf_dir}" ] && command -v git >/dev/null 2>&1 \
   && git -C "${_leaf_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
   _commit="$(git -C "${_leaf_dir}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
   [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"
   if [ -n "$(git -C "${_leaf_dir}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ]; then
      LEAF_SCRIPT_DIRTY=dirty; else LEAF_SCRIPT_DIRTY=clean; fi
   unset _commit
fi
unset _leaf_dir

echo "============================================================"
echo "  Phase 5: write modulefile ${MODULE_FILE}"
echo "============================================================"
${SUDO} mkdir -p "${MODULE_DIR}"
if [ "${CRAY_SYSTEM}" = "1" ]; then
${SUDO} tee "${MODULE_FILE}" >/dev/null <<EOF
#%Module
#
# ROCm ${ROCM_NUMERIC} (numeric build, almalinux 9.6, family ${AMDGPU_FAMILY}) -- Tcl modulefile.
# Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})

conflict rocm

module-whatis "ROCm ${ROCM_NUMERIC} (numeric build, Cray-wrapped on AAC7)"

set base  ${INSTALL_DIR}

setenv ROCM_PATH               \$base
setenv HSA_NO_SCRATCH_RECLAIM  1

prepend-path LD_LIBRARY_PATH    \$base/lib
prepend-path C_INCLUDE_PATH     \$base/include
prepend-path CPLUS_INCLUDE_PATH \$base/include
prepend-path CPATH              \$base/include
prepend-path INCLUDE            \$base/include
prepend-path PATH               \$base/bin

set _self    [file normalize \${ModulesCurrentModulefile}]
set _modroot [file dirname [file dirname [file dirname \$_self]]]
prepend-path MODULEPATH \$_modroot/rocm-${ROCM_NUMERIC}
prepend-path MODULEPATH \$_modroot/rocmplus-${ROCM_NUMERIC}
EOF
else
${SUDO} tee "${MODULE_FILE}" >/dev/null <<EOF
whatis("Name: ROCm")
whatis("Version: ${ROCM_NUMERIC}")
whatis("Category: AMD")
whatis("Source: numeric build (almalinux 9.6, family ${AMDGPU_FAMILY}), Cray-wrapped on AAC7")
whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

local base  = "${INSTALL_DIR}"
local mbase = "${TOP_MODULE_PATH}"

prepend_path("LD_LIBRARY_PATH",    pathJoin(base, "lib"))
prepend_path("C_INCLUDE_PATH",     pathJoin(base, "include"))
prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
prepend_path("CPATH",              pathJoin(base, "include"))
prepend_path("PATH",               pathJoin(base, "bin"))
prepend_path("INCLUDE",            pathJoin(base, "include"))
setenv("HSA_NO_SCRATCH_RECLAIM", "1")
setenv("ROCM_PATH", base)
prepend_path("MODULEPATH", pathJoin(mbase, "rocm-${ROCM_NUMERIC}"))
prepend_path("MODULEPATH", pathJoin(mbase, "rocmplus-${ROCM_NUMERIC}"))
family("GPUSDK")
EOF
fi
chown_root root:root "${MODULE_FILE}"
${SUDO} chmod 644 "${MODULE_FILE}"

# ---------------- Phase 5b/5c: per-package + .pc + Cray ecosystem ---
# shellcheck source=bare_system/leaf_modulefile_helpers.sh
source "$(dirname "${LEAF_SCRIPT_PATH}")/leaf_modulefile_helpers.sh"
echo "============================================================"
echo "  Phase 5b: per-package modulefiles under ${TOP_MODULE_PATH}/rocm-${ROCM_NUMERIC}/"
echo "============================================================"
emit_per_package_modulefiles \
   "${TOP_MODULE_PATH}/rocm-${ROCM_NUMERIC}" \
   "${ROCM_NUMERIC}" \
   "rocm/${ROCM_NUMERIC}" \
   "${INSTALL_DIR}" \
   "${LEAF_SCRIPT_NAME}" \
   "${LEAF_SCRIPT_COMMIT:0:12}" \
   "${LEAF_SCRIPT_DIRTY}"

echo "============================================================"
echo "  Phase 5c: pkg-config file + (Cray) PrgEnv-amd-new ecosystem"
echo "============================================================"
emit_rocm_pc "${INSTALL_DIR}" "${ROCM_NUMERIC}"

if [ "${CRAY_SYSTEM}" = "1" ]; then
   if [ -z "${PE_VERSION}" ]; then
      if [ -d /opt/cray/pe/modulefiles/PrgEnv-amd ]; then
         PE_VERSION=$(ls -1 /opt/cray/pe/modulefiles/PrgEnv-amd 2>/dev/null \
                      | grep -E '^[0-9]+\.' | sort -V | tail -n1)
      fi
      if [ -z "${PE_VERSION}" ] && command -v module >/dev/null 2>&1; then
         PE_VERSION=$(module -t avail PrgEnv-amd 2>&1 \
                      | grep -oE 'PrgEnv-amd/[0-9][^ ]*' \
                      | sed 's#PrgEnv-amd/##' | sort -V | tail -n1)
      fi
   fi
   if [ -z "${PE_VERSION}" ]; then
      echo "WARNING: could not auto-detect a stock PrgEnv-amd version; skipping"
      echo "         the PrgEnv-amd-new ecosystem. Re-run with --pe-version VER."
   else
      echo "  PrgEnv-amd version to wrap: ${PE_VERSION}"
      emit_cray_prgenv_ecosystem \
         "${TOP_MODULE_PATH}/base" \
         "${TOP_MODULE_PATH}/rocm-${ROCM_NUMERIC}" \
         "${TOP_MODULE_PATH}/rocmplus-${ROCM_NUMERIC}" \
         "${ROCM_NUMERIC}" \
         "${INSTALL_DIR}" \
         "${PE_VERSION}" \
         "${LEAF_SCRIPT_NAME}" \
         "${LEAF_SCRIPT_COMMIT:0:12}" \
         "${LEAF_SCRIPT_DIRTY}"
      # Build + emit the from-source AMD-LLVM MPICH wrappers that
      # PrgEnv-amd-new/<pe>-${ROCM_NUMERIC} auto-loads (amdflang cannot read
      # cray-mpich's mpi.mod). Non-fatal: skips cleanly if it cannot build.
      build_and_emit_mpich_wrappers \
         "${TOP_MODULE_PATH}/rocmplus-${ROCM_NUMERIC}" \
         "${ROCM_NUMERIC}" \
         "${INSTALL_DIR}" \
         "${INSTALL_DIR}/mpich-wrappers" \
         "${LEAF_SCRIPT_NAME}" \
         "${LEAF_SCRIPT_COMMIT:0:12}" \
         "${LEAF_SCRIPT_DIRTY}"
      echo "  -> expose with: module use ${TOP_MODULE_PATH}/base"
      echo "  -> then:        module swap PrgEnv-cray PrgEnv-amd-new/${PE_VERSION}-${ROCM_NUMERIC}"
      echo "  -> or (CCE+ROCm): module swap PrgEnv-cray PrgEnv-cray-new/${PE_VERSION}-${ROCM_NUMERIC}"
   fi
fi

# ---------------- world-readable perms (shared install locations) -----
_world_ro=0
case "${WORLD_READABLE}" in
   1) _world_ro=1 ;;
   auto)
      if [ -n "${HOME}" ]; then
         case "${TOP_INSTALL_PATH}" in "${HOME}"/*|"${HOME}") _world_ro=0 ;; *) _world_ro=1 ;; esac
      else
         _world_ro=1
      fi ;;
esac
if [ "${_world_ro}" = "1" ]; then
   make_world_readable \
      "${INSTALL_DIR}" \
      "${TOP_MODULE_PATH}/base" \
      "${TOP_MODULE_PATH}/rocm-${ROCM_NUMERIC}" \
      "${TOP_MODULE_PATH}/rocmplus-${ROCM_NUMERIC}" \
      "${MODULE_FILE}"
fi
unset _world_ro

echo ""
echo "============================================================"
echo "  Done: rocm-${ROCM_NUMERIC} (numeric build, Cray-wrapped)"
echo "  Install: ${INSTALL_DIR}"
echo "  Module : ${MODULE_FILE}"
echo "============================================================"
