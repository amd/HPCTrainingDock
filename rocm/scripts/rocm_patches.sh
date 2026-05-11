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
# entry is a fast check-and-exit-0.
#
# Backfill mode (--module-file-only):
#   Skips the build entirely and only applies the modulefile overlay
#   edit. Use this on clusters where rocm_setup.sh wrote the
#   rocm/X.Y.Z.lua modulefile BEFORE rocm_patches.sh existed, the
#   patched .so was already built by hand and is in place, but the
#   modulefile is still missing its `prepend_path("LD_LIBRARY_PATH",
#   "${INSTALL_PREFIX}/lib")` line. Idempotent: detects ANY existing
#   reference to `rocm-patches-${ROCM_VERSION}` in the modulefile
#   (whether written by this script or by a human admin) and exits
#   without touching the file.

LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
LEAF_DIR="$(dirname "${LEAF_SCRIPT_PATH}")"

# ── defaults ────────────────────────────────────────────────────────
: ${ROCM_VERSION:=""}
REPLACE=0
MODULE_PATH=/etc/lmod/modules/ROCm
INSTALL_PREFIX=""
PATCH_SOURCE_DIR=""
MODULE_FILE_ONLY=0
ROCM_PATH_OVERRIDE=""
NOOP_RC=43

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
      "--*")                 send-error "Unsupported argument at position $((${n}+1)) :: ${1}" ;;
      *)                     last ${1} ;;
   esac
   n=$((${n}+1))
   shift
done

[ -n "${ROCM_VERSION}" ] || send-error "--rocm-version is required"

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
      # apply_and_build.sh in /opt/rocm-patches-X.Y.Z/.
      #
      # rocprof-compute overlay (see rocprof-compute/ bundle): produces a
      # nuitka onefile of upstream rocprofiler-compute, drops it under
      # /opt/rocm-patches-${ROCM_VERSION}/rocprof-compute/, and adds a
      # prepend_path("PATH", ...) line to the modulefile so the overlay
      # shadows the broken in-distribution Python wrapper (or, on 7.1.x,
      # supersedes the rocm_setup.sh-built binary by being earlier on
      # PATH). Applies to every ROCm release the cluster has shipped with
      # a broken or in-built rocprof-compute -- 6.3.x through 7.1.x.
      7.2.0)        echo "rocprof-sys-1.3.0" ;;
      7.2.1)        echo "rocprof-sys-1.3.0" ;;
      6.3.*)        echo "rocprof-compute" ;;
      6.4.*)        echo "rocprof-compute" ;;
      7.0.*)        echo "rocprof-compute" ;;
      7.1.*)        echo "rocprof-compute" ;;
      *)            echo "" ;;
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
[ -n "${INSTALL_PREFIX}" ] || INSTALL_PREFIX="/opt/rocm-patches-${ROCM_VERSION}"
if [ -n "${ROCM_PATH_OVERRIDE}" ]; then
   ROCM_PATH="${ROCM_PATH_OVERRIDE}"
else
   ROCM_PATH="/opt/rocm-${ROCM_VERSION}"
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
      ${PKG_SUDO} ${DEB_FRONTEND} apt-get install -q -y \
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
#   * For 7.1.x specifically, the in-distribution rocprof-compute.bin
#      produced by rocm_setup.sh's nuitka build is still on disk
#      under ${ROCM_PATH}/bin/.  The overlay places another binary
#      earlier on PATH so the regression-test view of rocprof-compute
#      always resolves to the patches tree; the rocm_setup.sh-built
#      binary is left in place but shadowed.
#   * For 6.3.x there is no .exe to fall back to (the v3.0.0 / Omniperf
#      transition was still Python-only); build.sh is the only option.
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
      7.1.0) echo 'Upstream tag `rocm-7.1.0` -- monorepo (rocm-systems @ rocm-7.1.0), `projects/rocprofiler-compute` subtree.  rocm_setup.sh also builds a nuitka binary in `${ROCM_PATH}/bin/`; the overlay supersedes it via PATH ordering.' ;;
      7.1.1) echo 'Upstream tag `rocm-7.1.1` -- monorepo subtree.  rocm_setup.sh also builds a nuitka binary in `${ROCM_PATH}/bin/`; the overlay supersedes it via PATH ordering.' ;;
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
   if [ -e "${out_bin}" ] && [ "${REPLACE}" -eq 0 ]; then
      echo "[rocm_patches] ${out_bin} already exists -- skipping build (use --replace to force)"
   else
      echo "[rocm_patches] running nuitka build for rocprof-compute ${ROCM_VERSION} ..."
      echo "[rocm_patches]   (wall time ~25-30 min, peak ~10 GB RAM; runs on this host)"
      bash "${overlay_dir}/build.sh" || return 1
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
# patch_module_file
# -----------------
# Append, exactly once, an LD_LIBRARY_PATH overlay line to the
# rocm/${ROCM_VERSION}.lua module file written by rocm_setup.sh.
#
# Lmod's prepend_path is LIFO: a later prepend lands FIRST in the
# resolved path string, so the overlay line MUST be inserted AFTER the
# original `prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))`.
# We insert it immediately after that line, idempotently.
#
# Idempotency strategy:
#
# We detect a previous overlay edit by looking for ANY reference to
# `rocm-patches-${ROCM_VERSION}` in the modulefile -- not just our
# current ${INSTALL_PREFIX}/lib path. This catches:
#   * a prior run of this same script (same INSTALL_PREFIX) -- skip;
#   * a hand-applied edit by an admin (different absolute path
#     prefix, e.g. /shared/apps/.../opt/rocm-patches-X.Y.Z/lib) --
#     warn that the path differs from this run's INSTALL_PREFIX/lib
#     but DO NOT add a second line. The hand-applied entry is the
#     source of truth on that cluster; we don't second-guess it.
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

   # Pattern-based idempotency: any rocm-patches-${ROCM_VERSION} string
   # in the modulefile means somebody (this script on a previous run,
   # or a human admin) has already wired the overlay. Don't add a
   # second entry under any circumstances.
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
      return 0
   fi

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
   patch_module_file
   rc=$?
   if [ "${rc}" -eq 0 ]; then
      echo ""
      echo "[rocm_patches] ROCm ${ROCM_VERSION} module file overlay edit applied (backfill)."
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
         build_rocprof_compute && built_rocprof_compute=1 || rc=$? ;;
      *)
         echo "[rocm_patches] ERROR: no builder registered for bundle '${bundle}'" >&2
         rc=1 ;;
   esac
done

# patch_module_file() adds the LD_LIBRARY_PATH overlay required by the
# rocprof-sys bundle; only call it when that bundle was actually built.
if [ "${rc}" -eq 0 ] && [ "${built_rocprof_sys}" -eq 1 ]; then
   patch_module_file || rc=$?
fi

if [ "${rc}" -eq 0 ]; then
   echo ""
   echo "[rocm_patches] ROCm ${ROCM_VERSION} patch overlay applied successfully."
   if [ "${built_rocprof_sys}" -eq 1 ]; then
      echo "[rocm_patches]   rocprof-sys library: ${INSTALL_PREFIX}/lib/librocprof-sys.so.1.3.0"
   fi
   if [ "${built_rocprof_compute}" -eq 1 ]; then
      echo "[rocm_patches]   rocprof-compute:     ${INSTALL_PREFIX}/rocprof-compute/bin/rocprof-compute"
   fi
   echo "[rocm_patches]   module file:         ${MODULE_FILE}"
fi

exit ${rc}
