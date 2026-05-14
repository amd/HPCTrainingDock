#!/bin/bash
#
# rocm_patches.sh
# ---------------
# Apply vendored cherry-picks on top of the SDK that
# rocm/scripts/rocm_setup.sh just installed at /opt/rocm-${ROCM_VERSION}.
#
# Selective by ROCM_VERSION: every other release exits NOOP_RC=43 so the
# main_setup.sh per-package summary records "SKIPPED(no-op)" and we never
# rebuild anything we don't have to.
#
# Currently handled:
#   * ROCm 7.2.0 / 7.2.1  -- cherry-pick PR #3412 onto rocprof-sys 1.3.0
#                            and drop a patched librocprof-sys.so.1.3.0
#                            into /opt/rocm-patches-${ROCM_VERSION}/lib/.
#                            Edits the rocm/${ROCM_VERSION}.lua module
#                            file written by rocm_setup.sh so
#                            LD_LIBRARY_PATH picks the patched .so up
#                            ahead of the SDK's own copy.
#   * ROCm 7.1.0 / 7.1.1  -- five-patch stack on rocprof-sys 1.2.x
#                            (Bug A + Bug B fork-handling + B'/B''
#                            v1.3.0-shaped fixes carried back +
#                            Bug C eager-BFD-preload skip).
#                            Build is currently driven by the
#                            standalone apply_and_build.sh in the
#                            /opt/rocm-patches-${ROCM_VERSION}/ prefix
#                            (not yet wired into this script's in-tree
#                            builder). Use --module-file-only to
#                            backfill the modulefile entry once the
#                            standalone build has produced the .so.
#
# The patch text is vendored under rocm/sources/rocm-patches/ and is the
# *only* delta this script applies; everything else (clone of the
# rocm-systems monorepo at the v1.3.0 parent commit, submodule init,
# CMake configure with the ROCm-7.2.x-matching flags, install) is
# mechanical. See rocm/sources/rocm-patches/README.md and the bug
# background at /shared/apps/ubuntu/opt/rocm-patches-7.2.1/doc/.
#
# Conventions match the other rocm/scripts/*_setup.sh leaves:
#   * --rocm-version <X.Y.Z>           required (defaults shown below)
#   * --replace                        force rebuild even if already done
#   * --module-path <DIR>              base of the lmod tree
#   * --install-prefix <DIR>           where the patched .so lands
#   * --patch-source-dir <DIR>         where the vendored .patch tree lives
#   * exit 0  -- did work, or already up to date
#   * exit 43 -- intentional no-op (this ROCm version has no vendored fix)
#   * exit 1  -- real error
#
# Idempotent: re-running with the same ROCM_VERSION while the patched
# library is already in place + the module file already has the overlay
# entry + the SDK lib symlink swap is in place is a fast
# check-and-exit-0.
#
# Two post-install finishing steps the script applies after every
# successful build (and during --module-file-only backfill) are:
#
#   * fix_overlay_runpath_and_libunwind: cmake bakes absolute paths to
#     the build tree into the patched .so's DT_RUNPATH, and the
#     timemory-bundled libunwind.so.99 lives only in the build tree.
#     After the build dir is cleaned up the patched .so cannot load
#     (libunwind.so.99 missing, libgotcha.so.2 missing, etc.). The
#     fixup copies libunwind next to the patched .so and rewrites
#     DT_RUNPATH to a portable $ORIGIN-rooted form that reaches the
#     SDK's lib + rocprofiler-systems subdir.
#
#   * swap_sdk_lib_symlink: rocprof-sys-run (the SDK binary) prepends
#     ROCPROFSYS_ROOT/lib (the SDK lib) ahead of the inherited
#     LD_LIBRARY_PATH for the profiled child process. That defeats the
#     modulefile's LD_LIBRARY_PATH overlay. Making the SDK's
#     versioned librocprof-sys.so.X.Y.Z a symlink to the patched .so
#     in ${INSTALL_PREFIX}/lib/ is the canonical way to win the race:
#     wherever the loader looks (SDK lib or overlay lib), the patched
#     bits run. The original SDK file is preserved next door as
#     .orig.
#
# Backfill mode (--module-file-only):
#   Skips the build entirely and applies the three finishing steps:
#   modulefile overlay edit + fix_overlay_runpath_and_libunwind +
#   swap_sdk_lib_symlink. Use this on clusters where the patched .so
#   was produced by the standalone /opt/rocm-patches-X.Y.Z/apply_and_build.sh
#   (out-of-tree builder for the 7.1.x / 7.0.x / 6.4.x / afar-22.x
#   release lines), and the in-tree script has nothing to build but
#   still has to finish the deployment.

LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
LEAF_DIR="$(dirname "${LEAF_SCRIPT_PATH}")"

# Provenance: same pattern as the per-package `*_setup.sh` leaves
# (see kokkos_setup.sh ~L540).  Captures this script's git state so we
# can later embed a `whatis("Built by: rocm_patches.sh@<hash> (<dirty>)")`
# line in the SDK modulefile we edit.  inventory_packages.py reads
# that line to populate the `rocm_patches` provenance row.  Falls
# back to "unknown" outside a git checkout (Docker layer, release
# tarball, or git binary missing).
LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
LEAF_SCRIPT_COMMIT=unknown
LEAF_SCRIPT_DIRTY=unknown
if [ -d "${LEAF_DIR}" ] && command -v git >/dev/null 2>&1 \
   && git -C "${LEAF_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
   _commit="$(git -C "${LEAF_DIR}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
   [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"
   unset _commit
   if [ -n "$(git -C "${LEAF_DIR}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ]; then
      LEAF_SCRIPT_DIRTY=dirty
   else
      LEAF_SCRIPT_DIRTY=clean
   fi
fi

# ── defaults ────────────────────────────────────────────────────────
: ${ROCM_VERSION:=""}
REPLACE=0
MODULE_PATH=/etc/lmod/modules/ROCm
INSTALL_PREFIX=""
PATCH_SOURCE_DIR=""
MODULE_FILE_ONLY=0
ROCM_PATH_OVERRIDE=""
NOOP_RC=43
: ${ALLOW_LOGIN_NODE:=0}
ORIGINAL_ARGS=("$@")

# ── distro / sudo plumbing (matches sibling *_setup.sh) ─────────────
DISTRO=$(cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]')
DISTRO_VERSION=$(cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]')
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi
PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")

usage() {
   echo "Usage:"
   echo "  --rocm-version    [ ROCM_VERSION ]    required, e.g. 7.2.1"
   echo "  --replace                             force rebuild even if already applied"
   echo "  --module-path     [ MODULE_PATH ]     default ${MODULE_PATH}"
   echo "  --install-prefix  [ DIR ]             default /opt/rocm-patches-\${ROCM_VERSION}"
   echo "  --rocm-path       [ DIR ]             default /opt/rocm-\${ROCM_VERSION}"
   echo "                                        (the SDK install rocm_setup.sh produced;"
   echo "                                        prerequisite-existence check uses this)"
   echo "  --patch-source-dir [ DIR ]            auto-detected; vendored .patch tree"
   echo "  --module-file-only                    skip build; just apply the modulefile"
   echo "                                        LD_LIBRARY_PATH overlay edit (idempotent)."
   echo "                                        Use this to backfill the overlay entry on"
   echo "                                        a cluster where the patched .so is already"
   echo "                                        on disk but the rocm/X.Y.Z.lua modulefile"
   echo "                                        was installed before this script existed."
   echo "  --allow-login-node                    bypass the safety guard that refuses to run"
   echo "                                        the heavy nuitka build outside a Slurm"
   echo "                                        allocation (only relevant on shared head"
   echo "                                        nodes; nuitka peaks ~10 GB RSS)."
   echo "  --help"
   exit 1
}

send-error() {
   usage
   echo -e "\nError: ${@}"
   exit 1
}

reset-last() {
   last() { send-error "Unsupported argument :: ${1}"; }
}

n=0
while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--help")              usage ;;
      "--rocm-version")      shift; ROCM_VERSION=${1};       reset-last ;;
      "--replace")                  REPLACE=1;               reset-last ;;
      "--module-path")       shift; MODULE_PATH=${1};        reset-last ;;
      "--install-prefix")    shift; INSTALL_PREFIX=${1};     reset-last ;;
      "--rocm-path")         shift; ROCM_PATH_OVERRIDE=${1}; reset-last ;;
      "--patch-source-dir")  shift; PATCH_SOURCE_DIR=${1};   reset-last ;;
      "--module-file-only")         MODULE_FILE_ONLY=1;      reset-last ;;
      "--allow-login-node")         ALLOW_LOGIN_NODE=1;      reset-last ;;
      "--*")                 send-error "Unsupported argument at position $((${n}+1)) :: ${1}" ;;
      *)                     last ${1} ;;
   esac
   n=$((${n}+1))
   shift
done

[ -n "${ROCM_VERSION}" ] || send-error "--rocm-version is required"

# ── safety guard: don't nuke the login node ─────────────────────────
# The rocprof-compute nuitka onefile build peaks ~10 GB RSS and pegs
# one core at 100% for ~45 min on the 7.2.x line. Running that on a
# shared login/head node degrades interactive responsiveness for
# everyone else, and on memory-constrained head nodes it gets OOM-
# killed. Refuse to run if we don't appear to be in a Slurm
# allocation or a container. --module-file-only is light (no nuitka),
# so it bypasses the guard. --allow-login-node (or ALLOW_LOGIN_NODE=1
# env) is the explicit override for the rare cases where you really
# do want to run on the current host (e.g., a private workstation, a
# one-off recovery on a quiet cluster).
if [ "${MODULE_FILE_ONLY}" -eq 0 ] \
   && [ "${ALLOW_LOGIN_NODE}" -eq 0 ] \
   && [ -z "${SLURM_JOB_ID:-}" ] \
   && [ ! -f /.dockerenv ] \
   && [ ! -f /.singularity.d/Singularity ]; then
   _host="$(hostname -s 2>/dev/null || hostname)"
   echo "[rocm_patches] REFUSING to run on '${_host}': not inside a Slurm allocation or container." >&2
   echo "[rocm_patches]   The rocprof-compute nuitka build peaks ~10 GB RSS and pegs a CPU for ~45 min." >&2
   echo "[rocm_patches]   Running it on a shared head/login node would degrade other users' sessions" >&2
   echo "[rocm_patches]   and may get OOM-killed." >&2
   echo "" >&2
   echo "[rocm_patches]   Wrap your invocation in sbatch, e.g.:" >&2
   echo "" >&2
   echo "     sbatch -p sh5_cpx_a -N 1 -J rocm-patches-${ROCM_VERSION} -t 90 \\" >&2
   echo "       -o slurm-%j-rocm-patches-${ROCM_VERSION}.out \\" >&2
   echo "       --wrap=\"sudo -E bash ${LEAF_SCRIPT_PATH} ${ORIGINAL_ARGS[*]}\"" >&2
   echo "" >&2
   echo "[rocm_patches]   ...or pass --allow-login-node (or set ALLOW_LOGIN_NODE=1) to bypass." >&2
   exit 1
fi
unset _host

