#!/bin/bash
#
# run_rocm_afar_install.sh - non-interactive extract + module-write for a
# single AFAR (AMD Fortran AOMP/LLVM compiler ROCm-drop) tarball.
#
# AFAR drops on repo.radeon.com are pre-built ROCm SDK trees, NOT regular
# upstream ROCm releases:
#   * They're delivered as a single .tar.bz2 archive (no apt/dnf packages).
#   * The token in the filename uses FLANG_RELEASE_NUMBER (e.g. 22.2.0), NOT
#     the underlying ROCm SDK numeric, which lives in .info/version on the
#     extracted tree (afar-22.2.0 -> .info/version=7.2.0;
#                    afar-22.1.0 -> .info/version=7.1.0).
#   * There is no `make rocm`, no rocm_package, no rocm_patches.sh -- the
#     pipeline used by run_rocm_build.sh for official numeric versions
#     does not apply. This script is the AFAR-side analogue: just wget +
#     tar -xjf + write the GPUSDK-shaped modulefile.
#
# Phases:
#   0. Pre-check: skip cleanly (exit 0) if ${TOP_INSTALL_PATH}/rocm-afar-
#      ${FLANG_RELEASE_NUMBER} already exists and --replace-existing is not set.
#   1. AFAR_NUMBER auto-discovery from repo.radeon.com/rocm/misc/flang/ when
#      --afar-number was not supplied. AMD reposts under monotonically
#      increasing build numbers, so we tail -n1 the sorted matches.
#   2. wget the tarball to /tmp, sudo tar -xjpf into ${TOP_INSTALL_PATH}/,
#      sudo mv to drop the AFAR_NUMBER segment from the extracted dir name.
#   3. Read .info/version from the extracted tree -> ROCM_NUMERIC.
#   4. Emit ${TOP_MODULE_PATH}/base/rocm/afar-${FLANG_RELEASE_NUMBER}.lua
#      matching the GPUSDK-shaped modulefile currently deployed at
#      /shared/apps/modules/ubuntu/lmodfiles/base/rocm/afar-22.2.0.lua.
#      That modulefile prepends MODULEPATH for BOTH the SDK-side module
#      tree (rocm-afar-${FLANG_RELEASE_NUMBER}) and the rocmplus side
#      (rocmplus-afar-${ROCM_NUMERIC}); the latter uses .info/version,
#      hence the asymmetric naming.
#
# This script is invoked one-per-token by bare_system/run_rocm_build_sweep.sbatch
# when the sweep loop sees a token of the form afar-X.Y.Z. The sweep's
# regular numeric path (run_rocm_build.sh) is unchanged.

set -eo pipefail

# Capture this script's absolute path BEFORE any cd so the modulefile's
# whatis() provenance line below can git-resolve us even if a downstream
# wget/tar chdir's us out of the repo.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

: ${FLANG_RELEASE_NUMBER:=""}
: ${AFAR_NUMBER:=""}
: ${DISTRO:="ubuntu"}
: ${DISTRO_VERSION:="24.04"}
: ${TOP_INSTALL_PATH:="/nfsapps/opt"}
: ${TOP_MODULE_PATH:="/nfsapps/modules"}
: ${REPLACE_EXISTING:="0"}
: ${KEEP_FAILED_INSTALLS:="0"}

