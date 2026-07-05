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
#   0. Pre-check: skip cleanly (exit 0) if BOTH ${TOP_INSTALL_PATH}/rocm-afar-
#      ${FLANG_RELEASE_NUMBER} AND a matching afar-${FLANG_RELEASE_NUMBER}-*.lua
#      modulefile (new unified naming) already exist and --replace-existing
#      is not set. If only the install dir is present (legacy install from
#      before the afar-<REL>-<ROCM>.lua naming), Phase 1+2 are skipped via
#      SKIP_EXTRACT=1 and only the new-shape modulefile is emitted from the
#      existing .info/version (soft cutover).
#   1. AFAR_NUMBER auto-discovery from repo.radeon.com/rocm/misc/flang/ when
#      --afar-number was not supplied. AMD reposts under monotonically
#      increasing build numbers, so we tail -n1 the sorted matches.
#   2. wget the tarball to /tmp, sudo tar -xjpf into ${TOP_INSTALL_PATH}/,
#      sudo mv to drop the AFAR_NUMBER segment from the extracted dir name.
#   3. Read .info/version from the extracted tree -> ROCM_NUMERIC.
#   4. Emit ${TOP_MODULE_PATH}/base/rocm/afar-${FLANG_RELEASE_NUMBER}-${ROCM_NUMERIC}.lua
#      using the unified flang-site naming scheme:
#         install -> rocm-afar-<REL>          (compiler/AFAR number)
#         module  -> afar-<REL>-<ROCM>.lua    (compiler + SDK numeric)
#      The modulefile prepends MODULEPATH for BOTH the SDK-side module
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
# Phase 6 (rocm_patches.sh) controls -- mirror the numeric branch's
# run_rocm_build.sh:31 SKIP_PATCHES default of 0 (run patches by default).
# PATCHES_LOG is finalized below after FLANG_RELEASE_NUMBER is parsed so
# the on-disk filename reflects the actual release.
: ${SKIP_PATCHES:="0"}
PATCHES_LOG=""

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
                                + afar-<v>-*.lua modulefile (default ${REPLACE_EXISTING}).
                                Also reaps the legacy afar-<v>.lua modulefile
                                (no -<rocm> suffix) from the pre-unified-naming
                                layout.
  --keep-failed-installs 0|1    on failure, keep partial install + modulefile
                                for post-mortem (default ${KEEP_FAILED_INSTALLS})
  --skip-patches 0|1            skip Phase 6 (rocm_patches.sh on the AFAR
                                tree; mirrors run_rocm_build.sh's --skip-patches).
                                Default ${SKIP_PATCHES} (run patches).
  --patches-log PATH            log file for the Phase 6 rocm_patches.sh tee;
                                default patches_afar-\${FLANG_RELEASE_NUMBER}.out
  --help
EOF
   exit 1
}

# Print the real error FIRST: usage() ends in `exit 1`, so anything echoed
# after usage() is unreachable and the true cause gets masked.
send-error() { echo -e "Error: ${*}\n" >&2; usage; }
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
      "--skip-patches")         shift; SKIP_PATCHES=${1};         reset-last ;;
      "--patches-log")          shift; PATCHES_LOG=${1};          reset-last ;;
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

# Phase 6 default log basename. Set after the parse loop so an explicit
# --patches-log overrides this; the basename matches the numeric branch's
# patches_${ROCM_VERSION}.out (here keyed on the AFAR release tag).
: ${PATCHES_LOG:="patches_afar-${FLANG_RELEASE_NUMBER}.out"}
# MODULE_FILE is finalized AFTER Phase 3 once ROCM_NUMERIC is known (the
# new naming embeds the SDK numeric: afar-<REL>-<ROCM>.lua). Phase 0
# uses a glob match (afar-${REL}-*.lua) so we can detect any rocm
# version that may have been installed for this FLANG_RELEASE_NUMBER.
LEGACY_MODULE_FILE="${MODULE_DIR}/afar-${FLANG_RELEASE_NUMBER}.lua"
MODULE_FILE=""   # set after Phase 3