# ── version → patch-bundle dispatch ─────────────────────────────────
# Centralised here so adding new vendored fixes is a one-line edit.
# Echoes a space-separated list of <component>/<version> directory
# names under sources/rocm-patches/. Empty output ⇒ no-op.
rocm_version_to_patches() {
   local v="$1"
   case "$v" in
      # rocprof-sys cherry-picks: only the v1.3.0 source line is currently
      # handled in-tree (rocm-7.2.x). The 6.4.x / 7.0.x / 7.1.x rocprof-sys
      # overlays are still built out-of-tree via the per-version
      # apply_and_build.sh in /opt/rocm-patches-X.Y.Z/. The afar-22.{1,2}.0
      # rocprof-sys overlays follow the same out-of-tree pattern
      # (apply_and_build.sh pinned to upstream tag rocm-7.1.0 = v1.2.0
      # source baseline matching the afar-22.x .deb's librocprof-sys.so.1.2.0);
      # use rocm_patches.sh --module-file-only --rocm-version afar-22.X.0
      # to backfill the modulefile entry after the standalone build.
      #
      # rocprof-compute overlay (see rocprof-compute/ bundle): produces a
      # nuitka onefile of upstream rocprofiler-compute, drops it under
      # /opt/rocm-patches-${ROCM_VERSION}/rocprof-compute/, and adds a
      # prepend_path("PATH", ...) line to the modulefile so the overlay
      # shadows the in-distribution Python wrapper / .exe.  This is the
      # SOLE source of a working `rocprof-compute` on every supported
      # ROCm release -- 6.3.x through 7.2.x for official releases, plus
      # afar-22.{1,2}.0 and therock-23.{1,2}.0 on the RC side.  Prior
      # to 2026-05 the nuitka build for 7.1.0+ lived inline in
      # rocm/scripts/rocm_setup.sh; it has been moved here so the
      # build, install wiring, and provenance whatis() line are all
      # produced by a single script.  (See companion edit in
      # rocm_setup.sh: the >=7.1.0 nuitka THEN-branch is now a no-op
      # comment that defers to this overlay.)
      #
      # On the 7.2.x line two bundles run back-to-back: the rocprof-sys
      # cherry-pick (for 7.2.0 / 7.2.1 / 7.2.2 / 7.2.3 -- all four ship
      # rocprof-sys 1.3.0 from the same source baseline) PLUS the
      # rocprof-compute overlay.  build_rocprof_compute() is invoked
      # after build_rocprof_sys_1_3_0() because the dispatch iterates
      # PATCH_BUNDLES in order.
      #
      # Empirical NOTE (2026-05): for the RC trees afar-22.{1,2}.0 and
      # therock-23.{1,2}.0, the VERSION.sha on disk does NOT resolve to
      # a public commit on github.com/ROCm/rocprofiler-compute -- the
      # RC .debs are built from internal AMD branches.  build.sh's
      # RC-mode catches this in `git rev-parse --verify` and returns
      # exit 43 (soft no-op).  We still LIST the trees here so that
      # any future RC .deb whose VERSION.sha gets pushed upstream
      # gets the overlay automatically; right now no overlay is
      # actually produced for those RC trees.
      7.2.0)            echo "rocprof-sys-1.3.0 rocprof-compute" ;;
      7.2.1)            echo "rocprof-sys-1.3.0 rocprof-compute" ;;
      # 7.2.2: the 4 vendored rocprof-sys 1.3.0 patches apply cleanly to
      # the rocm-7.2.2 source tag (same projects/rocprofiler-systems
      # VERSION 1.3.0 baseline as 7.2.0 / 7.2.1).  Verified by running
      # the in-tree builder against /shared/apps/ubuntu/opt/rocm-7.2.2
      # on the AAC6 Ubuntu 22.04 hosts (rocprof-sys SIGSEGV regression
      # reproducer in MPI_Ghost_Exchange_Ver2_Rocprof-Sys passes
      # post-overlay; see slurm-9046).
      7.2.2)            echo "rocprof-sys-1.3.0 rocprof-compute" ;;
      # 7.2.3: same source baseline as 7.2.0 / 7.2.1 / 7.2.2 (rocm-systems
      # tag rocm-7.2.3 ships projects/rocprofiler-systems VERSION 1.3.0
      # and all 4 patches apply cleanly).  An earlier 7.2.3 build of the
      # ROCm SDK required GLIBC >= 2.36 / GLIBCXX >= 3.4.32 and was
      # blocked on Ubuntu 22.04 hosts (GLIBC 2.35 / GLIBCXX 3.4.30); the
      # current 7.2.3 install rebuilt against the older glibc, so
      # amdclang and the SDK both load cleanly and the in-tree builder
      # produces a working librocprof-sys.so.1.3.0 against rocm-7.2.3's
      # rocprofiler-sdk 1.1.0.
      7.2.3)            echo "rocprof-sys-1.3.0 rocprof-compute" ;;
      6.3.*)            echo "rocprof-compute" ;;
      6.4.*)            echo "rocprof-compute" ;;
      7.0.*)            echo "rocprof-compute" ;;
      7.1.*)            echo "rocprof-compute" ;;
      afar-22.1.0)      echo "rocprof-compute" ;;
      afar-22.2.0)      echo "rocprof-compute" ;;
      therock-23.1.0)   echo "rocprof-compute" ;;
      therock-23.2.0)   echo "rocprof-compute" ;;
      *)                echo "" ;;
   esac
}

PATCH_BUNDLES="$(rocm_version_to_patches "${ROCM_VERSION}")"

# ── locate the vendored .patch tree ─────────────────────────────────
# Two layouts to support:
#   (a) repo layout:   <repo>/rocm/scripts/rocm_patches.sh +
#                      <repo>/rocm/sources/rocm-patches/
#   (b) Docker layout: /tmp/rocm/rocm_patches.sh +
#                      /tmp/rocm/sources/rocm-patches/  (we COPY both)
# If --patch-source-dir was passed, we trust it. Empty in
# --module-file-only mode is fine (we don't read patches).
if [ -z "${PATCH_SOURCE_DIR}" ]; then
   for cand in \
      "${LEAF_DIR}/../sources/rocm-patches" \
      "${LEAF_DIR}/sources/rocm-patches"; do
      if [ -d "${cand}" ]; then
         PATCH_SOURCE_DIR="$(cd "${cand}" && pwd -P)"
         break
      fi
   done
fi

# ── derived paths ───────────────────────────────────────────────────
# Set unconditionally so --module-file-only mode (which never reads
# PATCH_BUNDLES or PATCH_SOURCE_DIR) can still resolve INSTALL_PREFIX
# and MODULE_FILE for the modulefile edit.
INSTALL_PREFIX_EXPLICIT=1
[ -n "${INSTALL_PREFIX}" ] || { INSTALL_PREFIX="/opt/rocm-patches-${ROCM_VERSION}"; INSTALL_PREFIX_EXPLICIT=0; }
if [ -n "${ROCM_PATH_OVERRIDE}" ]; then
   ROCM_PATH="${ROCM_PATH_OVERRIDE}"
else
   ROCM_PATH="/opt/rocm-${ROCM_VERSION}"
fi

# When the caller passed --rocm-path pointing at a non-default
# location (e.g. /shared/apps/ubuntu/opt/rocm-7.2.3 from main_setup.sh's
# rocmplus branch) but did NOT pass --install-prefix, keep the two
# paths SYNCHRONIZED by deriving INSTALL_PREFIX from ROCM_PATH. By
# convention rocm-${V} and rocm-patches-${V} are siblings in the
# same parent dir, so the SDK install and its patches overlay always
# live together. Without this, INSTALL_PREFIX would stay at the
# /opt/rocm-patches-${V} default and the idempotency check below
# would look at the wrong location, triggering a wasteful rebuild
# (slurm jobs 9000/9001, 2026-05-11).
if [ "${INSTALL_PREFIX_EXPLICIT}" -eq 0 ] \
   && [ -n "${ROCM_PATH_OVERRIDE}" ] \
   && [ "${ROCM_PATH}" != "/opt/rocm-${ROCM_VERSION}" ]; then
   _derived="$(dirname "${ROCM_PATH}")/rocm-patches-${ROCM_VERSION}"
   echo "[rocm_patches] auto-derived INSTALL_PREFIX from ROCM_PATH: ${_derived}"
   echo "[rocm_patches]   (sibling of ${ROCM_PATH}; pass --install-prefix to override)"
   INSTALL_PREFIX="${_derived}"
   unset _derived
fi

MODULE_FILE="${MODULE_PATH}/rocm/${ROCM_VERSION}.lua"

echo ""
echo "=================================="
echo "Starting ROCm patch overlay install"
echo "  DISTRO            : $DISTRO"
echo "  DISTRO_VERSION    : $DISTRO_VERSION"
echo "  ROCM_VERSION      : $ROCM_VERSION"
echo "  ROCM_PATH         : $ROCM_PATH"
echo "  INSTALL_PREFIX    : $INSTALL_PREFIX"
echo "  MODULE_FILE       : $MODULE_FILE"
echo "  PATCH_SOURCE_DIR  : $PATCH_SOURCE_DIR"
echo "  PATCH_BUNDLES     : $PATCH_BUNDLES"
echo "  REPLACE           : $REPLACE"
echo "  MODULE_FILE_ONLY  : $MODULE_FILE_ONLY"
echo "=================================="
echo ""

# ── prerequisite: rocm_setup.sh actually installed something ────────
# If /opt/rocm-${ROCM_VERSION} doesn't exist we have nothing to overlay
# (rocm_setup.sh either was deselected or failed). Bail cleanly so the
# patch step doesn't masquerade as a real failure. Skipped under
# --module-file-only (backfill mode does not touch the SDK install).
if [ "${MODULE_FILE_ONLY}" -eq 0 ] && [ ! -d "${ROCM_PATH}" ]; then
   echo "[rocm_patches] ${ROCM_PATH} does not exist -- rocm_setup.sh must run first; skipping (no-op)"
   exit ${NOOP_RC}
fi

# ── prerequisite: in build mode, we need a registered bundle and a
#    patch source tree.  In --module-file-only mode, neither is
#    required (we are just editing the modulefile to point at an
#    existing overlay that was built out-of-tree, e.g. via the
#    standalone apply_and_build.sh on the rocm-patches-X.Y.Z prefix
#    for ROCm releases that the in-tree builder does not yet handle
#    -- currently 7.1.0 and 7.1.1, where the rocprof-sys 1.2.1 source
#    line needs all five vendored patches and the build is driven by
#    rocm-patches-7.1.{0,1}/apply_and_build.sh).
if [ "${MODULE_FILE_ONLY}" -eq 0 ]; then
   if [ -z "${PATCH_BUNDLES}" ]; then
      echo "[rocm_patches] no vendored patches needed for ROCm ${ROCM_VERSION} -- skipping (no-op)"
      exit ${NOOP_RC}
   fi
   [ -d "${PATCH_SOURCE_DIR}" ] || send-error "patch source dir not found (looked next to ${LEAF_DIR})"
fi