usage() {
   cat <<EOF
Usage: $0 [opts]
  --flang-release-number VER    AFAR release tag (e.g. 22.2.0). REQUIRED.
  --afar-number NUM             AMD-internal build number embedded in the tarball
                                filename. Default: empty (auto-discover from
                                https://repo.radeon.com/rocm/misc/flang/).
  --distro NAME                 default ${DISTRO}
  --distro-version VER          default ${DISTRO_VERSION}
                                (informational only -- the AFAR URL has no
                                distro-version segment, only distro family)
  --top-install-path PATH       SDK extract destination; default ${TOP_INSTALL_PATH}
  --top-module-path  PATH       Lmod root for modulefile; default ${TOP_MODULE_PATH}
  --replace-existing 0|1        overwrite existing rocm-afar-<v> install
                                + modulefile (default ${REPLACE_EXISTING})
  --keep-failed-installs 0|1    on failure, keep partial install + modulefile
                                for post-mortem (default ${KEEP_FAILED_INSTALLS})
  --help
EOF
   exit 1
}

send-error() { usage; echo -e "\nError: ${@}" >&2; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

n=0
while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--flang-release-number") shift; FLANG_RELEASE_NUMBER=${1}; reset-last ;;
      "--afar-number")          shift; AFAR_NUMBER=${1};          reset-last ;;
      "--distro")               shift; DISTRO=${1};               reset-last ;;
      "--distro-version")       shift; DISTRO_VERSION=${1};       reset-last ;;
      "--top-install-path")     shift; TOP_INSTALL_PATH=${1};     reset-last ;;
      "--top-module-path")      shift; TOP_MODULE_PATH=${1};      reset-last ;;
      "--replace-existing")     shift; REPLACE_EXISTING=${1};     reset-last ;;
      "--keep-failed-installs") shift; KEEP_FAILED_INSTALLS=${1}; reset-last ;;
      "--help"|"-h")            usage ;;
      *)                        last ${1} ;;
   esac
   n=$((n + 1))
   shift
done

[[ -z "${FLANG_RELEASE_NUMBER}" ]] && send-error "--flang-release-number is required"

ARCHIVE_DIR="rocm-afar-${FLANG_RELEASE_NUMBER}"
INSTALL_DIR="${TOP_INSTALL_PATH}/${ARCHIVE_DIR}"
MODULE_DIR="${TOP_MODULE_PATH}/base/rocm"
MODULE_FILE="${MODULE_DIR}/afar-${FLANG_RELEASE_NUMBER}.lua"

# ---------------- Phase 0: skip-if-installed pre-check ----------------
if [[ -d "${INSTALL_DIR}" && "${REPLACE_EXISTING}" != "1" ]]; then
   echo "[$(date)] SKIP afar-${FLANG_RELEASE_NUMBER}: ${INSTALL_DIR} already exists"
   echo "         Pass --replace-existing 1 to re-download + re-extract."
   exit 0
fi

# ---------------- Defensive remount of /nfsapps as rw -----------------
# /etc/exports.d/nfsapps_sh5_rw.exports grants rw to sh5 admin nodes, but
# the warewulf-managed fstab still mounts /nfsapps ro by default. Mirrors
# the same block in run_rocm_build.sh:209-214.
INSTALL_PARENT="${TOP_INSTALL_PATH%/*}"
if ! sudo -n test -w "${INSTALL_PARENT}" 2>/dev/null; then
   echo "Attempting to remount ${INSTALL_PARENT} rw..."
   sudo mount -o remount,rw "${INSTALL_PARENT}" 2>/dev/null || true
fi
if ! sudo -n test -w "${INSTALL_PARENT}" 2>/dev/null; then
   echo "ERROR: ${INSTALL_PARENT} is not writable on $(hostname); aborting." >&2
   mount | grep nfsapps || true
   exit 1
fi

# Self-heal install/module roots if missing (mirrors the sweep sbatch).
for d in "${TOP_INSTALL_PATH}" "${TOP_MODULE_PATH}" "${MODULE_DIR}"; do
   if ! sudo -n test -d "${d}" 2>/dev/null; then
      echo "Creating missing ${d}"
      sudo install -d -o root -g root -m 0755 "${d}"
   fi
done

# ---------------- --replace-existing cleanup --------------------------
if [[ "${REPLACE_EXISTING}" == "1" ]]; then
   if [[ -d "${INSTALL_DIR}" ]]; then
      echo "[--replace-existing 1] removing ${INSTALL_DIR}"
      sudo rm -rf "${INSTALL_DIR}"
   fi
   if [[ -f "${MODULE_FILE}" ]]; then
      echo "[--replace-existing 1] removing ${MODULE_FILE}"
      sudo rm -f "${MODULE_FILE}"
   fi
fi

# ---------------- EXIT-trap fail-cleanup ------------------------------
# Mirrors flang-new_setup.sh:197-208: on non-zero exit, blow away the
# partial install dir + modulefile so the next run starts clean, unless
# --keep-failed-installs 1 preserves them for post-mortem.
_afar_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[afar fail-cleanup] rc=${rc}: removing partial install + modulefile"
      sudo rm -rf "${INSTALL_DIR}" 2>/dev/null || true
      sudo rm -f  "${MODULE_FILE}" 2>/dev/null || true
   elif [ ${rc} -ne 0 ]; then
      echo "[afar fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _afar_on_exit EXIT

