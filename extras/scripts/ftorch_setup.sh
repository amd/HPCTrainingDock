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
#
# Marker filename has to be derived from the basename of FTORCH_PATH (and
# NOT the literal "ftorch.SKIPPED") so it stays distinct across:
#   * gfortran vs amdflang installs   (ftorch-v* vs ftorch_amdflang-v*)
#   * different bound pytorch versions (-v<VER> tail differs)
# Otherwise a single ftorch.SKIPPED marker would shadow every other
# (toolchain, pytorch-version) cell in inventory_packages.py for the
# same rocmplus tree, mis-flagging working installs as 'N'. The marker
# strips the trailing -v<VER> from FTORCH_PATH's basename so the file is
# named e.g. ftorch.SKIPPED / ftorch_amdflang.SKIPPED -- inventory looks
# up ${pkg}.SKIPPED keyed on the cell's pkg name (ftorch /
# ftorch_amdflang per PKG_TO_MODULE_CAT), not the version-tagged dir
# basename, so this aligns with the consumer's lookup shape.
_ftorch_write_missing_prereq_marker() {
   local _skip_dir _mods _ftorch_basename _marker_name
   _skip_dir="$(dirname "${FTORCH_PATH}")"
   _ftorch_basename="$(basename "${FTORCH_PATH}")"
   # Strip the -v<VER> tail to recover the pkg name (ftorch / ftorch_amdflang).
   _marker_name="${_ftorch_basename%-v*}.SKIPPED"
   _mods=$(printf '%s ' "$@")
   ${SUDO} mkdir -p "${_skip_dir}" 2>/dev/null || true
   if [ ! -d "${_skip_dir}" ]; then
      echo "ftorch: could not create skip-marker dir ${_skip_dir}" >&2
      return 0
   fi
   ${SUDO} tee "${_skip_dir}/${_marker_name}" >/dev/null 2>/dev/null <<MARKER_EOF || true
SKIPPED package: ${_ftorch_basename%-v*}
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Fortran toolchain:    ${FC_COMPILER} (install prefix ${FTORCH_PATH})
Bound PyTorch:        ${PYTORCH_VERSION:-unresolved}
Bound PyTorch module: ${PYTORCH_MODULE}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    ftorch_setup.sh (preflight_modules)
Reason:          Required Lmod module(s) could not be loaded (needed: ${_mods}). Typical case: no ${PYTORCH_MODULE} module for this rocmplus tree. Install PyTorch for this SDK or include pytorch in --packages. See the log for the Lmod error.
MARKER_EOF
}

# Variables controlling setup process
ROCM_VERSION=6.2.0
BUILD_FTORCH=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/ftorch
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
FTORCH_PATH=/opt/rocmplus-${ROCM_VERSION}/ftorch
FTORCH_PATH_INPUT=""
PYTORCH_MODULE=pytorch
FTORCH_VERSION=""    # empty -> default branch (main); else passed to git checkout after clone
# PYTORCH_VERSION: the pytorch SDK release this ftorch is bound to. FTorch's
# .so + .mod artifacts embed libtorch's C++ ABI, so the install is only
# valid for the one pytorch version it was built against -- different
# pytorch versions ship different libtorch SONAMEs / headers and cannot
# share a single ftorch install. We therefore version the ftorch install
# dir + modulefile by PYTORCH_VERSION (NOT by FTorch's own upstream version
# tag, which is captured separately via --ftorch-version above and recorded
# in the modulefile whatis() line).
#
# Resolution order (highest priority first):
#   1. --pytorch-version <VER>  (explicit; main_setup.sh passes this when
#      iterating over multiple pytorch installs).
#   2. ${PYTORCH_MODULE} parsed as "pytorch/<VER>"  (e.g. when the operator
#      passed --pytorch-module pytorch/2.9.1 directly).
#   3. After preflight has loaded the pytorch module, scan LOADEDMODULES
#      for the resolved "pytorch/<VER>" token (handles --pytorch-module
#      pytorch with no explicit version: Lmod's default-version rule
#      picks one and we read the resolved value back out).
# All three paths populate the same PYTORCH_VERSION variable; the install
# dir / modulefile name / whatis() string then come from one source of truth.
PYTORCH_VERSION=""
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
   echo "  --pytorch-version [ PYTORCH_VERSION ] pytorch SDK release this ftorch will be bound to. The ftorch install dir + modulefile are versioned by THIS value (ftorch-v\${PYTORCH_VERSION}/ and \${MODULE_PATH}/\${PYTORCH_VERSION}.lua) so multiple pytorch versions can each have their own ftorch. Empty (default) -> auto-derive after the pytorch module is loaded (preflight stage); pass explicitly when --pytorch-module is bare 'pytorch' but you need to pin the install dir to a specific version up front."
   echo "  --install-path [ FTORCH_PATH ] default $FTORCH_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --ftorch-version [ FTORCH_VERSION ] FTorch upstream git tag/branch/commit to check out after clone (default: repo HEAD). Independent of --pytorch-version: this controls the source ref FTorch is BUILT FROM, --pytorch-version controls the libtorch ABI it is BUILT AGAINST. Recorded in the modulefile whatis() but NOT in the install path."
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
      "--pytorch-version")
          shift
          PYTORCH_VERSION=${1}
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
# (..._amdflang) and write a sibling modulefile under MODULE_PATH_amdflang
# so the gfortran and amdflang installs coexist. .mod files are not
# portable across Fortran compilers, so a single install cannot serve
# both toolchains. The _amdflang suffix on MODULE_PATH itself keeps the
# Lmod hierarchy clean: a user picks the toolchain at `module load ftorch`
# time by selecting either the ftorch/<pytorch-ver> or
# ftorch_amdflang/<pytorch-ver> module under whichever MODULE_PATH
# the site exposes.
case "${FC_COMPILER}" in
   gfortran|amdflang) ;;
   *)
      send-error "Unsupported --fc-compiler value: '${FC_COMPILER}' (expected: gfortran|amdflang)"
      ;;