# ── Strengthened idempotency check ──────────────────────────────────
# Short-circuit the WHOLE script with NOOP_RC when every bundle in
# PATCH_BUNDLES has all its on-disk artifacts AND a matching modulefile
# entry already in place, and the caller did not request --replace.
# This complements the per-bundle skip-if-output-exists checks inside
# the build_* functions (which only catch "binary present at the
# CURRENT INSTALL_PREFIX") by ALSO requiring the modulefile to
# already reference the overlay -- so a stale install dir with no
# wired-up modulefile still triggers a rebuild.
#
# Robustness:
#   * INSTALL_PREFIX is auto-synchronized to ROCM_PATH above, so the
#     install-dir check looks at the right location even when the
#     caller only passed --rocm-path (main_setup.sh's rocmplus
#     branch). An explicit --install-prefix overrides the auto.
#   * The modulefile lookup scans a list of candidate locations
#     (explicit MODULE_PATH + cluster fall-backs) so a modulefile
#     written to a non-default tree (e.g. /shared/apps/modules/...)
#     is still found when the caller left MODULE_PATH at the
#     /etc/lmod/modules/ROCm script default.
#   * --module-file-only never short-circuits; that mode IS the
#     modulefile-only work, by definition.
#   * --replace forces a rebuild unconditionally.
#
# Per-bundle artifact + modulefile-line matchers live in the case
# inside the function. Unknown bundle name -> conservative "force
# rebuild" (return 1) so adding new bundles cannot silently regress
# the idempotency check.
already_installed_check() {
   [ "${MODULE_FILE_ONLY}" -eq 0 ] || return 1
   [ "${REPLACE}" -eq 0 ]          || return 1
   [ -d "${INSTALL_PREFIX}" ]      || return 1

   local -a mf_candidates=(
      "${MODULE_PATH}/rocm/${ROCM_VERSION}.lua"
      "${MODULE_PATH}/rocm/${ROCM_VERSION}"
      "/shared/apps/modules/ubuntu/lmodfiles/base/rocm/${ROCM_VERSION}.lua"
      "/nfsapps/modules/base/rocm/${ROCM_VERSION}.lua"
      "/etc/lmod/modules/ROCm/rocm/${ROCM_VERSION}.lua"
   )
   local mf=""
   for cand in "${mf_candidates[@]}"; do
      if [ -f "${cand}" ]; then mf="${cand}"; break; fi
   done
   [ -n "${mf}" ] || return 1

   local bundle bin lib
   for bundle in ${PATCH_BUNDLES}; do
      case "${bundle}" in
         rocprof-compute)
            bin="${INSTALL_PREFIX}/rocprof-compute/bin/rocprof-compute"
            [ -e "${bin}" ] || return 1
            [ -x "${bin}" ] || return 1
            grep -qE 'prepend_path\(\s*"PATH"\s*,\s*"[^"]+/rocprof-compute/bin"\s*\)' "${mf}" \
               || return 1
            ;;
         rocprof-sys-1.3.0)
            lib="${INSTALL_PREFIX}/lib/librocprof-sys.so.1.3.0"
            [ -f "${lib}" ] || return 1
            grep -qE "rocm-patches-${ROCM_VERSION}/lib" "${mf}" \
               || return 1
            ;;
         *)
            return 1
            ;;
      esac
   done

   echo "[rocm_patches] all bundles already installed for ROCm ${ROCM_VERSION}:"
   echo "[rocm_patches]   install dir : ${INSTALL_PREFIX}"
   echo "[rocm_patches]   modulefile  : ${mf}"
   echo "[rocm_patches]   bundles     : ${PATCH_BUNDLES}"
   echo "[rocm_patches] skipping rebuild (use --replace to force)"
   return 0
}

if already_installed_check; then
   exit ${NOOP_RC}
fi