# ---------------- Phase 1: AFAR_NUMBER auto-discovery -----------------
# AFAR_NUMBER is the AMD-internal build number embedded in the tarball
# filename (e.g. rocm-afar-8873-drop-22.2.0-ubuntu.tar.bz2). AMD reposts
# the same FLANG_RELEASE_NUMBER under monotonically-increasing build
# numbers when fixing regressions, so tail -n1 the sorted list picks the
# latest repost. The page is a plain Apache directory listing (href= the
# filename), so a simple grep against the HTML works.
URL_BASE="https://repo.radeon.com/rocm/misc/flang"
if [[ -z "${AFAR_NUMBER}" ]]; then
   echo "============================================================"
   echo "  Phase 1: discover AFAR_NUMBER for flang-release ${FLANG_RELEASE_NUMBER} on ${DISTRO}"
   echo "============================================================"
   PATTERN="rocm-afar-[0-9]+-drop-${FLANG_RELEASE_NUMBER}-${DISTRO}\.tar\.bz2"
   AFAR_NUMBER=$(curl -fsSL "${URL_BASE}/" \
      | grep -oE "${PATTERN}" \
      | sort -u \
      | tail -n1 \
      | sed -E 's/^rocm-afar-([0-9]+)-drop-.*$/\1/')
   if [[ -z "${AFAR_NUMBER}" ]]; then
      echo "ERROR: could not auto-discover AFAR_NUMBER for flang-release '${FLANG_RELEASE_NUMBER}' on distro '${DISTRO}'" >&2
      echo "       (no match for pattern '${PATTERN}' at ${URL_BASE}/)" >&2
      echo "       Pass --afar-number NUM explicitly, or verify the drop exists upstream." >&2
      exit 1
   fi
   echo "Discovered AFAR_NUMBER=${AFAR_NUMBER} for rocm-afar-${FLANG_RELEASE_NUMBER} (${DISTRO})"
fi

ARCHIVE_NAME="rocm-afar-${AFAR_NUMBER}-drop-${FLANG_RELEASE_NUMBER}"
FULL_ARCHIVE_NAME="${ARCHIVE_NAME}-${DISTRO}"
TARBALL_URL="${URL_BASE}/${FULL_ARCHIVE_NAME}.tar.bz2"
LOCAL_TARBALL="/tmp/${FULL_ARCHIVE_NAME}.tar.bz2"

echo ""
echo "============================================================"
echo "  AFAR install plan"
echo "============================================================"
echo "  FLANG_RELEASE_NUMBER : ${FLANG_RELEASE_NUMBER}"
echo "  AFAR_NUMBER          : ${AFAR_NUMBER}"
echo "  DISTRO               : ${DISTRO} ${DISTRO_VERSION}"
echo "  Tarball URL          : ${TARBALL_URL}"
echo "  Local tarball        : ${LOCAL_TARBALL}"
echo "  Install dir          : ${INSTALL_DIR}"
echo "  Modulefile           : ${MODULE_FILE}"
echo "  REPLACE_EXISTING     : ${REPLACE_EXISTING}"
echo "  KEEP_FAILED_INSTALLS : ${KEEP_FAILED_INSTALLS}"
echo "============================================================"
echo ""

# ---------------- Phase 2: download + extract -------------------------
echo "============================================================"
echo "  Phase 2: wget + tar -xjpf -> ${TOP_INSTALL_PATH}/"
echo "============================================================"
rm -f "${LOCAL_TARBALL}"
wget -q --show-progress "${TARBALL_URL}" -O "${LOCAL_TARBALL}"
sudo tar -xjpf "${LOCAL_TARBALL}" -C "${TOP_INSTALL_PATH}/"

