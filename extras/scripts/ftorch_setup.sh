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

# Best-effort sibling marker for bare_system/inventory_packages.py ('N' cell
# when FTorch cannot run because required modules are missing — mirrors
# pytorch_setup.sh's pytorch.SKIPPED pattern).
_ftorch_write_missing_prereq_marker() {
   local _skip_dir _mods
   _skip_dir="$(dirname "${FTORCH_PATH}")"
   _mods=$(printf '%s ' "$@")
   ${SUDO} mkdir -p "${_skip_dir}" 2>/dev/null || true
   if [ ! -d "${_skip_dir}" ]; then
      echo "ftorch: could not create skip-marker dir ${_skip_dir}" >&2
      return 0
   fi
   ${SUDO} tee "${_skip_dir}/ftorch.SKIPPED" >/dev/null 2>/dev/null <<MARKER_EOF || true
SKIPPED package: ftorch
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Fortran toolchain: ${FC_COMPILER} (install prefix ${FTORCH_PATH})
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    ftorch_setup.sh (preflight_modules)
Reason:          Required Lmod module(s) could not be loaded (needed: ${_mods}). Typical case: no ${PYTORCH_MODULE} module for this rocmplus tree. Install PyTorch for this SDK or include pytorch in --packages. See the log for the Lmod error.
MARKER_EOF
}

# Variables controlling setup process
ROCM_VERSION=6.2.0
BUILD_FTORCH=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/ftorch
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
FTORCH_PATH=/opt/rocmplus-${ROCM_VERSION}/ftorch
FTORCH_PATH_INPUT=""
PYTORCH_MODULE=pytorch
FTORCH_VERSION=""    # empty -> default branch (main); else passed to git checkout after clone
# --fc-compiler {gfortran|amdflang}: choose Fortran compiler for the FTorch
# build. Default is gfortran (matches Ubuntu 22.04 system default). Selecting
# `amdflang` loads the rocm-tied `amdclang` modulefile (which sets
# CC=amdclang, CXX=amdclang++, FC=amdflang -- amdflang-new on ROCm 7.x,
# amdflang-classic on ROCm 6.x), appends `_amdflang` to BOTH ${FTORCH_PATH}
# and ${MODULE_PATH}, and renames the modulefile to dev_amdflang.lua so
# the gfortran and amdflang installs coexist side by side. This mirrors
# the `--use-amdflang 1` suffix pattern in petsc_setup.sh.
# Rationale: Fortran .mod files are NOT compiler-portable -- gfortran's
# gzip-compressed .mod cannot be consumed by amdflang and vice versa --
# so a single ftorch install cannot serve both toolchains.
FC_COMPILER=gfortran
# --replace 1: rm -rf prior install dir + dev.lua before build.
# (When --fc-compiler amdflang, the suffix _amdflang is added to BOTH
# paths above, so we always clean whatever the resolved
# FTORCH_PATH/MODULE_PATH is.)
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
   echo "  --build-ftorch [ BUILD_FTORCH ] default $BUILD_FTORCH "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --pytorch-module [ PYTORCH_MODULE ] default $PYTORCH_MODULE"
   echo "  --install-path [ FTORCH_PATH ] default $FTORCH_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --ftorch-version [ FTORCH_VERSION ] git tag/branch/commit to check out after clone (default: repo HEAD)"
   echo "  --fc-compiler [ gfortran|amdflang ] Fortran compiler for the build, default $FC_COMPILER. amdflang appends _amdflang to install + modulefile paths and loads the rocm-tied amdclang module."
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
      "--build-ftorch")
          shift
          BUILD_FTORCH=${1}
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
          FTORCH_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
	  reset-last
          ;;
      "--pytorch-module")
          shift
          PYTORCH_MODULE=${1}
	  reset-last
          ;;
      "--ftorch-version")
          shift
          FTORCH_VERSION=${1}
          reset-last
          ;;
      "--fc-compiler")
          shift
          FC_COMPILER=${1}
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