# ─────────────────────────────────────────────────────────────────────
# build_rocprof_sys_1_3_0
# -----------------------
# Cherry-picks PR #3412 (just the 6-line crash fix) onto the v1.3.0
# parent commit, builds librocprof-sys.so.1.3.0 with flags that match
# the ROCm 7.2.x ship build, installs it into ${INSTALL_PREFIX}/lib.
# ─────────────────────────────────────────────────────────────────────
build_rocprof_sys_1_3_0() {
   local bundle_dir="${PATCH_SOURCE_DIR}/rocprof-sys-1.3.0"
   local out_lib="${INSTALL_PREFIX}/lib/librocprof-sys.so.1.3.0"

   [ -d "${bundle_dir}" ] || send-error "patch bundle missing: ${bundle_dir}"

   # Idempotency: skip the slow build if the patched library is already
   # in place and --replace was not requested.
   if [ -f "${out_lib}" ] && [ "${REPLACE}" -eq 0 ]; then
      echo "[rocm_patches] ${out_lib} already exists -- skipping rebuild (use --replace to force)"
      return 0
   fi

   # Source-of-truth pin. ROCm/rocm-systems publishes per-release tags
   # whose `projects/rocprofiler-systems/VERSION` matches the .so
   # version that the SDK installs:
   #     rocm-7.2.0, rocm-7.2.1   -> rocprof-sys VERSION 1.3.0
   # Building from this tag (vs the develop branch where v1.5.0+
   # refactored sdk_tool_configure and bumped the SONAME to 1.6.0)
   # is what makes our .so an ABI-compatible drop-in for the SDK's
   # librocprof-sys.so.1.3.0.
   local repo="https://github.com/ROCm/rocm-systems.git"
   local base_commit="rocm-${ROCM_VERSION}"

   # Where we do the heavy lifting. Use a stable path under
   # ${INSTALL_PREFIX} so re-runs reuse the clone.
   local src_root="${INSTALL_PREFIX}/source/rocm-systems"
   local build_dir="${INSTALL_PREFIX}/build/rocprofiler-systems"
   local lib_dir="${INSTALL_PREFIX}/lib"

   ${SUDO} mkdir -p "${INSTALL_PREFIX}" "$(dirname "${src_root}")" "${build_dir}" "${lib_dir}"
   # The build itself runs unprivileged in ${INSTALL_PREFIX}; chown so
   # subsequent tooling (cmake, git) can write without sudo. (On a
   # Docker layer EUID is 0 so this is a no-op.)
   if [ "${EUID:-$(id -u)}" -ne 0 ]; then
      ${SUDO} chown -R "$(id -u):$(id -g)" "${INSTALL_PREFIX}" || true
   fi

   # ── build deps ───────────────────────────────────────────────────
   if [ "${DISTRO}" = "ubuntu" ]; then
      ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
         build-essential cmake git ca-certificates pkg-config \
         libelf-dev libdw-dev libdrm-dev libnuma-dev libsqlite3-dev \
         zlib1g-dev libzstd-dev libssl-dev || true
   fi

   # ── clone (resumable) ────────────────────────────────────────────
   if [ ! -d "${src_root}/.git" ]; then
      echo "[rocm_patches] cloning ${repo} (large; ~5-10 min) ..."
      git clone --filter=blob:none --no-checkout "${repo}" "${src_root}"
   fi
   (
      cd "${src_root}"
      echo "[rocm_patches] fetching tag ${base_commit} ..."
      git fetch --depth=1 origin "refs/tags/${base_commit}:refs/tags/${base_commit}"
      echo "[rocm_patches] checking out tag ${base_commit} ..."
      git -c advice.detachedHead=false checkout "tags/${base_commit}"
      echo "[rocm_patches] sparse-checkout projects/rocprofiler-systems ..."
      git sparse-checkout init --cone
      git sparse-checkout set projects/rocprofiler-systems
      echo "[rocm_patches] initialising submodules ..."
      git submodule update --init --recursive --depth 1 \
         -- projects/rocprofiler-systems

      # ── apply vendored patches ────────────────────────────────────
      for p in "${bundle_dir}"/*.patch; do
         echo "[rocm_patches] applying $(basename "$p") ..."
         if git apply --check "$p" 2>/dev/null; then
            git apply "$p"
         elif git apply --check -R "$p" 2>/dev/null; then
            echo "[rocm_patches]   (already applied; skipping)"
         else
            echo "[rocm_patches] ERROR: patch failed to apply: $p" >&2
            exit 1
         fi
      done
   ) || return 1

   # ── pre-fetch timemory's binutils-2.42 tarball ───────────────────
   # ExternalProject_Add has no retry loop; a single mid-stream RST
   # against the gnu.org mirrors aborts a 30+ minute build. We curl
   # the tarball ourselves with --retry across several mirrors, then
   # point timemory at the local file:// URL via the cmake flag below.
   local tarball_dir="${INSTALL_PREFIX}/source/tarballs"
   local binutils_tar="${tarball_dir}/binutils-2.42.tar.gz"
   local binutils_sha="5d2a6c1d49686a557869caae08b6c2e83699775efd27505e01b2f4db1a024ffc"
   mkdir -p "${tarball_dir}"
   if [ -f "${binutils_tar}" ] \
      && echo "${binutils_sha}  ${binutils_tar}" | sha256sum -c - >/dev/null 2>&1; then
      echo "[rocm_patches] binutils-2.42 tarball already cached at ${binutils_tar}"
   else
      rm -f "${binutils_tar}"
      echo "[rocm_patches] pre-fetching binutils-2.42.tar.gz (retry across mirrors) ..."
      local urls=(
         "https://ftp.gnu.org/gnu/binutils/binutils-2.42.tar.gz"
         "http://ftpmirror.gnu.org/gnu/binutils/binutils-2.42.tar.gz"
         "http://mirrors.kernel.org/sourceware/binutils/releases/binutils-2.42.tar.gz"
         "https://sourceware.org/pub/binutils/releases/binutils-2.42.tar.gz"
      )
      local got=0 url
      for url in "${urls[@]}"; do
         echo "[rocm_patches]   trying $url"
         if curl --fail --location --silent --show-error \
                 --retry 8 --retry-delay 5 --retry-all-errors \
                 --connect-timeout 30 --max-time 1200 \
                 -o "${binutils_tar}" "$url"; then
            if echo "${binutils_sha}  ${binutils_tar}" | sha256sum -c - >/dev/null 2>&1; then
               echo "[rocm_patches]   ok ($(stat -c%s "${binutils_tar}") bytes, sha256 verified)"
               got=1; break
            else
               echo "[rocm_patches]   sha256 mismatch from $url"
               rm -f "${binutils_tar}"
            fi
         else
            echo "[rocm_patches]   curl failed for $url"
            rm -f "${binutils_tar}"
         fi
      done
      [ "${got}" -eq 1 ] || { echo "[rocm_patches] ERROR: could not fetch binutils-2.42.tar.gz" >&2; return 1; }
   fi

   # ── rewrite timemory ConfigBinutils.cmake to use local tarball ───
   # CMake 3.31 ExternalProject_Add rejects URL lists that mix paths
   # (file:// or absolute) with http(s) URLs -- "At least one entry of
   # URL is a path (invalid in a list)". The upstream template
   # hardcodes two gnu.org mirrors next to the optional
   # TIMEMORY_BINUTILS_DOWNLOAD_URL, so we cannot inject our cached
   # tarball through that variable on this CMake version. Collapse
   # the URL list to a single absolute-path entry pointing at the
   # cluster-cached tarball; CMake accepts a sole-path entry, and as
   # a side-effect this guarantees the build never reaches gnu.org or
   # sourceware.org at all (so the next 30-minute build is immune to
   # mirror DDoS / mid-stream RST drops).
   local cfg_file="${src_root}/projects/rocprofiler-systems/external/timemory/cmake/Modules/ConfigBinutils.cmake"
   [ -f "${cfg_file}" ] || { echo "[rocm_patches] ERROR: expected ${cfg_file}" >&2; return 1; }
   if ! grep -Fq "rocm-patches-localurl" "${cfg_file}"; then
      echo "[rocm_patches] rewriting ConfigBinutils.cmake to use local binutils-2.42 tarball ..."
      python3 - "${cfg_file}" "${binutils_tar}" <<'PY' || return 1
import re, sys, pathlib
cfg, tarball = sys.argv[1], sys.argv[2]
text = pathlib.Path(cfg).read_text()
new_url = (
    "    # rocm-patches-localurl: collapsed URL list to the cluster-cached tarball.\n"
    "    # CMake 3.31 ExternalProject_Add rejects mixed path+url URL lists.\n"
    f"    URL {tarball}\n"
)
text2 = re.sub(
    r"    URL \$\{TIMEMORY_BINUTILS_DOWNLOAD_URL\}\n"
    r"        http://ftpmirror\.gnu\.org/gnu/binutils/binutils-2\.42\.tar\.gz\n"
    r"        http://mirrors\.kernel\.org/sourceware/binutils/releases/binutils-2\.42\.tar\.gz\n",
    new_url, text, count=1)
if text == text2:
    sys.exit("could not locate the URL block in ConfigBinutils.cmake; upstream layout drifted")
pathlib.Path(cfg).write_text(text2)
PY
   fi

   # ── workaround upstream FindTBB.cmake bug in v1.3.0 ──────────────
   # The FindTBB.cmake shipped in rocprofiler-systems v1.3.0 only
   # checks $TBB_INCLUDE_DIRS/{tbb/tbb_stddef.h,tbb/version.h}. On
   # Ubuntu 22.04 (libtbb-dev = TBB 2021.5) the version macros live
   # in $TBB_INCLUDE_DIRS/oneapi/tbb/version.h; tbb/version.h is a
   # redirect wrapper with no macros, so the regex extraction leaves
   # TBB_VERSION_MAJOR set to the full text of the wrapper file and
   # find_package then fails:
   #     Could NOT find TBB: Found unsuitable version "/* Copyright .../
   # Upstream fixed this on develop but the fix did not land in the
   # rocm-7.2.x release line. Append the oneapi path so the foreach
   # (LAST-existing-wins) picks it on systems where it exists and
   # falls back to the original behaviour everywhere else.
   local ftbb_file="${src_root}/projects/rocprofiler-systems/cmake/Modules/FindTBB.cmake"
   [ -f "${ftbb_file}" ] || { echo "[rocm_patches] ERROR: expected ${ftbb_file}" >&2; return 1; }
   if ! grep -Fq "rocm-patches-oneapi-fallback" "${ftbb_file}"; then
      echo "[rocm_patches] rewriting FindTBB.cmake to handle Ubuntu 22.04 oneapi/tbb layout ..."
      python3 - "${ftbb_file}" <<'PY' || return 1
import sys, pathlib
f = sys.argv[1]
text = pathlib.Path(f).read_text()
old = (
    "    set(_version_files\n"
    "        \"${TBB_INCLUDE_DIRS}/tbb/tbb_stddef.h\"\n"
    "        \"${TBB_INCLUDE_DIRS}/tbb/version.h\"\n"
    "    )\n"
)
new = (
    "    # rocm-patches-oneapi-fallback: Ubuntu 22.04 libtbb-dev puts the\n"
    "    # version macros in oneapi/tbb/version.h; tbb/version.h there is\n"
    "    # a redirect wrapper. Append the oneapi path -- the foreach below\n"
    "    # keeps the LAST existing entry, so on systems where both exist\n"
    "    # the working file wins. Untouched on systems without oneapi/.\n"
    "    set(_version_files\n"
    "        \"${TBB_INCLUDE_DIRS}/tbb/tbb_stddef.h\"\n"
    "        \"${TBB_INCLUDE_DIRS}/tbb/version.h\"\n"
    "        \"${TBB_INCLUDE_DIRS}/oneapi/tbb/version.h\"\n"
    "    )\n"
)
if old not in text:
    sys.exit("could not locate the _version_files block in FindTBB.cmake; upstream layout drifted")
pathlib.Path(f).write_text(text.replace(old, new, 1))
PY
   fi

   # ── workaround upstream DyninstBoost.cmake bug in v1.3.0 ─────────
   # When BUILD_BOOST=OFF and find_package(Boost) succeeds (the
   # common case on Ubuntu 22.04 with libboost-all-dev = 1.74.0),
   # DyninstBoost.cmake early-returns BEFORE the
   #     add_library(Dyninst::Boost_headers INTERFACE IMPORTED)
   # call near EOF, leaving external/dyninst's CMakeLists.txt
   # referencing a non-existent target. Result: CMake Generate fails
   # with "Target dynElf links to: Dyninst::Boost_headers but the
   # target was not found." Fixed on develop, not in the rocm-7.2.x
   # line -- inject the target creation into the Boost_FOUND
   # early-return path. Idempotent.
   # ── workaround upstream timemory libunwind include-order bug ─────
   # timemory builds its own libunwind (ExternalProject) into
   #   build/.../external/timemory/external/libunwind/install/include/
   # and exposes it via
   #   target_include_directories(timemory-libunwind SYSTEM INTERFACE ...).
   # But amdclang implicitly adds /opt/rocm-7.2.1/llvm/include as a
   # SYSTEM include, which contains LLVM's libunwind.h -- it lacks
   # `unw_strerror`, `unw_frame_regnum_t`, and other GNU-libunwind-
   # only identifiers timemory relies on, so the build fails with
   #   timemory/unwind/entry.hpp: error: use of undeclared identifier 'unw_strerror'
   #   timemory/unwind/stack.hpp: error: unknown type name 'unw_frame_regnum_t'
   # Add the BEFORE keyword so the bundled libunwind path is PREPENDED
   # (it wins over amdclang's implicit /opt/rocm-/llvm/include).
   local tpkg_file="${src_root}/projects/rocprofiler-systems/external/timemory/cmake/Modules/Packages.cmake"
   [ -f "${tpkg_file}" ] || { echo "[rocm_patches] ERROR: expected ${tpkg_file}" >&2; return 1; }
   if ! grep -Fq "rocm-patches-libunwind-before" "${tpkg_file}"; then
      echo "[rocm_patches] rewriting timemory Packages.cmake to prepend bundled libunwind include path ..."
      python3 - "${tpkg_file}" <<'PY' || return 1
import sys, pathlib
f = sys.argv[1]
text = pathlib.Path(f).read_text()
old = (
    "        target_include_directories(timemory-libunwind SYSTEM\n"
    "                                   INTERFACE ${libunwind_INCLUDE_DIRS})\n"
)
new = (
    "        # rocm-patches-libunwind-before: prepend (BEFORE) so the\n"
    "        # bundled timemory libunwind include path beats amdclang's\n"
    "        # implicit -isystem /opt/rocm-/llvm/include (LLVM libunwind\n"
    "        # which lacks unw_strerror / unw_frame_regnum_t etc.).\n"
    "        target_include_directories(timemory-libunwind BEFORE SYSTEM\n"
    "                                   INTERFACE ${libunwind_INCLUDE_DIRS})\n"
)
if old not in text:
    sys.exit("could not locate the timemory-libunwind include block; upstream layout drifted")
pathlib.Path(f).write_text(text.replace(old, new, 1))
PY
   fi

   local dboost_file="${src_root}/projects/rocprofiler-systems/cmake/DyninstBoost.cmake"
   [ -f "${dboost_file}" ] || { echo "[rocm_patches] ERROR: expected ${dboost_file}" >&2; return 1; }
   if ! grep -Fq "rocm-patches-boost-headers-import" "${dboost_file}"; then
      echo "[rocm_patches] rewriting DyninstBoost.cmake to create Dyninst::Boost{_headers} in the Boost_FOUND path ..."
      python3 - "${dboost_file}" <<'PY' || return 1
import sys, pathlib
f = sys.argv[1]
text = pathlib.Path(f).read_text()
old = (
    "if(NOT BUILD_BOOST)\n"
    "    find_package(Boost)\n"
    "endif()\n"
    "\n"
    "if(Boost_FOUND)\n"
    "    return()\n"
    "endif()\n"
)
new = (
    "if(NOT BUILD_BOOST)\n"
    "    find_package(Boost)\n"
    "endif()\n"
    "\n"
    "if(Boost_FOUND)\n"
    "    # rocm-patches-boost-headers-import: in v1.3.0, BOTH\n"
    "    # add_library(Dyninst::Boost_headers ...) and the linkable\n"
    "    # Dyninst::Boost target are unreachable on the Boost_FOUND\n"
    "    # early-return path. external/dyninst/common/CMakeLists.txt\n"
    "    # declares  PUBLIC_DEPS Dyninst::TBB Dyninst::Boost  -- without\n"
    "    # the linkable target, the libcommon.so link fails with undefined\n"
    "    # boost::filesystem / boost::thread / boost::system symbols.\n"
    "    # Mirror what external/dyninst/cmake/tpls/DyninstBoost.cmake does:\n"
    "    # find Boost with the linkable components dyninst needs, then\n"
    "    # create both IMPORTED targets explicitly.\n"
    "    find_package(\n"
    "        Boost\n"
    "        QUIET\n"
    "        REQUIRED\n"
    "        COMPONENTS atomic chrono date_time filesystem thread timer system\n"
    "    )\n"
    "    if(NOT TARGET Dyninst::Boost)\n"
    "        add_library(Dyninst::Boost INTERFACE IMPORTED)\n"
    "        target_link_libraries(Dyninst::Boost INTERFACE ${Boost_LIBRARIES})\n"
    "        target_include_directories(\n"
    "            Dyninst::Boost\n"
    "            SYSTEM\n"
    "            INTERFACE ${Boost_INCLUDE_DIRS}\n"
    "        )\n"
    "        target_compile_definitions(\n"
    "            Dyninst::Boost\n"
    "            INTERFACE BOOST_MULTI_INDEX_DISABLE_SERIALIZATION\n"
    "        )\n"
    "    endif()\n"
    "    if(NOT TARGET Dyninst::Boost_headers)\n"
    "        add_library(Dyninst::Boost_headers INTERFACE IMPORTED)\n"
    "        target_include_directories(\n"
    "            Dyninst::Boost_headers\n"
    "            SYSTEM\n"
    "            INTERFACE ${Boost_INCLUDE_DIRS}\n"
    "        )\n"
    "        target_compile_definitions(\n"
    "            Dyninst::Boost_headers\n"
    "            INTERFACE BOOST_MULTI_INDEX_DISABLE_SERIALIZATION\n"
    "        )\n"
    "    endif()\n"
    "    return()\n"
    "endif()\n"
)
if old not in text:
    sys.exit("could not locate the Boost_FOUND early-return block; upstream layout drifted")
pathlib.Path(f).write_text(text.replace(old, new, 1))
PY
   fi

   # ── scrub /llvm/include from CPATH ───────────────────────────────
   # `module load amdclang` prepends $ROCM_PATH/llvm/include to CPATH,
   # and clang processes CPATH entries BEFORE -isystem flags from
   # cmake. That means LLVM's libunwind.h (in $ROCM_PATH/llvm/include)
   # wins over timemory's bundled GNU libunwind, and the build fails
   # with `unw_strerror` / `unw_frame_regnum_t` undeclared in
   # timemory/unwind/{entry,stack}.hpp. Drop the offending entry; the
   # rocm-7.2.1/include base path stays so HSA / HIP / rocprofiler-sdk
   # headers still resolve.
   if [ -n "${CPATH:-}" ]; then
      local _new_cpath
      _new_cpath=$(printf '%s\n' "${CPATH}" | tr ':' '\n' | grep -v '/llvm/include$' | paste -sd: -)
      if [ "${_new_cpath}" != "${CPATH}" ]; then
         echo "[rocm_patches] scrubbing /llvm/include from CPATH (LLVM libunwind shadows bundled GNU libunwind)"
         echo "[rocm_patches]   was: ${CPATH}"
         echo "[rocm_patches]   now: ${_new_cpath}"
         export CPATH="${_new_cpath}"
      fi
   fi

   # ── configure & build ────────────────────────────────────────────
   # Mirrors the ROCm 7.2.x ship build to the extent we can verify
   # without an SRPM:
   #   * RelWithDebInfo / shared libs (matches SONAME = librocprof-sys.so.1)
   #   * rocprofiler-sdk + OMPT enabled (this is the whole point)
   #   * timemory's binutils-2.42 tarball is pre-fetched (with retries
   #     across multiple mirrors) into ${INSTALL_PREFIX}/source/tarballs
   #     before CMake runs, and TIMEMORY_BINUTILS_DOWNLOAD_URL is
   #     pointed at the local file:// URL. ExternalProject_Add has no
   #     retry loop, so a single mid-stream RST or redirect-target 5xx
   #     blows away a 30+ minute build; pre-fetching shifts that
   #     transient-failure surface to a place we can retry properly.
   #   * Dyninst built from the vendored submodule (BUILD_DYNINST=ON).
   #     The flag does NOT mean "skip Dyninst" -- the project does
   #     find_package(Dyninst REQUIRED) at configure time regardless.
   #     ON = build vendored submodule, OFF = use system install. We
   #     default to ON for a self-contained build (no apt dyninst-dev
   #     dependency on the build host).
   #   * MPI build, Python, examples, tests, docs disabled (none of
   #     these affect the rocprof-sys-run runtime path that the fix
   #     targets, and turning them off keeps the build small).
   echo "[rocm_patches] running cmake ..."
   cmake \
      -S "${src_root}/projects/rocprofiler-systems" \
      -B "${build_dir}" \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}/install-staging" \
      -DROCPROFSYS_USE_ROCM=ON \
      -DROCPROFSYS_USE_ROCPROFILER_SDK=ON \
      -DROCPROFSYS_USE_OMPT=ON \
      -DROCPROFSYS_USE_PAPI=OFF \
      -DROCPROFSYS_USE_MPI=OFF \
      -DROCPROFSYS_USE_PYTHON=OFF \
      -DROCPROFSYS_BUILD_DYNINST=ON \
      -DROCPROFSYS_BUILD_LIBUNWIND=ON \
      -DROCPROFSYS_BUILD_EXAMPLES=OFF \
      -DROCPROFSYS_BUILD_TESTING=OFF \
      -DROCPROFSYS_BUILD_DOCS=OFF \
      -DCMAKE_PREFIX_PATH="${ROCM_PATH}" \
      -DAMDDeviceLibs_DIR="${ROCM_PATH}/lib/cmake/AMDDeviceLibs" \
      || return 1

   # In the v1.3.0 baseline (rocm-7.2.x source line),
   # librocprof-sys.so.1.3.0 is produced by the default aggregating
   # target and pulls in perfetto's static lib via its build deps.
   # Building the shared-library target alone leaves
   # external/perfetto/.../libperfetto.a unbuilt and the link fails.
   # Build everything; we install only the .so.1.3.0 artifact below.
   echo "[rocm_patches] building all rocprofiler-systems targets (slow) ..."
   cmake --build "${build_dir}" --parallel "${NJOBS:-$(nproc)}" || return 1

   # ── install patched .so ──────────────────────────────────────────
   local built
   built="$(find "${build_dir}" -maxdepth 6 -name 'librocprof-sys.so.1.3.0' \
              -type f -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
   [ -n "${built}" ] || { echo "[rocm_patches] ERROR: built .so not found" >&2; return 1; }

   echo "[rocm_patches] installing ${built} -> ${lib_dir}/ ..."
   ${SUDO} install -m 0755 "${built}" "${lib_dir}/librocprof-sys.so.1.3.0"
   ${SUDO} ln -sfn librocprof-sys.so.1.3.0 "${lib_dir}/librocprof-sys.so.1"
   ${SUDO} ln -sfn librocprof-sys.so.1     "${lib_dir}/librocprof-sys.so"

   # ── SONAME sanity check ──────────────────────────────────────────
   local soname
   soname="$(readelf -d "${lib_dir}/librocprof-sys.so.1.3.0" 2>/dev/null \
              | awk '/SONAME/{print $NF}' | tr -d '[]')"
   if [ "${soname}" != "librocprof-sys.so.1" ]; then
      echo "[rocm_patches] ERROR: SONAME mismatch (got '${soname}', expected 'librocprof-sys.so.1')" >&2
      return 1
   fi
   echo "[rocm_patches] SONAME OK: ${soname}"

   # ── provenance file ──────────────────────────────────────────────
   ${SUDO} tee "${lib_dir}/.build-info" >/dev/null <<EOF
built-from:    ${repo}
commit:        $(git -C "${src_root}" rev-parse HEAD 2>/dev/null || echo unknown)
patches:       $(ls "${bundle_dir}"/*.patch 2>/dev/null | xargs -n1 basename | tr '\n' ' ')
compiler:      $(${CXX:-g++} --version 2>/dev/null | head -1)
cmake:         $(cmake --version 2>/dev/null | head -1)
host:          $(hostname)
date:          $(date -u +%Y-%m-%dT%H:%M:%SZ)
size:          $(stat -c%s "${lib_dir}/librocprof-sys.so.1.3.0") bytes
soname:        ${soname}
rocm-version:  ${ROCM_VERSION}
EOF
   echo "[rocm_patches] wrote ${lib_dir}/.build-info"

   return 0
}

# ─────────────────────────────────────────────────────────────────────
# build_rocprof_compute
# ---------------------
# Materialize the rocprof-compute overlay for one ROCm version:
#
#   1. Stage the vendored install.sh / build.sh / README.md.in into
#      ${INSTALL_PREFIX}/rocprof-compute/.
#   2. Render README.md from README.md.in (substitutes @VERSION@ and
#      @DETAIL_BLOCK@; the latter is a per-version snippet picked
#      from a local lookup table below).
#   3. Run build.sh (nuitka onefile of upstream rocprofiler-compute @
#      tag rocm-${ROCM_VERSION}).  Idempotent: skips if
#      lib/rocprof-compute.bin already exists and --replace was not
#      passed.  Wall time on a compute node is ~25-30 min per build;
#      caller (main_setup.sh) is responsible for running this on a
#      host with enough RAM (peak ~10 GB) and CPU.
#   4. Run install.sh with ROCM_PATH and MODULEFILE injected via env
#      so it edits the modulefile this run targets (rather than its
#      built-in /shared/apps/... default).
#
# Notes:
#   * No vendored .patch files.  The whole bundle is a single
#      pair of shell scripts plus a README template.
#   * Prior to 2026-05 the nuitka build for ROCm >= 7.1.0 lived inline
#      in rocm/scripts/rocm_setup.sh; that block has been retired in
#      favour of this overlay so the build, the install wiring, and
#      the `Built by: rocm_patches.sh@...` provenance line are all
#      produced by a single script.  rocm_setup.sh no longer builds
#      rocprof-compute on any ROCm version.
#   * For 6.3.x there is no .exe to fall back to (the v3.0.0 / Omniperf
#      transition was still Python-only); build.sh is the only option.
#   * For 7.x the SDK still ships a (broken) Python wrapper at
#      ${ROCM_PATH}/bin/rocprof-compute; the overlay's bin/ wins via
#      PATH ordering on the modulefile.
# ─────────────────────────────────────────────────────────────────────
rocprof_compute_detail_block() {
   # Per-version one-liner that lands in the rendered README.md under
   # ${INSTALL_PREFIX}/rocprof-compute/.  Keep these short -- the doc
   # body lives in README.md.in.
   case "$1" in
      6.3.0) echo 'Upstream tag `rocm-6.3.0` resolves to commit `4244ddb`, upstream VERSION `3.0.0`.' ;;
      6.3.1) echo 'Upstream tag `rocm-6.3.1` resolves to commit `2ef01fb`, upstream VERSION `3.0.0` (same commit as rocm-6.3.2 and rocm-6.3.3; only CMakeLists.txt differs from rocm-6.3.0).' ;;
      6.3.2) echo 'Upstream tag `rocm-6.3.2` resolves to commit `2ef01fb`, upstream VERSION `3.0.0` (same commit as rocm-6.3.1 and rocm-6.3.3).' ;;
      6.3.3) echo 'Upstream tag `rocm-6.3.3` resolves to commit `2ef01fb`, upstream VERSION `3.0.0`.' ;;
      6.3.4) echo 'No upstream `rocm-6.3.4` tag exists; build.sh falls back to the most recent 6.3.x tag (`rocm-6.3.3` / commit `2ef01fb`, upstream VERSION `3.0.0`).  In-distribution VERSION.sha on this cluster is `dc8dc2c3`.' ;;
      6.4.0) echo 'Upstream tag `rocm-6.4.0` resolves to commit `62bf58c`, upstream VERSION `3.1.0`.' ;;
      6.4.1) echo 'Upstream tag `rocm-6.4.1` resolves to commit `7b25d958`, upstream VERSION `3.1.0`.' ;;
      6.4.2) echo 'Upstream tag `rocm-6.4.2` resolves to commit `3c7933e1`, upstream VERSION `3.1.1`.' ;;
      6.4.3) echo 'Upstream tag `rocm-6.4.3` resolves to commit `3c7933e1`, upstream VERSION `3.1.1`.  Note: the in-distribution `rocprof-compute.exe` for rocm-6.4.3 ships with a broken pyinstaller bundle (missing `VERSION.sha` inside the onefile), so a fresh nuitka rebuild is required.' ;;
      7.0.0) echo 'Upstream tag `rocm-7.0.0` resolves to commit `246dd58`, upstream VERSION `3.2.3` (same commit as rocm-7.0.1 and rocm-7.0.2).' ;;
      7.0.1) echo 'Upstream tag `rocm-7.0.1` resolves to commit `246dd58`, upstream VERSION `3.2.3`.' ;;
      7.0.2) echo 'Upstream tag `rocm-7.0.2` resolves to commit `246dd58`, upstream VERSION `3.2.3`.' ;;
      7.1.0) echo 'Upstream tag `rocm-7.1.0` -- monorepo (rocm-systems @ rocm-7.1.0), `projects/rocprofiler-compute` subtree.' ;;
      7.1.1) echo 'Upstream tag `rocm-7.1.1` -- monorepo (rocm-systems @ rocm-7.1.1), `projects/rocprofiler-compute` subtree.' ;;
      7.2.0) echo 'Upstream tag `rocm-7.2.0` -- monorepo (rocm-systems @ rocm-7.2.0), `projects/rocprofiler-compute` subtree.  Builds alongside the rocprof-sys 1.3.0 cherry-pick.' ;;
      7.2.1) echo 'Upstream tag `rocm-7.2.1` -- monorepo (rocm-systems @ rocm-7.2.1), `projects/rocprofiler-compute` subtree.  Builds alongside the rocprof-sys 1.3.0 cherry-pick.' ;;
      7.2.2) echo 'Upstream tag `rocm-7.2.2` -- monorepo (rocm-systems @ rocm-7.2.2), `projects/rocprofiler-compute` subtree.  Builds alongside the rocprof-sys 1.3.0 cherry-pick.' ;;
      7.2.3) echo 'Upstream tag `rocm-7.2.3` -- monorepo (rocm-systems @ rocm-7.2.3), `projects/rocprofiler-compute` subtree.  Builds alongside the rocprof-sys 1.3.0 cherry-pick.' ;;
      afar-22.1.0)    echo 'RC tree (no `rocm-afar-22.1.0` upstream tag).  build.sh switches to RC mode and pins to the commit recorded in `${ROCM_PATH}/libexec/rocprofiler-compute/VERSION.sha` (afar-22.1.0 ships `167a9576`, upstream VERSION `3.3.0`).' ;;
      afar-22.2.0)    echo 'RC tree (no `rocm-afar-22.2.0` upstream tag).  build.sh switches to RC mode and pins to the commit recorded in `${ROCM_PATH}/libexec/rocprofiler-compute/VERSION.sha` (afar-22.2.0 ships `bad92dc4`, upstream VERSION `3.3.0`).' ;;
      therock-23.1.0) echo 'RC tree (no `rocm-therock-23.1.0` upstream tag).  build.sh switches to RC mode and pins to the commit recorded in `${ROCM_PATH}/libexec/rocprofiler-compute/VERSION.sha` (when present).' ;;
      therock-23.2.0) echo 'RC tree (no `rocm-therock-23.2.0` upstream tag).  build.sh switches to RC mode and pins to the commit recorded in `${ROCM_PATH}/libexec/rocprofiler-compute/VERSION.sha` (therock-23.2.0 ships `bc96f0a`, upstream VERSION `3.6.0`).' ;;
      *)     echo "Upstream tag \`rocm-$1\`." ;;
   esac
}

build_rocprof_compute() {
   local bundle_dir="${PATCH_SOURCE_DIR}/rocprof-compute"
   local overlay_dir="${INSTALL_PREFIX}/rocprof-compute"
   local out_bin="${overlay_dir}/lib/rocprof-compute.bin"

   [ -d "${bundle_dir}" ] || send-error "patch bundle missing: ${bundle_dir}"
   for f in install.sh build.sh README.md.in; do
      [ -f "${bundle_dir}/${f}" ] || send-error "missing vendored file: ${bundle_dir}/${f}"
   done

   # ── 1. stage the overlay tree ────────────────────────────────────
   ${SUDO} mkdir -p "${overlay_dir}/bin" "${overlay_dir}/lib" \
                    "${overlay_dir}/build" "${overlay_dir}/doc"
   if [ "${EUID:-$(id -u)}" -ne 0 ]; then
      ${SUDO} chown -R "$(id -u):$(id -g)" "${overlay_dir}" || true
   fi
   install -m 0755 "${bundle_dir}/install.sh" "${overlay_dir}/install.sh"
   install -m 0755 "${bundle_dir}/build.sh"   "${overlay_dir}/build.sh"

   # ── 2. render README.md from README.md.in ────────────────────────
   local detail
   detail="$(rocprof_compute_detail_block "${ROCM_VERSION}")"
   sed -e "s/@VERSION@/${ROCM_VERSION}/g" \
       -e "s|@DETAIL_BLOCK@|${detail}|g" \
       "${bundle_dir}/README.md.in" > "${overlay_dir}/README.md"

   # ── 3. build (idempotent) ────────────────────────────────────────
   # Skip the slow build if a binary is already in place and the user
   # didn't ask for a forced rebuild.  build.sh itself produces a
   # versioned filename (rocprof-compute-v<X>.bin) and re-points
   # lib/rocprof-compute.bin at it via symlink, so this check is
   # sufficient regardless of which upstream tag we last built.
   #
   # Exit code 43 from build.sh is the agreed soft no-op: an RC tree
   # whose VERSION.sha is missing/empty, so the upstream commit cannot
   # be pinned reliably. Treat that as "no overlay produced, but not
   # a failure"; do not invoke install.sh in that case (there's no
   # binary to wire up, and we should not edit the modulefile to point
   # at a nonexistent overlay).
   local skipped=0
   if [ -e "${out_bin}" ] && [ "${REPLACE}" -eq 0 ]; then
      echo "[rocm_patches] ${out_bin} already exists -- skipping build (use --replace to force)"
   else
      echo "[rocm_patches] running nuitka build for rocprof-compute ${ROCM_VERSION} ..."
      echo "[rocm_patches]   (wall time ~25-30 min, peak ~10 GB RAM; runs on this host)"
      # build.sh runs under `set -euo pipefail`; capture its exit
      # status WITHOUT short-circuiting via `||` so we can distinguish
      # the 43-soft-skip from a real failure.
      local build_rc=0
      bash "${overlay_dir}/build.sh" || build_rc=$?
      if [ "${build_rc}" -eq 43 ]; then
         echo "[rocm_patches] build.sh returned 43 (RC tree without VERSION.sha)"
         echo "[rocm_patches] no rocprof-compute overlay will be produced for ${ROCM_VERSION}"
         skipped=1
      elif [ "${build_rc}" -ne 0 ]; then
         return 1
      fi
   fi

   if [ "${skipped}" -eq 1 ]; then
      return 43
   fi

   # ── 4. wire up via install.sh ────────────────────────────────────
   # Inject ROCM_PATH and MODULEFILE so install.sh edits the modulefile
   # *this* run targets, not its built-in /shared/apps/... default.
   echo "[rocm_patches] running install.sh to wire bin/ symlinks and modulefile ..."
   ROCM_PATH="${ROCM_PATH}" \
   MODULEFILE="${MODULE_FILE}" \
   bash "${overlay_dir}/install.sh" || return 1

   return 0
}

# ─────────────────────────────────────────────────────────────────────
# fix_overlay_runpath_and_libunwind
# ---------------------------------
# After the patched librocprof-sys.so.X.Y.Z lands in
# ${INSTALL_PREFIX}/lib/, two follow-up steps are required before the
# patched .so will actually load at runtime:
#
#   1. Resolve libunwind.so.99 (the timemory-bundled libunwind built
#      next to the patched .so). The build tree ships it at
#      <INSTALL_PREFIX>/build/rocprofiler-systems/external/timemory/
#      external/libunwind/install/lib/libunwind.so.99.0.0.  Copy it
#      next to the patched .so plus the SONAME / dev symlinks. If the
#      build dir was cleaned up (out-of-tree apply_and_build.sh, or
#      operator removed build/), borrow from a sibling overlay whose
#      libunwind is on disk and ABI-compatible (any 7.x or 6.4.x
#      bundled libunwind works -- DT_SONAME = libunwind.so.99 for all).
#
#   2. Rewrite the patched .so's DT_RUNPATH from the absolute
#      build-tree paths cmake baked in (which point at directories
#      cleaned up after the build) to a portable form pointing at
#      $ORIGIN (= ${INSTALL_PREFIX}/lib, where libunwind.so.99 now
#      lives), the matching SDK's lib dir, and the SDK's
#      rocprofiler-systems internal lib subdir (where libgotcha.so.2
#      etc. live), plus the standard elfutils path.
#
# Idempotent.  Returns 0 on success, 1 on hard error.
# ─────────────────────────────────────────────────────────────────────
fix_overlay_runpath_and_libunwind() {
   local lib_dir="${INSTALL_PREFIX}/lib"
   local patched
   patched=$(ls -1 "${lib_dir}"/librocprof-sys.so.[0-9]*.[0-9]*.[0-9]* 2>/dev/null \
              | grep -vE '\.orig$' | head -1)
   if [ -z "${patched}" ]; then
      echo "[rocm_patches] fix_overlay_runpath_and_libunwind: no patched .so in ${lib_dir}; skipping"
      return 0
   fi

   # 1. libunwind.so.99 next to the patched .so
   if [ ! -e "${lib_dir}/libunwind.so.99.0.0" ]; then
      local src=""
      local candidate
      candidate=$(find "${INSTALL_PREFIX}/build" \
                      -path '*/timemory/external/libunwind/install/lib/libunwind.so.99.0.0' \
                      2>/dev/null | head -1)
      if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
         src="${candidate}"
      else
         # Build tree was cleaned up; look at sibling overlays in the
         # same install root (/opt/rocm-patches-* by default; honour
         # whatever prefix the caller chose).
         local roots
         roots="$(dirname "${INSTALL_PREFIX}")"
         local donor
         for donor in 7.1.0 7.1.1 7.0.2 6.4.3 6.4.0 7.0.0; do
            local d="${roots}/rocm-patches-${donor}/build/rocprofiler-systems/external/timemory/external/libunwind/install/lib/libunwind.so.99.0.0"
            if [ -f "${d}" ]; then
               src="${d}"
               break
            fi
         done
      fi
      if [ -z "${src}" ] || [ ! -f "${src}" ]; then
         echo "[rocm_patches] WARNING: libunwind.so.99.0.0 not findable; patched .so" >&2
         echo "[rocm_patches]          will fail to load with 'libunwind.so.99: not found'." >&2
         echo "[rocm_patches]          Provide a libunwind under ${lib_dir}/ manually." >&2
         return 1
      fi
      echo "[rocm_patches] copy libunwind.so.99.0.0 from ${src}"
      ${SUDO} install -m 0755 "${src}" "${lib_dir}/libunwind.so.99.0.0"
      ${SUDO} ln -sfn libunwind.so.99.0.0 "${lib_dir}/libunwind.so.99"
      ${SUDO} ln -sfn libunwind.so.99     "${lib_dir}/libunwind.so"
   else
      echo "[rocm_patches] libunwind.so.99.0.0 already present in ${lib_dir}"
   fi

   # 2. Rewrite RUNPATH on the patched .so
   if ! command -v patchelf >/dev/null 2>&1; then
      echo "[rocm_patches] ERROR: patchelf not on PATH; cannot rewrite RUNPATH" >&2
      return 1
   fi

   local sdk_name
   # Trim any rocm- prefix and use what's left (handles 7.2.1 → rocm-7.2.1,
   # afar-22.1.0 → rocm-afar-22.1.0, therock-23.2.0 → rocm-therock-23.2.0).
   sdk_name="rocm-${ROCM_VERSION}"
   local new_rpath="\$ORIGIN:\$ORIGIN/../../${sdk_name}/lib/rocprofiler-systems:\$ORIGIN/../../${sdk_name}/lib:/usr/lib/x86_64-linux-gnu/elfutils"
   local cur_rpath
   cur_rpath=$(patchelf --print-rpath "${patched}" 2>/dev/null)
   if [ "${cur_rpath}" = "${new_rpath}" ]; then
      echo "[rocm_patches] RUNPATH on $(basename "${patched}") is already portable"
   else
      echo "[rocm_patches] rewriting RUNPATH on $(basename "${patched}")"
      echo "[rocm_patches]   from: ${cur_rpath}"
      echo "[rocm_patches]   to:   ${new_rpath}"
      ${SUDO} patchelf --set-rpath "${new_rpath}" "${patched}" || return 1
   fi

   # 3. Verify all NEEDED libs resolve from the install location.
   local missing
   missing=$(cd "${lib_dir}" && ldd "./$(basename "${patched}")" 2>&1 \
              | grep -E 'not found' | head -5)
   if [ -n "${missing}" ]; then
      echo "[rocm_patches] WARNING: patched .so still has unresolved deps:" >&2
      echo "${missing}" | sed 's/^/[rocm_patches]   /' >&2
      return 1
   fi
   return 0
}

# ─────────────────────────────────────────────────────────────────────
# swap_sdk_lib_symlink
# --------------------
# Replace the SDK's versioned librocprof-sys.so.X.Y.Z with an absolute
# symlink to the patched .so in ${INSTALL_PREFIX}/lib/.  The original
# SDK file is preserved as `.orig` on the first run.  Idempotent:
# detects an existing swap (live entry already pointing at the
# patches lib) and exits with no change.  Refuses to overwrite if a
# `.orig` is already present alongside a live SDK file that is NOT
# the overlay symlink (means a previous swap was partially reverted
# by hand -- requires operator attention).
#
# Why this is necessary on top of the LD_LIBRARY_PATH modulefile
# overlay: rocprof-sys-run (the SDK binary at
# ${ROCM_PATH}/bin/rocprof-sys-run) constructs the child env by
# prepending ${ROCPROFSYS_ROOT}/lib ahead of the inherited
# LD_LIBRARY_PATH.  That defeats the modulefile overlay -- the SDK's
# unpatched .so wins dlopen() resolution in the profiled child and
# the Bug A SIGSEGV in rocprofiler_configure() returns.  Making the
# SDK's own versioned .so a symlink into the patches dir means the
# patched bits run regardless of which path the loader picks.
#
# Touches exactly ONE node under the SDK tree (the versioned .so).
# The librocprof-sys.so / .so.MAJOR aliases are SDK-relative symlinks
# that already point at the versioned file and need no change.
# ─────────────────────────────────────────────────────────────────────
swap_sdk_lib_symlink() {
   local overlay_lib="${INSTALL_PREFIX}/lib"
   local patched
   patched=$(ls -1 "${overlay_lib}"/librocprof-sys.so.[0-9]*.[0-9]*.[0-9]* 2>/dev/null \
              | grep -vE '\.orig$' | head -1)
   if [ -z "${patched}" ]; then
      echo "[rocm_patches] swap_sdk_lib_symlink: no patched .so in ${overlay_lib}; skipping"
      return 0
   fi
   local sofile
   sofile="$(basename "${patched}")"
   local sdk_so="${ROCM_PATH}/lib/${sofile}"
   if [ ! -e "${sdk_so}" ] && [ ! -L "${sdk_so}" ]; then
      echo "[rocm_patches] swap_sdk_lib_symlink: SDK has no ${sofile} at ${sdk_so}"
      echo "[rocm_patches]   (SDK SONAME differs from overlay's; nothing to swap)"
      return 0
   fi
   if [ -L "${sdk_so}" ] \
        && [ "$(readlink -f "${sdk_so}")" = "$(readlink -f "${patched}")" ]; then
      echo "[rocm_patches] SDK ${sofile} already points at the overlay (idempotent)"
      return 0
   fi
   if [ -e "${sdk_so}.orig" ]; then
      echo "[rocm_patches] WARNING: ${sdk_so}.orig already exists but live file is" >&2
      echo "[rocm_patches]          not the overlay symlink.  Refusing to overwrite --" >&2
      echo "[rocm_patches]          investigate.  (Re-run after restoring .orig or" >&2
      echo "[rocm_patches]          fixing the live file by hand.)" >&2
      return 1
   fi
   echo "[rocm_patches] swap SDK ${sofile}:"
   echo "[rocm_patches]   ${sdk_so}.orig <-- (current SDK file moved aside)"
   echo "[rocm_patches]   ${sdk_so}      --> ${patched}"
   ${SUDO} mv -n "${sdk_so}" "${sdk_so}.orig" || return 1
   ${SUDO} ln -sfn "${patched}" "${sdk_so}"   || return 1
   return 0
}

# ─────────────────────────────────────────────────────────────────────
# patch_module_file
# -----------------
# Append, exactly once, two overlay lines to the rocm/${ROCM_VERSION}.lua
# module file written by rocm_setup.sh:
#
#   1. prepend_path("LD_LIBRARY_PATH", "${INSTALL_PREFIX}/lib")
#        so dlopen() resolves librocprof-sys.so.1.3.0 to our patched
#        .so ahead of the SDK's own (unpatched) copy.
#
#   2. prepend_path("PATH", pathJoin(base, "share/rocprofiler-systems/bin"))
#        so the rocprof-sys-run wrapper (installed by
#        install_rocprof_sys_run_wrapper, see below) shadows the SDK's
#        ${ROCM_PATH}/bin/rocprof-sys-run. The wrapper preloads
#        librocprof-sys.so.1 to defeat libbfd interposition on hosts
#        whose system libbfd is older than the binutils version
#        rocprof-sys statically links.
#
# Lmod's prepend_path is LIFO: a later prepend lands FIRST in the
# resolved path string, so the LD_LIBRARY_PATH overlay MUST be inserted
# AFTER the original `prepend_path("LD_LIBRARY_PATH", pathJoin(base,
# "lib"))`. We insert it immediately after that line, idempotently.
# The PATH prepend goes at end-of-file; its position relative to the
# rocm-7.2.x bin prepend doesn't matter since both share/rocprofiler-systems/bin
# and bin are SDK-owned (the wrapper just needs to win over <rocm>/bin).
#
# Idempotency strategy:
#
# Two independent idempotency checks, one per inserted block:
#
#   * LD_LIBRARY_PATH block: keyed off `rocm-patches-${ROCM_VERSION}`.
#     Any reference to that string in the modulefile means somebody
#     (this script on a previous run, or a human admin) has already
#     wired the overlay. We do NOT add a second entry under any
#     circumstances. On admin-applied hand edits with a different
#     absolute path (e.g. /shared/apps/.../opt/rocm-patches-X.Y.Z/lib
#     vs. our /opt/rocm-patches-X.Y.Z/lib default), we warn but keep
#     the existing entry as the source of truth.
#
#   * PATH block: keyed off the literal token
#     `share/rocprofiler-systems/bin`. The two blocks are decoupled so
#     that a re-run can backfill the PATH prepend on modulefiles that
#     already have the LD_LIBRARY_PATH overlay from an older revision
#     of this script.
# ─────────────────────────────────────────────────────────────────────
patch_module_file() {
   if [ ! -f "${MODULE_FILE}" ]; then
      echo "[rocm_patches] WARNING: module file not found: ${MODULE_FILE}"
      echo "[rocm_patches]          rocprof-sys-run will still pick up the"
      echo "[rocm_patches]          patched .so as long as ${INSTALL_PREFIX}/lib"
      echo "[rocm_patches]          is on LD_LIBRARY_PATH at runtime."
      return 0
   fi

   local overlay="${INSTALL_PREFIX}/lib"
   local marker="rocm-patches-${ROCM_VERSION}"

   # ─── Block 1: LD_LIBRARY_PATH overlay ───────────────────────────
   if grep -Fq "${marker}" "${MODULE_FILE}"; then
      # Try to extract the existing overlay path so we can warn on
      # mismatch with this run's INSTALL_PREFIX/lib.
      local existing
      existing="$(grep -oE '"[^"]*'"${marker}"'[^"]*/lib"' "${MODULE_FILE}" \
                   | head -1 | tr -d '"')"
      if [ -n "${existing}" ] && [ "${existing}" != "${overlay}" ]; then
         echo "[rocm_patches] module file already has an overlay entry, but it"
         echo "[rocm_patches]   points at:        ${existing}"
         echo "[rocm_patches]   this run targets: ${overlay}"
         echo "[rocm_patches] keeping the existing entry (likely an admin's hand"
         echo "[rocm_patches] edit on a cluster with a non-default install layout)."
         echo "[rocm_patches] If you intended to use ${overlay}, edit ${MODULE_FILE}"
         echo "[rocm_patches] manually or re-run with --install-prefix matching the"
         echo "[rocm_patches] existing path."
      else
         echo "[rocm_patches] module file already has overlay entry for ${marker}; nothing to do"
      fi
   else
      echo "[rocm_patches] adding LD_LIBRARY_PATH overlay to ${MODULE_FILE}"
      # Append after the canonical line; if the canonical line is absent
      # (older module variant) just append at end of file.
      if grep -q 'prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))' "${MODULE_FILE}"; then
         ${SUDO} sed -i '/prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))/a\
\
\t-- rocm-patches-'"${ROCM_VERSION}"' overlay (cherry-picks of upstream PRs and\
\t-- vendored fixes for rocprof-sys regressions on this ROCm release line;\
\t-- see '"${INSTALL_PREFIX}"'/doc/ for the full bug report). prepend_path\
\t-- is LIFO, so the overlay MUST come AFTER the SDK lib path so it lands\
\t-- FIRST in the resolved LD_LIBRARY_PATH.\
\tprepend_path("LD_LIBRARY_PATH", "'"${overlay}"'")' \
            "${MODULE_FILE}"
      else
         ${SUDO} tee -a "${MODULE_FILE}" >/dev/null <<-EOF

	-- rocm-patches-${ROCM_VERSION} overlay (rocprof-sys regression fixes; see ${INSTALL_PREFIX}/doc/)
	prepend_path("LD_LIBRARY_PATH", "${overlay}")
EOF
      fi
   fi

   # ─── Block 2: PATH prepend for the rocprof-sys-run wrapper ──────
   # The literal `share/rocprofiler-systems/bin` token is unique to
   # this prepend (rocprof-compute uses share/rocprof-compute/bin or
   # similar; there is no collision in any of the 6.3.x .. 7.2.x
   # modulefiles we generate). Append at end-of-file so we don't fight
   # any specific anchor line.
   if grep -Fq 'share/rocprofiler-systems/bin' "${MODULE_FILE}"; then
      echo "[rocm_patches] module file already has rocprof-sys-run wrapper PATH prepend; nothing to do"
   else
      echo "[rocm_patches] adding rocprof-sys-run wrapper PATH prepend to ${MODULE_FILE}"
      ${SUDO} tee -a "${MODULE_FILE}" >/dev/null <<-'EOF'

	-- Place the rocprof-sys-run wrapper (which applies a libbfd LD_PRELOAD
	-- workaround when the system libbfd is older than the one rocprof-sys
	-- statically links) first in PATH. The wrapper is a no-op on systems
	-- where the system libbfd is new enough. See
	-- install_rocprof_sys_run_wrapper() in rocm_patches.sh for the install
	-- side, and <rocm>/share/rocprofiler-systems/bin/rocprof-sys-run itself
	-- for the bug background.
	prepend_path("PATH", pathJoin(base, "share/rocprofiler-systems/bin"))
EOF
   fi
}

# ─────────────────────────────────────────────────────────────────────
# install_rocprof_sys_run_wrapper
# -------------------------------
# Copy the vendored rocprof-sys-run wrapper into
# ${ROCM_PATH}/share/rocprofiler-systems/bin/rocprof-sys-run, where it
# is found ahead of the SDK's own ${ROCM_PATH}/bin/rocprof-sys-run by
# virtue of the modulefile's share/rocprofiler-systems/bin PATH prepend
# (added by patch_module_file()).
#
# The wrapper exists to defeat a libbfd ABI mismatch: rocprof-sys
# statically links binutils-2.42 (cherry-pick) but the system libbfd
# (e.g. Ubuntu 22.04's libbfd-2.38-system.so) is pulled in transitively
# by OpenMPI/UCX. Without LD_PRELOAD the system 2.38 symbols win
# resolution and rocprof-sys SegFaults inside
# _bfd_x86_elf_get_synthetic_symtab() during rocprofiler_configure(),
# usually during MPI rank static-init. The wrapper preloads
# librocprof-sys.so.1 so its bundled 2.42 symbols win instead. See the
# wrapper's own docstring at sources/rocm-patches/rocprof-sys-1.3.0/rocprof-sys-run
# for the full bug write-up.
#
# Idempotent:
#   * if the destination file is byte-identical to the vendored source,
#     do nothing;
#   * if it differs (e.g. an older revision of the wrapper, or a hand
#     edit), overwrite it. This is what we want when the wrapper itself
#     is updated in a later commit.
# ─────────────────────────────────────────────────────────────────────
install_rocprof_sys_run_wrapper() {
   local src="${PATCH_SOURCE_DIR}/rocprof-sys-1.3.0/rocprof-sys-run"
   local dst_dir="${ROCM_PATH}/share/rocprofiler-systems/bin"
   local dst="${dst_dir}/rocprof-sys-run"

   if [ ! -f "${src}" ]; then
      echo "[rocm_patches] WARNING: vendored wrapper not found: ${src}"
      echo "[rocm_patches]          libbfd LD_PRELOAD workaround will NOT be applied;"
      echo "[rocm_patches]          rocprof-sys-instrumented MPI programs may SegFault"
      echo "[rocm_patches]          on hosts whose system libbfd is older than 2.42."
      return 0
   fi

   if [ -f "${dst}" ] && cmp -s "${src}" "${dst}"; then
      echo "[rocm_patches] rocprof-sys-run wrapper already up to date at ${dst}"
      return 0
   fi

   echo "[rocm_patches] installing rocprof-sys-run wrapper at ${dst}"
   ${SUDO} install -d -m 0755 "${dst_dir}" || return 1
   ${SUDO} install -m 0755 "${src}" "${dst}" || return 1
   return 0
}

# ─────────────────────────────────────────────────────────────────────
# write_rocm_patches_provenance
# -----------------------------
# Embed a `whatis("Built by: rocm_patches.sh@<hash> (<dirty>)")` line
# in the SDK modulefile we just edited, matching the convention used
# by every `_setup.sh` leaf in this repo.  inventory_packages.py reads
# this line to populate the `rocm_patches` row of its
# --install-provenance matrix.
#
# Idempotent in two ways:
#   * If an existing `Built by: ${LEAF_SCRIPT_NAME}@...` line is already
#     present in the modulefile, REPLACE its payload in place so the
#     latest hash + clean/dirty bit wins (re-runs at different commits
#     don't leave stale entries behind).
#   * Otherwise append a new line at the end of the file. We don't try
#     to insert it next to rocm_setup.sh's own `Built by:` line near
#     the top, because that anchor may not exist on older modulefiles
#     written before rocm_setup.sh started emitting Built-by lines.
#     inventory_packages.py uses re.finditer over the whole file and
#     does not care about ordering.
#
# Co-exists cleanly with rocm_setup.sh's `Built by: rocm_setup.sh@...`
# line in the same .lua: the line is keyed by writer-script name, and
# inventory_packages.py filters by script when populating each row.
# ─────────────────────────────────────────────────────────────────────
write_rocm_patches_provenance() {
   if [ ! -f "${MODULE_FILE}" ]; then
      echo "[rocm_patches] WARNING: ${MODULE_FILE} missing; cannot embed provenance line"
      return 0
   fi
   local new_line='whatis("Built by: '"${LEAF_SCRIPT_NAME}"'@'"${LEAF_SCRIPT_COMMIT:0:12}"' ('"${LEAF_SCRIPT_DIRTY}"')")'
   if grep -q "Built by: ${LEAF_SCRIPT_NAME}@" "${MODULE_FILE}"; then
      # Replace existing payload in-place. Using '#' as sed delimiter
      # so the embedded `/` in "rocm_patches.sh" doesn't need escaping.
      ${SUDO} sed -i \
         "s#whatis(\"Built by: ${LEAF_SCRIPT_NAME}@[^\"]*\")#${new_line}#" \
         "${MODULE_FILE}"
      echo "[rocm_patches] refreshed provenance in ${MODULE_FILE}"
   else
      echo "${new_line}" | ${SUDO} tee -a "${MODULE_FILE}" >/dev/null
      echo "[rocm_patches] embedded provenance into ${MODULE_FILE}"
   fi
}

# ── dispatch ────────────────────────────────────────────────────────
rc=0

# Backfill mode: skip the build entirely; only apply the modulefile
# overlay edit. The function is idempotent (won't add a second entry
# on a re-run, won't overwrite a hand-applied entry pointing
# elsewhere), so this is safe to call regardless of cluster state.
# Sanity-check: the overlay lib dir must already exist (the patched
# .so was built either by the in-tree builder above, or by the
# standalone rocm-patches-X.Y.Z/apply_and_build.sh for releases the
# in-tree builder does not yet handle). Pointing the modulefile at
# an empty/non-existent dir would be silently wrong.
if [ "${MODULE_FILE_ONLY}" -eq 1 ]; then
   echo "[rocm_patches] --module-file-only mode: skipping build, only patching ${MODULE_FILE}"
   if [ ! -d "${INSTALL_PREFIX}/lib" ]; then
      echo "[rocm_patches] ERROR: ${INSTALL_PREFIX}/lib does not exist." >&2
      echo "[rocm_patches]   --module-file-only is a backfill helper; the patched .so" >&2
      echo "[rocm_patches]   must already be built and on disk before calling it." >&2
      echo "[rocm_patches]   Either (a) build it first via the standalone" >&2
      echo "[rocm_patches]       ${INSTALL_PREFIX}/apply_and_build.sh" >&2
      echo "[rocm_patches]   or (b) drop --module-file-only and let this script run" >&2
      echo "[rocm_patches]   the full build (only supported for 7.2.0/7.2.1 today)." >&2
      exit 1
   fi
   patch_module_file || rc=$?
   # Install the rocprof-sys-run wrapper alongside the LD_LIBRARY_PATH
   # overlay so the libbfd LD_PRELOAD workaround fires on the next
   # `module load rocm/${ROCM_VERSION}; rocprof-sys-run -- ...`.  Both
   # halves of the wrapper machinery (PATH prepend in patch_module_file
   # + the wrapper file itself here) are needed for the workaround to
   # take effect; backfilling either alone leaves a broken state.
   if [ "${rc}" -eq 0 ]; then
      install_rocprof_sys_run_wrapper || rc=$?
   fi
   # Self-heal the patched .so's RUNPATH and ensure libunwind.so.99 is
   # next to it (no-op if already done).  Then swap the SDK's
   # versioned .so to point at the overlay (no-op if already swapped).
   # Both steps are needed for clusters whose patched .so was built by
   # the standalone apply_and_build.sh and never had the RUNPATH /
   # SDK-swap follow-up applied.
   if [ "${rc}" -eq 0 ]; then
      fix_overlay_runpath_and_libunwind || rc=$?
   fi
   if [ "${rc}" -eq 0 ]; then
      swap_sdk_lib_symlink || rc=$?
   fi
   if [ "${rc}" -eq 0 ]; then
      write_rocm_patches_provenance || rc=$?
   fi
   if [ "${rc}" -eq 0 ]; then
      echo ""
      echo "[rocm_patches] ROCm ${ROCM_VERSION} backfill applied (modulefile + SDK swap)."
      echo "[rocm_patches]   module file: ${MODULE_FILE}"
   fi
   exit ${rc}
fi

# Track which bundles actually ran so we only invoke bundle-specific
# post-build hooks (e.g. the rocprof-sys LD_LIBRARY_PATH modulefile edit)
# when the matching bundle was built this run.
built_rocprof_sys=0
built_rocprof_compute=0

for bundle in ${PATCH_BUNDLES}; do
   case "${bundle}" in
      rocprof-sys-1.3.0)
         build_rocprof_sys_1_3_0 && built_rocprof_sys=1 || rc=$? ;;
      rocprof-compute)
         # build_rocprof_compute runs the bundle's own install.sh which
         # edits the modulefile (prepend_path PATH), so there's no
         # follow-on hook from this script.
         #
         # Exit 43 is a soft skip (RC tree with no VERSION.sha): treat
         # it as success-with-no-overlay-produced, NOT a build failure.
         # That keeps the per-package summary line clean on clusters
         # where some RC trees have a pinnable upstream commit and
         # others don't.
         build_rocprof_compute
         bundle_rc=$?
         if [ "${bundle_rc}" -eq 0 ]; then
            built_rocprof_compute=1
         elif [ "${bundle_rc}" -eq 43 ]; then
            : # soft skip; leave built_rocprof_compute=0, rc unchanged
         else
            rc=${bundle_rc}
         fi ;;
      *)
         echo "[rocm_patches] ERROR: no builder registered for bundle '${bundle}'" >&2
         rc=1 ;;
   esac