# Drop the AFAR_NUMBER segment so the on-disk dir matches the modulefile
# token. The tarball expands to rocm-afar-<NUM>-drop-<REL>/; we rename to
# rocm-afar-<REL>/. Bail loudly if the expected source dir is missing --
# that would mean AMD changed the in-archive layout.
EXTRACTED_DIR="${TOP_INSTALL_PATH}/${ARCHIVE_NAME}"
if [[ ! -d "${EXTRACTED_DIR}" ]]; then
   echo "ERROR: expected extracted dir not found: ${EXTRACTED_DIR}" >&2
   echo "       (Did the AFAR drop change its top-level dir name?)" >&2
   sudo find "${TOP_INSTALL_PATH}" -maxdepth 1 -name 'rocm-afar-*' -type d -printf '       found: %p\n' || true
   exit 1
fi
sudo mv "${EXTRACTED_DIR}" "${INSTALL_DIR}"
sudo chown -R root:root "${INSTALL_DIR}"
sudo chmod 755 "${INSTALL_DIR}"
rm -f "${LOCAL_TARBALL}"
echo "Extracted: ${INSTALL_DIR}"

# ---------------- Phase 3: derive ROCM_NUMERIC from .info/version -----
if [[ ! -f "${INSTALL_DIR}/.info/version" ]]; then
   echo "ERROR: ${INSTALL_DIR}/.info/version missing; cannot derive ROCM_NUMERIC" >&2
   echo "       This is required for the rocmplus-afar-<numeric> MODULEPATH" >&2
   echo "       prepend in the modulefile below." >&2
   exit 1
fi
ROCM_NUMERIC=$(cut -f1 -d- "${INSTALL_DIR}/.info/version")
if [[ -z "${ROCM_NUMERIC}" ]]; then
   echo "ERROR: ${INSTALL_DIR}/.info/version is empty" >&2
   exit 1
fi
echo "ROCM_NUMERIC (from .info/version): ${ROCM_NUMERIC}"

# ---------------- Phase 4: emit GPUSDK modulefile ---------------------
# Provenance: capture this leaf script's git state for the whatis() line.
# Same pattern as flang-new_setup.sh:298-313.
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

echo "============================================================"
echo "  Phase 4: write modulefile ${MODULE_FILE}"
echo "============================================================"
sudo mkdir -p "${MODULE_DIR}"

# Heredoc-pipe into sudo tee so the modulefile is created root-owned even
# when this script runs as a non-root user. The modulefile shape matches
# the currently-deployed /shared/apps/modules/ubuntu/lmodfiles/base/rocm/
# afar-22.2.0.lua exactly (family("GPUSDK"), ROCM_PATH, and TWO MODULEPATH
# prepends -- one to rocm-afar-<flang-rel> for SDK packages, one to
# rocmplus-afar-<rocm-numeric> for the rocmplus stack).
sudo tee "${MODULE_FILE}" >/dev/null <<EOF
whatis("Name: ROCm")
whatis("Version: afar-${FLANG_RELEASE_NUMBER}")
whatis("Category: AMD")
whatis("ROCm")
whatis("Set HIPCC_VERBOSE=7 to see what hipcc is doing for the compilation and link")
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
setenv("HIPCC_COMPILE_FLAGS_APPEND", "--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/11")
setenv("HIPCC_LINK_FLAGS_APPEND",    "--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/11")
setenv("ROCM_PATH", base)
prepend_path("MODULEPATH", pathJoin(mbase, "rocm-afar-${FLANG_RELEASE_NUMBER}"))
prepend_path("MODULEPATH", pathJoin(mbase, "rocmplus-afar-${ROCM_NUMERIC}"))
family("GPUSDK")

-- Place the rocprof-sys-run wrapper (which applies a libbfd LD_PRELOAD
-- workaround when the system libbfd is older than the one rocprof-sys
-- statically links) first in PATH. The wrapper is a no-op on systems
-- where the system libbfd is new enough.
prepend_path("PATH", pathJoin(base, "share/rocprofiler-systems/bin"))
EOF
sudo chown root:root "${MODULE_FILE}"
sudo chmod 644 "${MODULE_FILE}"

echo ""
echo "============================================================"
echo "  Done: afar-${FLANG_RELEASE_NUMBER} (ROCM_NUMERIC=${ROCM_NUMERIC})"
echo "  Install: ${INSTALL_DIR}"
echo "  Module : ${MODULE_FILE}"
echo "============================================================"