if [ "${FTORCH_PATH_INPUT}" != "" ]; then
   FTORCH_PATH=${FTORCH_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   FTORCH_PATH=/opt/rocmplus-${ROCM_VERSION}/ftorch
fi

# ── --fc-compiler validation + path/modulefile suffix ───────────────
# Mirrors petsc_setup.sh's --use-amdflang 1 suffix pattern: when the
# operator picks the amdflang toolchain we install to a sibling location
# (FTORCH_PATH_amdflang) and write a sibling modulefile (dev_amdflang.lua
# under MODULE_PATH_amdflang) so the gfortran and amdflang installs
# coexist. .mod files are not portable across Fortran compilers, so a
# single install cannot serve both toolchains. The modulefile suffix
# (_amdflang on MODULE_PATH itself) keeps the Lmod hierarchy clean: a
# user picks the toolchain at `module load ftorch` time by selecting
# either the dev or dev_amdflang version under whichever MODULE_PATH
# the site exposes.
case "${FC_COMPILER}" in
   gfortran|amdflang) ;;
   *)
      send-error "Unsupported --fc-compiler value: '${FC_COMPILER}' (expected: gfortran|amdflang)"
      ;;
esac
# Modulefile inside the per-toolchain MODULE_PATH always stays dev.lua
# so the Lmod hierarchy is symmetrical:
#   ftorch/dev          (gfortran build)
#   ftorch_amdflang/dev (amdflang build)
# i.e. the *directory* (= Lmod module name) carries the toolchain tag,
# not the file name. This matches petsc's _amdflang suffix convention.
MODULEFILE_NAME=dev.lua
if [ "${FC_COMPILER}" = "amdflang" ]; then
   FTORCH_PATH=${FTORCH_PATH}_amdflang
   MODULE_PATH=${MODULE_PATH}_amdflang
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is dev.lua in both cases; the install dir +
# enclosing module dir carry the _amdflang suffix when --fc-compiler
# amdflang was passed (see suffix block above).
# ── BUILD_FTORCH=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_FTORCH}" = "0" ]; then
   echo "[ftorch BUILD_FTORCH=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[ftorch --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${FTORCH_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${MODULEFILE_NAME}"
   ${SUDO} rm -rf "${FTORCH_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${MODULEFILE_NAME}"
   _ft_mark="$(dirname "${FTORCH_PATH}")/ftorch.SKIPPED"
   ${SUDO} rm -f "${_ft_mark}"
   unset _ft_mark
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${FTORCH_PATH}" ]; then
   echo ""
   echo "[ftorch existence-check] ${FTORCH_PATH} already installed; skipping."
   echo "                         pass --replace 1 to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (FTORCH_BUILD_ROOT, set