done

# patch_module_file() adds the LD_LIBRARY_PATH overlay required by the
# rocprof-sys bundle; only call it when that bundle was actually built.
# fix_overlay_runpath_and_libunwind() turns the patched .so's bogus
# absolute build-tree DT_RUNPATH into a portable form ($ORIGIN-rooted)
# and installs libunwind.so.99 next to the patched .so. swap_sdk_lib_symlink()
# then makes the SDK's own librocprof-sys.so.X.Y.Z a symlink to the
# patched .so so the runtime defeats rocprof-sys-run's own
# LD_LIBRARY_PATH prepending of ROCPROFSYS_ROOT/lib.
if [ "${rc}" -eq 0 ] && [ "${built_rocprof_sys}" -eq 1 ]; then
   patch_module_file || rc=$?
   # install_rocprof_sys_run_wrapper() drops a small bash wrapper at
   # ${ROCM_PATH}/share/rocprofiler-systems/bin/rocprof-sys-run that
   # LD_PRELOADs the patched librocprof-sys.so.1 to defeat the system
   # libbfd vs bundled binutils-2.42 symbol interposition. The
   # modulefile PATH prepend added by patch_module_file() makes the
   # wrapper win over ${ROCM_PATH}/bin/rocprof-sys-run at runtime.
   if [ "${rc}" -eq 0 ]; then
      install_rocprof_sys_run_wrapper || rc=$?
   fi
   if [ "${rc}" -eq 0 ]; then
      fix_overlay_runpath_and_libunwind || rc=$?
   fi
   if [ "${rc}" -eq 0 ]; then
      swap_sdk_lib_symlink || rc=$?
   fi