# ---------------- Phase 0: skip-if-installed pre-check ----------------
# Skip only if BOTH the install dir AND a new-shape modulefile
# (afar-${REL}-<rocm>.lua) already exist. If the install dir is present
# but the new-shape modulefile is missing (e.g. a legacy install from
# before the unified afar-<REL>-<ROCM>.lua naming), we fall through:
# Phase 1's URL discovery and Phase 2's download/extract are skipped via
# the SKIP_EXTRACT flag below, but Phase 3 will re-read .info/version
# from the existing install and Phase 4 will emit the new-shape
# modulefile -- soft cutover, no re-extraction needed.
SKIP_EXTRACT=0
if [[ -d "${INSTALL_DIR}" && "${REPLACE_EXISTING}" != "1" ]]; then
   shopt -s nullglob
   _existing_modules=( "${MODULE_DIR}"/afar-${FLANG_RELEASE_NUMBER}-*.lua )
   shopt -u nullglob
   if [[ ${#_existing_modules[@]} -gt 0 ]]; then
      echo "[$(date)] SKIP afar-${FLANG_RELEASE_NUMBER}: ${INSTALL_DIR} + ${_existing_modules[0]} already exist"
      echo "         Pass --replace-existing 1 to re-download + re-extract."
      exit 0
   fi
   echo "[$(date)] NOTE afar-${FLANG_RELEASE_NUMBER}: ${INSTALL_DIR} exists but no afar-${FLANG_RELEASE_NUMBER}-*.lua modulefile found"
   echo "         (legacy install from before unified afar-<REL>-<ROCM>.lua naming?);"
   echo "         re-using existing install and emitting new-shape modulefile only."
   SKIP_EXTRACT=1
   unset _existing_modules
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
# Reap BOTH the legacy modulefile (afar-${REL}.lua, no -<rocm> suffix)
# AND any new-shape afar-${REL}-*.lua glob, since the rocm-version
# segment may have changed between runs (e.g. AMD reposts under a
# different .info/version) -- leaving a stale numeric-suffixed module
# behind would result in two visible modules for the same FLANG release.
if [[ "${REPLACE_EXISTING}" == "1" ]]; then
   if [[ -d "${INSTALL_DIR}" ]]; then
      echo "[--replace-existing 1] removing ${INSTALL_DIR}"
      sudo rm -rf "${INSTALL_DIR}"
   fi
   if [[ -f "${LEGACY_MODULE_FILE}" ]]; then
      echo "[--replace-existing 1] removing legacy ${LEGACY_MODULE_FILE}"
      sudo rm -f "${LEGACY_MODULE_FILE}"
   fi
   shopt -s nullglob
   for _stale in "${MODULE_DIR}"/afar-${FLANG_RELEASE_NUMBER}-*.lua; do
      echo "[--replace-existing 1] removing ${_stale}"
      sudo rm -f "${_stale}"
   done
   shopt -u nullglob
   unset _stale
fi

# ---------------- EXIT-trap fail-cleanup ------------------------------
# Mirrors flang-new_setup.sh:197-208: on non-zero exit, blow away the
# partial install dir + modulefile so the next run starts clean, unless
# --keep-failed-installs 1 preserves them for post-mortem.
_afar_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[afar fail-cleanup] rc=${rc}: removing partial install + modulefile"
      # Only blow away the install dir when WE created it this run (i.e.
      # SKIP_EXTRACT=0). In the soft-cutover path (SKIP_EXTRACT=1) the
      # install dir was already on disk before this run, so leave it
      # alone -- the failure is in modulefile re-emission only.
      if [ "${SKIP_EXTRACT}" != "1" ]; then
         sudo rm -rf "${INSTALL_DIR}" 2>/dev/null || true
      fi
      [ -n "${MODULE_FILE}" ] && sudo rm -f "${MODULE_FILE}" 2>/dev/null || true
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
if [[ "${SKIP_EXTRACT}" == "1" ]]; then
   echo "============================================================"
   echo "  Phase 1+2: SKIPPED (soft-cutover: ${INSTALL_DIR} already on disk)"
   echo "============================================================"
   ARCHIVE_NAME="(skipped)"
   TARBALL_URL="(skipped)"
   LOCAL_TARBALL=""
else
   if [[ -z "${AFAR_NUMBER}" ]]; then
      echo "============================================================"
      echo "  Phase 1: discover AFAR_NUMBER for flang-release ${FLANG_RELEASE_NUMBER} on ${DISTRO}"
      echo "============================================================"
      PATTERN="rocm-afar-[0-9]+-drop-${FLANG_RELEASE_NUMBER}-${DISTRO}\.tar\.bz2"
      # `|| true` on the whole pipeline (brace group): this script has
      # `set -eo pipefail` at the top, so a no-match grep would otherwise
      # kill the script silently before the `if [[ -z "${AFAR_NUMBER}" ]]`
      # ERROR diagnostic below could fire. Same class of bug observed in
      # run_rocm_therock_afar_install.sh during job 10698 (2026-05-26).
      AFAR_NUMBER=$( { curl -fsSL "${URL_BASE}/" \
         | grep -oE "${PATTERN}" \
         | sort -u \
         | tail -n1 \
         | sed -E 's/^rocm-afar-([0-9]+)-drop-.*$/\1/'; } || true)
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
   echo "  Modulefile           : (set after Phase 3, shape afar-${FLANG_RELEASE_NUMBER}-<rocm>.lua)"
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
fi

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

# Finalize MODULE_FILE now that ROCM_NUMERIC is known. The new unified
# naming embeds both the FLANG release tag and the SDK numeric, so the
# operator sees a single rocm/afar-<REL>-<ROCM> module per install.
MODULE_FILE="${MODULE_DIR}/afar-${FLANG_RELEASE_NUMBER}-${ROCM_NUMERIC}.lua"

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
# when this script runs as a non-root user. The modulefile shape:
#   family("GPUSDK"), ROCM_PATH, and TWO MODULEPATH prepends:
#     rocm-afar-<flang-rel>           SDK-side per-package modules
#     rocmplus-afar-<flang-rel>-<rocm-numeric>
#                                     rocmplus stack (compiler-AND-rocm-keyed
#                                     so two AFAR drops with the same SDK
#                                     numeric but different compiler releases
#                                     get separate rocmplus trees).
sudo tee "${MODULE_FILE}" >/dev/null <<EOF
whatis("Name: ROCm")
whatis("Version: afar-${FLANG_RELEASE_NUMBER}-${ROCM_NUMERIC}")
whatis("Category: AMD")
whatis("ROCm")
whatis("Set HIPCC_VERBOSE=7 to see what hipcc is doing for the compilation and link")
whatis("Source: AFAR drop ${FLANG_RELEASE_NUMBER} (build ${AFAR_NUMBER}, ROCm ${ROCM_NUMERIC} from .info/version)")
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
-- NOTE: CCC_OVERRIDE_OPTIONS deliberately NOT set (direct-amdclang pin now
-- lives in the UCC build in comm/scripts/openmpi_setup.sh) -- clang echoes
-- "### CCC_OVERRIDE_OPTIONS:" to stderr on every call and that corrupted
-- downstream configure output parsing (e.g. PETSc's HIP probe).
setenv("ROCM_PATH", base)
prepend_path("MODULEPATH", pathJoin(mbase, "rocm-afar-${FLANG_RELEASE_NUMBER}"))
prepend_path("MODULEPATH", pathJoin(mbase, "rocmplus-afar-${FLANG_RELEASE_NUMBER}-${ROCM_NUMERIC}"))
family("GPUSDK")

-- Place the rocprof-sys-run wrapper (which applies a libbfd LD_PRELOAD
-- workaround when the system libbfd is older than the one rocprof-sys
-- statically links) first in PATH. The wrapper is a no-op on systems
-- where the system libbfd is new enough.
prepend_path("PATH", pathJoin(base, "share/rocprofiler-systems/bin"))
EOF
sudo chown root:root "${MODULE_FILE}"
sudo chmod 644 "${MODULE_FILE}"

# ---------------- Phase 4b: per-package secondary modulefiles ---------
# Mirror what the regular numeric pipeline emits via deploy_module_package.sh
# (amdclang / hipfort / opencl modulefiles under the rocm-<v>/ MODULEPATH
# prepended above) so `module load rocm/afar-${FLANG_RELEASE_NUMBER}-${ROCM_NUMERIC}`
# is followed by a working `module avail amdclang|hipfort|opencl`. Each
# emission is feature-gated on the actual presence of the component in
# ${INSTALL_DIR}: AFAR drops typically ship llvm/bin/amdclang +
# include/hipfort, but not opencl/bin -- the gating keeps us from writing
# modulefiles that point at non-existent paths.
echo "============================================================"
echo "  Phase 4b: per-package modulefiles under ${TOP_MODULE_PATH}/rocm-afar-${FLANG_RELEASE_NUMBER}/"
echo "============================================================"
# shellcheck source=bare_system/leaf_modulefile_helpers.sh
source "$(dirname "${LEAF_SCRIPT_PATH}")/leaf_modulefile_helpers.sh"
emit_per_package_modulefiles \
   "${TOP_MODULE_PATH}/rocm-afar-${FLANG_RELEASE_NUMBER}" \
   "${ROCM_NUMERIC}" \
   "rocm/afar-${FLANG_RELEASE_NUMBER}-${ROCM_NUMERIC}" \
   "${INSTALL_DIR}" \
   "${LEAF_SCRIPT_NAME}" \
   "${LEAF_SCRIPT_COMMIT:0:12}" \
   "${LEAF_SCRIPT_DIRTY}"

# ---------------- Phase 6: rocm_patches.sh on the AFAR tree -----------
# Mirror Phase 3.6 of bare_system/run_rocm_build.sh:483-512 (the numeric
# branch's patch-overlay step). rocm_patches.sh's dispatch table has
# entries for afar-22.{1,2}.0 (rocprof-compute overlay); for AFAR releases
# without a registered bundle the script returns NOOP_RC=43 and we treat
# that as success.
#
# Path conventions:
#   --rocm-version    afar-${FLANG_RELEASE_NUMBER}
#                     (the dispatch key used by rocm_version_to_patches();
#                     for the AFAR-proper / TheRock-AFAR family the
#                     unified `afar-<REL>` key applies to both branches
#                     since the release-tag namespaces don't collide)
#   --rocm-path       ${INSTALL_DIR}
#                     (= ${TOP_INSTALL_PATH}/rocm-afar-${REL})
#   --install-prefix  auto-derived by rocm_patches.sh:371-379 from
#                     ${ROCM_PATH} to ${TOP_INSTALL_PATH}/rocm-patches-afar-${REL}
#                     (sibling of the SDK install)
#   --module-file     ${MODULE_FILE}  (afar-${REL}-${ROCM_NUMERIC}.lua,
#                     the unified flang-site shape; without this override
#                     rocm_patches.sh would look for
#                     ${MODULE_PATH}/rocm/afar-${REL}.lua, which does NOT
#                     exist on the AFAR side -- see the --module-file flag
#                     docstring in rocm_patches.sh)
#
# Exit codes (rocm_patches.sh):
#   0  -- patches applied (or already up to date)
#   43 -- intentional no-op (no vendored fix for this version)
#   *  -- hard error -- propagate to the EXIT trap
#
# Gated by --skip-patches (operator opt-out), mirrors the numeric
# branch's SKIP_PATCHES flag in run_rocm_build.sh:31.
if [[ "${SKIP_PATCHES}" != "1" ]]; then
   echo "============================================================"
   echo "  Phase 6: rocm_patches.sh on ${INSTALL_DIR} (-> ${PATCHES_LOG})"
   echo "============================================================"
   # rocm_patches.sh is a sibling-tree leaf (rocm/scripts/rocm_patches.sh).
   # Resolve relative to this leaf script's dir so the call works
   # regardless of $PWD.
   _patches_sh="$(dirname "${LEAF_SCRIPT_PATH}")/../rocm/scripts/rocm_patches.sh"
   if [[ ! -x "${_patches_sh}" ]]; then
      echo "[Phase 6] WARNING: rocm_patches.sh not found / not executable at ${_patches_sh}; skipping"
   else
      PATCHES_RC=0
      set +e
      "${_patches_sh}" \
            --rocm-version    "afar-${FLANG_RELEASE_NUMBER}" \
            --rocm-path       "${INSTALL_DIR}" \
            --module-path     "${TOP_MODULE_PATH}/base" \
            --module-file     "${MODULE_FILE}" \
            2>&1 | tee "${PATCHES_LOG}"
      PATCHES_RC=${PIPESTATUS[0]}
      set -e
      if [[ "${PATCHES_RC}" -eq 43 ]]; then
         echo "[Phase 6] rocm_patches.sh returned 43 (NOOP_RC) -- no vendored fix for afar-${FLANG_RELEASE_NUMBER}; treating as success"
      elif [[ "${PATCHES_RC}" -ne 0 ]]; then
         echo "ERROR: rocm_patches.sh failed for afar-${FLANG_RELEASE_NUMBER} (rc=${PATCHES_RC})" >&2
         exit "${PATCHES_RC}"
      else
         # Normalize ownership/perms on the overlay tree so it matches the
         # SDK extract (root:root, dirs 755).
         _overlay="${TOP_INSTALL_PATH}/rocm-patches-afar-${FLANG_RELEASE_NUMBER}"
         if [[ -d "${_overlay}" ]]; then
            sudo chown -R root:root "${_overlay}"
            sudo find "${_overlay}" -type d -exec chmod 755 {} +
         fi
         unset _overlay
         echo "[Phase 6] patches applied for afar-${FLANG_RELEASE_NUMBER}"
      fi
   fi
   unset _patches_sh
fi

echo ""
echo "============================================================"
echo "  Done: afar-${FLANG_RELEASE_NUMBER}-${ROCM_NUMERIC}"
echo "  Install: ${INSTALL_DIR}"
echo "  Module : ${MODULE_FILE}  (loads rocm/afar-${FLANG_RELEASE_NUMBER}-${ROCM_NUMERIC},"
echo "                            ROCM_PATH=${INSTALL_DIR})"
echo "============================================================"