# under BUILD_FTORCH=1) PLUS fail-cleanup of partial install +
# modulefile. Replaces inline `trap '... rm FTORCH_BUILD_ROOT ...' EXIT`.
_ftorch_on_exit() {
   local rc=$?
   [ -n "${FTORCH_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${FTORCH_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[ftorch fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${FTORCH_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${MODULEFILE_NAME}"
   elif [ ${rc} -ne 0 ]; then
      echo "[ftorch fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _ftorch_on_exit EXIT

echo ""
echo "==================================="
echo "Starting FTorch Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_FTORCH: $BUILD_FTORCH"
echo "FC_COMPILER: $FC_COMPILER"
echo "FTORCH_PATH: $FTORCH_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

if [ "${BUILD_FTORCH}" = "0" ]; then

   echo "FTorch will not be built, according to the specified value of BUILD_FTORCH"
   echo "BUILD_FTORCH: $BUILD_FTORCH"
   exit

else
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

   # Provenance: capture this leaf script's git state for the modulefile
   # whatis() line emitted by the heredoc below. Self-contained (no
   # source dependency); falls back to "unknown" when the install runs
   # from a stripped-of-.git context (Docker layer, release tarball, or
   # git binary missing).
   #
   # Why the absolute-path dance: BASH_SOURCE[0] is whatever path was used
   # to invoke the script -- often the relative `extras/scripts/ftorch_setup.sh`
   # when called from bare_system/main_setup.sh. Passing that relative path
   # to `git -C "${_leaf_dir}" log -- "${BASH_SOURCE[0]}"` makes git look
   # for `${_leaf_dir}/extras/scripts/ftorch_setup.sh` (a path that does
   # not exist), `git log` succeeds with empty output, and
   # LEAF_SCRIPT_COMMIT ends up as the empty string -- which is what
   # produced the `whatis("Built by: ftorch_setup.sh@ (clean)")` lines
   # (no SHA, no "unknown") that the 2026-05-08 audit flagged across every
   # rocmplus-* ftorch + ftorch_amdflang modulefile in this sweep.
   # Absolutize once, here, and feed the absolute path to every git query
   # (matches cupy_setup.sh).
   LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
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

   # Per-job throwaway build dir; replaces a fixed `cd /tmp` (with a
   # later `rm -rf FTorch`) that would race with any other concurrent
   # ftorch build on the same node.
   FTORCH_BUILD_ROOT=$(mktemp -d -t ftorch-build.XXXXXX)
   # NOTE: build-dir cleanup is consolidated into _ftorch_on_exit
   # installed above (so the same EXIT handler also does fail-cleanup
   # of any partial install / modulefile).
   cd "${FTORCH_BUILD_ROOT}"

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   # Cached tarballs in /CacheFiles only exist for the gfortran build
   # (the historical default); they bake gfortran .mod files which can't
   # be consumed by amdflang. Skip the cache restore path for the
   # amdflang variant so it always builds from source.
   if [ "${FC_COMPILER}" != "amdflang" ] && [ -f "${CACHE_FILES}/ftorch.tgz" ]; then
      echo ""
      echo "============================"
      echo " Installing Cached FTorch"
      echo "============================"
      echo ""

      # Install next to CMAKE_INSTALL_PREFIX: tarball layout matches a
      # rocmplus root with a top-level `ftorch/` (same as historical
      # cache capture under /opt/rocmplus-${ROCM_VERSION}/). Honor
      # --install-path / shared-apps trees; do not hardcode /opt.
      FTORCH_PARENT="$(dirname "${FTORCH_PATH}")"
      echo "ftorch cache: extracting ${CACHE_FILES}/ftorch.tgz into ${FTORCH_PARENT}"
      ${SUDO} mkdir -p "${FTORCH_PARENT}"
      ${SUDO} tar -xzpf "${CACHE_FILES}/ftorch.tgz" -C "${FTORCH_PARENT}"
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/ftorch.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building FTorch"
      echo "============================"
      echo ""

      # When --fc-compiler amdflang, also preflight the rocm-tied
      # `amdclang` module: it sets CC=amdclang, CXX=amdclang++, FC=amdflang
      # (and exports OMPI_CC/CXX/FC for OpenMPI wrappers). It must be
      # loaded BEFORE the FTorch cmake invocation so cmake auto-detects
      # the AMD toolchain rather than falling back to gcc/gfortran.
      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${PYTORCH_MODULE}" )
      if [ "${FC_COMPILER}" = "amdflang" ]; then
         REQUIRED_MODULES+=( "amdclang" )
      fi
      preflight_modules "${REQUIRED_MODULES[@]}" || {
         _rc=$?
         if [ "${_rc}" -eq "${MISSING_PREREQ_RC}" ]; then
            _ftorch_write_missing_prereq_marker "${REQUIRED_MODULES[@]}"
         fi
         exit "${_rc}"
      }

      if [ -d "$FTORCH_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${FTORCH_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p $FTORCH_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $FTORCH_PATH
      fi

      git clone https://github.com/Cambridge-ICCS/FTorch.git
      if [ -n "${FTORCH_VERSION}" ]; then
         echo "Checking out FTorch ref: ${FTORCH_VERSION}"
         (cd FTorch && git checkout "${FTORCH_VERSION}")
      fi
      cd FTorch

      mkdir build && cd build

      # PyTorch bundles its own cmake/ctest/cpack/etc. under
      # ${PYTORCH_PATH}/bin whose shebangs point at the build venv
      # (#!/home/admin/pytorch_build/bin/python3). That venv is deleted
      # at the end of pytorch_setup.sh, so execve returns ENOENT on
      # the interpreter ("bad interpreter" -> exit 126). The pytorch
      # module load above prepends ${PYTORCH_PATH}/bin to PATH, so a
      # bare `cmake` would resolve to that broken script. Resolve a
      # system cmake explicitly by stripping any pytorch bin dir from
      # PATH for this lookup. Tracks audit_2026_05_01.md Issue 5; the
      # root cause is the unconditional shebang rewrite that should be
      # applied in pytorch_setup.sh (deferred fix).
      #
      # 8063 audit: the prior regex `/pytorch/.*/bin$` required at
      # least one path component between `/pytorch/` and `/bin`, but
      # pytorch_setup.sh installs to ${ROCMPLUS}/pytorch-v${VERSION}/
      # pytorch/bin (no intermediate component) so the regex never
      # matched and the broken cmake stayed first on PATH. Switch to
      # filtering by the install-root naming convention `pytorch-v`
      # (set in pytorch_setup.sh:61, INSTALL_PATH=...pytorch-v${VER})
      # which uniquely identifies our install across versions and
      # cannot be defeated by adding/removing intermediate path
      # components in a future module layout. (Option B from the
      # 8063 audit; PYTORCH_PATH isn't exported by the pytorch
      # modulefile so we can't filter by absolute path here.)
      CMAKE_BIN=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/pytorch-v[^/]*/' | paste -sd:) command -v cmake)
      if [ ! -x "${CMAKE_BIN}" ]; then
         CMAKE_BIN=/usr/bin/cmake
      fi
      echo "ftorch: using cmake at ${CMAKE_BIN} (head -1: $(head -1 "${CMAKE_BIN}" 2>/dev/null))"

      # When --fc-compiler amdflang, point cmake explicitly at the
      # amdflang binary that the `amdclang` module exported via $FC,
      # plus the matching C/C++ compilers. This belt-and-suspenders is
      # needed because cmake caches the auto-detected compiler on the
      # first configure (so a later toolchain swap inside the same
      # build dir would silently keep gfortran). Falls back to
      # ${ROCM_PATH}/llvm/bin/amdflang if $FC was not exported (e.g.
      # the amdclang module landed in a non-standard location).
      CMAKE_FC_ARGS=()
      if [ "${FC_COMPILER}" = "amdflang" ]; then
         AMDFLANG_BIN="${FC:-${ROCM_PATH}/llvm/bin/amdflang}"
         AMDCLANG_BIN="${CC:-${ROCM_PATH}/llvm/bin/amdclang}"
         AMDCLANGXX_BIN="${CXX:-${ROCM_PATH}/llvm/bin/amdclang++}"
         echo "ftorch: building with AMD toolchain"
         echo "  CC  = ${AMDCLANG_BIN}"
         echo "  CXX = ${AMDCLANGXX_BIN}"
         echo "  FC  = ${AMDFLANG_BIN}"
         CMAKE_FC_ARGS+=( "-DCMAKE_C_COMPILER=${AMDCLANG_BIN}" )
         CMAKE_FC_ARGS+=( "-DCMAKE_CXX_COMPILER=${AMDCLANGXX_BIN}" )
         CMAKE_FC_ARGS+=( "-DCMAKE_Fortran_COMPILER=${AMDFLANG_BIN}" )
      fi

      "${CMAKE_BIN}" -DCMAKE_INSTALL_PREFIX=$FTORCH_PATH  -DGPU_DEVICE=HIP \
         "${CMAKE_FC_ARGS[@]}" ..
      make -j
      ${SUDO} make install

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find $FTORCH_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $FTORCH_PATH -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w $FTORCH_PATH
      fi

      # cleanup: trap handles ${FTORCH_BUILD_ROOT}/FTorch
      cd /
      if [ "${FC_COMPILER}" = "amdflang" ]; then
         module unload amdclang 2>/dev/null || true
      fi
      module unload ${ROCM_MODULE_NAME}
      module unload ${PYTORCH_MODULE}
   fi

   # Create a module file for ftorch.
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   #
   # Modulefile name is always dev.lua; the enclosing MODULE_PATH carries
   # the _amdflang suffix when --fc-compiler amdflang was passed (so the
   # Lmod module name becomes ftorch_amdflang vs ftorch). When the
   # amdflang build, also emit a prereq("amdclang") so consumers can't
   # load the amdflang ftorch into a gcc/gfortran environment (the .mod
   # files would not match -- see header for full rationale).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   FC_PREREQ_LINE=""
   if [ "${FC_COMPILER}" = "amdflang" ]; then
      FC_PREREQ_LINE='prereq("amdclang")'
   fi

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${MODULEFILE_NAME}
	whatis("FTorch: a library for directly calling PyTorch ML models from Fortran")
	whatis("Fortran toolchain: ${FC_COMPILER}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prereq("${ROCM_MODULE_NAME}")
	${FC_PREREQ_LINE}
	load("${PYTORCH_MODULE}")
	prepend_path("LD_LIBRARY_PATH", pathJoin("${FTORCH_PATH}", "lib"))
	setenv("FTORCH_HOME","${FTORCH_PATH}")
	setenv("FTorch_DIR","${FTORCH_PATH}")

EOF

fi