esac
if [ "${FC_COMPILER}" = "amdflang" ]; then
   FTORCH_PATH=${FTORCH_PATH}_amdflang
   MODULE_PATH=${MODULE_PATH}_amdflang
fi

# ── BUILD_FTORCH=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
# Done BEFORE PYTORCH_VERSION resolution so the no-op path can return
# cleanly even if no pytorch module is loadable -- the orchestrator's
# DESELECTED branch only needs the exit code (NOOP_RC=43), not a
# resolved install path.
NOOP_RC=43
if [ "${BUILD_FTORCH}" = "0" ]; then
   echo "[ftorch BUILD_FTORCH=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── PYTORCH_VERSION resolution (see header comment block on PYTORCH_VERSION) ─
# We need the bound pytorch version BEFORE the --replace cleanup and
# existence guard below, because both consult the final FTORCH_PATH /
# MODULEFILE_NAME, and both of those are versioned by PYTORCH_VERSION.
# Three resolution paths, in priority order; the first that yields a
# non-empty value wins:
#
#   1. --pytorch-version <VER>: explicit, highest authority. main_setup.sh
#      always passes this when iterating over multiple pytorch installs
#      (PKG_VERSIONS_REQ[pytorch]).
#   2. --pytorch-module pytorch/<VER>: parse the version out of the
#      module token directly. main_setup.sh ALSO passes this so that
#      the leaf's preflight `module load` pins the same version Lmod
#      will expose to the build's cmake.
#   3. Lmod probe: query `module -t avail ${PYTORCH_MODULE}` and pick the
#      LATEST existing pytorch module (highest version). Used only for
#      standalone invocation where neither flag was passed (e.g. an
#      operator running ftorch_setup.sh by hand against an existing
#      rocmplus tree). We deliberately track the newest install rather
#      than the Lmod (D) default: each ROCm version ships a different
#      default pytorch, and the (D) marker is not guaranteed to point at
#      the newest one. Best-effort; failures fall through to the error
#      below. (In sweeps main_setup.sh resolves this and passes
#      --pytorch-version explicitly, so this path is the manual-run
#      equivalent of that same "latest existing" rule.)
if [[ -z "${PYTORCH_VERSION}" ]]; then
   case "${PYTORCH_MODULE}" in
      pytorch/*) PYTORCH_VERSION="${PYTORCH_MODULE#pytorch/}" ;;
   esac
fi
if [[ -z "${PYTORCH_VERSION}" ]]; then
   if ! type module >/dev/null 2>&1; then
      [ -r /etc/profile.d/lmod.sh ]         && . /etc/profile.d/lmod.sh
      [ -r /usr/share/lmod/lmod/init/bash ] && . /usr/share/lmod/lmod/init/bash
   fi
   if type module >/dev/null 2>&1; then
      # `module -t avail` prints one modulefile per line in machine-
      # parseable form; the default version is suffixed with `(D)`.
      # Collect every pytorch/<ver> candidate, strip the trailing
      # columns and the (D) marker, then pick the highest by version
      # sort (sort -V) so ftorch binds to the latest existing pytorch.
      _ML_AVAIL=$(module -t avail "${PYTORCH_MODULE}" 2>&1 || true)
      _candidates=()
      while IFS= read -r _line; do
         case "${_line}" in
            "${PYTORCH_MODULE}/"*)
               _ver="${_line#${PYTORCH_MODULE}/}"
               _ver="${_ver%%[[:space:]]*}"   # drop trailing columns
               _ver="${_ver%%(D)*}"           # drop Lmod default marker
               _ver="${_ver%/}"               # drop any trailing slash
               # Skip the tunableop variant modulefile. pytorch_setup.sh
               # publishes BOTH `pytorch/<VER>` and
               # `pytorch/<VER>_tunableop_enabled` (same install; the
               # tunableop one only flips a runtime env var). `sort -V`
               # ranks `<VER>_tunableop_enabled` ABOVE the plain `<VER>`,
               # so without this filter ftorch would bind to the tunableop
               # module. FTorch must bind to the regular pytorch module.
               case "${_ver}" in *_tunableop_enabled) continue ;; esac
               [[ -n "${_ver}" ]] && _candidates+=("${_ver}")
               ;;
         esac
      done <<< "${_ML_AVAIL}"
      if [[ "${#_candidates[@]}" -gt 0 ]]; then
         PYTORCH_VERSION=$(printf '%s\n' "${_candidates[@]}" | sort -V | tail -n1)
      fi
      unset _ML_AVAIL _line _ver _candidates
   fi
fi
if [[ -z "${PYTORCH_VERSION}" ]]; then
   send-error "Could not resolve PYTORCH_VERSION. Pass --pytorch-version <VER>, or --pytorch-module pytorch/<VER>, or ensure at least one '${PYTORCH_MODULE}/<VER>' Lmod modulefile exists so the install dir + modulefile name can be versioned by the latest one."
fi

# ── Final FTORCH_PATH + modulefile name (now version-keyed) ─────────
# Install layout (mirrors pytorch_setup.sh: pytorch-v<VER>/ + <VER>.lua):
#   gfortran:  ${ROCMPLUS}/ftorch-v${PYTORCH_VERSION}/
#              ${MODULE_PATH}/${PYTORCH_VERSION}.lua          -> ftorch/${VER}
#   amdflang:  ${ROCMPLUS}/ftorch_amdflang-v${PYTORCH_VERSION}/
#              ${MODULE_PATH}/${PYTORCH_VERSION}.lua          -> ftorch_amdflang/${VER}
# Note: the install dir gets BOTH the toolchain suffix (_amdflang on
# the basename, applied above) AND the pytorch-version suffix
# (-v<VER>, applied here). The basename order matters -- pytorch's
# version goes LAST so the dir matches `ftorch*-v*` for the inventory
# regex (ftorch / ftorch_amdflang -> -v<pytorch-ver> tail), parallel
# to pytorch-v<pytorch-ver>.
FTORCH_PATH="${FTORCH_PATH}-v${PYTORCH_VERSION}"
MODULEFILE_NAME="${PYTORCH_VERSION}.lua"

if [ "${REPLACE}" = "1" ]; then
   echo "[ftorch --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${FTORCH_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${MODULEFILE_NAME}"
   echo "  bound pytorch version: ${PYTORCH_VERSION}"
   ${SUDO} rm -rf "${FTORCH_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${MODULEFILE_NAME}"
   # Marker filename matches the basename-stripping done in
   # _ftorch_write_missing_prereq_marker (ftorch / ftorch_amdflang
   # without the -v<VER> tail) so the cleanup is symmetric.
   _ft_basename="$(basename "${FTORCH_PATH}")"
   _ft_mark="$(dirname "${FTORCH_PATH}")/${_ft_basename%-v*}.SKIPPED"
   ${SUDO} rm -f "${_ft_mark}"
   unset _ft_mark _ft_basename
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
   # attempted-but-failed marker (inventory 'F' glyph): persistent sibling
   # of the install dir that survives the rm -rf below; cleared on success.
   # Inventory tracks a single 'ftorch' row (the ftorch_amdflang flavor is
   # not a separate presence row), so one ftorch.FAILED marker suffices
   # regardless of which flavor FTORCH_PATH points at this run.
   _fail_marker="$(dirname "${FTORCH_PATH}")/ftorch.FAILED"
   if [ ${rc} -ne 0 ]; then
      ${SUDO:-sudo} mkdir -p "$(dirname "${FTORCH_PATH}")" 2>/dev/null || true
      ${SUDO:-sudo} tee "${_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: ftorch
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    ftorch_setup.sh (EXIT-trap fail marker)
Reason:          build exited rc=${rc}; partial install wiped (see log_ftorch_*.txt).
MARKER_EOF
   else
      ${SUDO:-sudo} rm -f "${_fail_marker}"
   fi
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
echo "ROCM_VERSION:    $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_FTORCH:    $BUILD_FTORCH"
echo "FC_COMPILER:     $FC_COMPILER"
echo "PYTORCH_VERSION: $PYTORCH_VERSION  (bound libtorch ABI; FTorch install + modulefile are versioned by this)"
echo "PYTORCH_MODULE:  $PYTORCH_MODULE"
echo "FTORCH_VERSION:  ${FTORCH_VERSION:-<repo HEAD>}  (FTorch upstream git ref)"
echo "FTORCH_PATH:     $FTORCH_PATH"
echo "MODULE_PATH:     $MODULE_PATH"
echo "MODULEFILE_NAME: $MODULEFILE_NAME"
echo "==================================="
echo ""

if [ "${BUILD_FTORCH}" = "0" ]; then

   echo "FTorch will not be built, according to the specified value of BUILD_FTORCH"
   echo "BUILD_FTORCH: $BUILD_FTORCH"
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
   # Cache restore is intentionally DISABLED in the versioned-install
   # regime: the historical /CacheFiles/.../ftorch.tgz tarballs were
   # captured against an unknown pytorch version (the legacy
   # ${ROCMPLUS}/ftorch/ single-install layout did not record one),
   # so they cannot be safely extracted into a versioned install dir
   # ftorch-v${PYTORCH_VERSION}/ -- we'd be claiming the bound pytorch
   # version is X.Y.Z when in fact the .so + .mod files inside were
   # built against some older pytorch release. Always build from
   # source so the (FTORCH_PATH, PYTORCH_VERSION) pairing is correct
   # by construction. The cache path is left here so an explicit
   # --rebuild-cache mode could be wired in later (would require
   # capturing pytorch version into the tarball name and validating
   # on extract; deferred until there's a wall-time motivation).
   if false && [ "${FC_COMPILER}" != "amdflang" ] && [ -f "${CACHE_FILES}/ftorch.tgz" ]; then
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
   # Modulefile name is ${PYTORCH_VERSION}.lua (bound libtorch ABI keyed
   # by the pytorch version this ftorch was built against). The
   # enclosing MODULE_PATH carries the _amdflang suffix when
   # --fc-compiler amdflang was passed, so the Lmod module name
   # becomes ftorch_amdflang/${VER} vs ftorch/${VER}. When the
   # amdflang build, also emit a prereq("amdclang") so consumers can't
   # load the amdflang ftorch into a gcc/gfortran environment (the .mod
   # files would not match -- see header for full rationale).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   FC_PREREQ_LINE=""
   if [ "${FC_COMPILER}" = "amdflang" ]; then
      FC_PREREQ_LINE='prereq("amdclang")'
   fi

   # Compute the version-pinned pytorch module name to LOAD from the
   # ftorch modulefile. Without this, the heredoc below would write
   # `load("pytorch")` (bare), which Lmod resolves to whichever pytorch
   # version is currently the default -- typically the highest. That
   # silently mismatches the libtorch ABI baked into ftorch's .so + .mod
   # whenever multiple pytorch installs coexist (the whole reason this
   # script is now versioned). Always pin the load target to the same
   # pytorch version we resolved + linked against above.
   #   PYTORCH_MODULE has form "pytorch" (bare)         -> pin to pytorch/${VER}
   #   PYTORCH_MODULE has form "pytorch/X.Y.Z"          -> use as-is (already pinned)
   #   PYTORCH_MODULE has form "<other>"                -> pin <other>/${VER}
   case "${PYTORCH_MODULE}" in
      */*) PYTORCH_MODULE_PINNED="${PYTORCH_MODULE}" ;;
      *)   PYTORCH_MODULE_PINNED="${PYTORCH_MODULE}/${PYTORCH_VERSION}" ;;
   esac

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${MODULEFILE_NAME}
	whatis("FTorch: a library for directly calling PyTorch ML models from Fortran")
	whatis("Bound PyTorch:    ${PYTORCH_VERSION} (libtorch ABI is pinned; see Lmod load() below)")
	whatis("Bound PyTorch module: ${PYTORCH_MODULE_PINNED}")
	whatis("Fortran toolchain: ${FC_COMPILER}")
	whatis("FTorch upstream ref: ${FTORCH_VERSION:-<repo HEAD>}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prereq("${ROCM_MODULE_NAME}")
	${FC_PREREQ_LINE}
	load("${PYTORCH_MODULE_PINNED}")
	prepend_path("LD_LIBRARY_PATH", pathJoin("${FTORCH_PATH}", "lib"))
	setenv("FTORCH_HOME","${FTORCH_PATH}")
	setenv("FTorch_DIR","${FTORCH_PATH}")

EOF

fi