fi

# Embed the rocm_patches provenance whatis() line in the SDK modulefile
# when at least one bundle actually produced an overlay this run.  Skip
# the soft-noop/no-dispatch cases so inventory_packages.py's
# `rocm_patches` row stays '-' for versions where we did no work
# (instead of misleadingly claiming a "Built by:" run).  See
# write_rocm_patches_provenance() for the full idempotency story.
if [ "${rc}" -eq 0 ] \
     && { [ "${built_rocprof_sys}" -eq 1 ] \
          || [ "${built_rocprof_compute}" -eq 1 ]; }; then
   write_rocm_patches_provenance || rc=$?
fi

if [ "${rc}" -eq 0 ]; then
   echo ""
   if [ "${built_rocprof_sys}" -eq 0 ] && [ "${built_rocprof_compute}" -eq 0 ]; then
      # All bundles dispatched ran (or were skipped) without error, but
      # nothing landed on disk -- e.g. every dispatched bundle was a
      # soft no-op (RC tree without a public-resolvable VERSION.sha).
      echo "[rocm_patches] ROCm ${ROCM_VERSION}: no overlay artefacts were produced."
      echo "[rocm_patches]   (every dispatched bundle returned a soft no-op;"
      echo "[rocm_patches]    see preceding lines for the per-bundle reason)"
   else
      echo "[rocm_patches] ROCm ${ROCM_VERSION} patch overlay applied successfully."
      if [ "${built_rocprof_sys}" -eq 1 ]; then
         echo "[rocm_patches]   rocprof-sys library: ${INSTALL_PREFIX}/lib/librocprof-sys.so.1.3.0"
      fi
      if [ "${built_rocprof_compute}" -eq 1 ]; then
         echo "[rocm_patches]   rocprof-compute:     ${INSTALL_PREFIX}/rocprof-compute/bin/rocprof-compute"
      fi
      echo "[rocm_patches]   module file:         ${MODULE_FILE}"
   fi
fi

exit ${rc}
