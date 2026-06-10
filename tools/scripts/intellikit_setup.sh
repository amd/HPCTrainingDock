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
ROCM_VERSION=6.4.3
BUILD_INTELLIKIT=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AMDResearchTools/intellikit
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
INTELLIKIT_PATH=""           # default derived below from INTELLIKIT_VERSION
INTELLIKIT_PATH_INPUT=""
# --install-path: parent dir; the script appends intellikit-${INTELLIKIT_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version (mirrors mdb_setup.sh's path convention).
# --install-path-no-version (full leaf dir, no version appended) wins
# over --install-path when both are set, for callers that need exact
# control of the final install directory.
ROCMPLUS_PATH_INPUT=""
# IntelliKit has no published release tags; "main" is both the git ref
# (--ref to pip) and the version token used for the install dir name and
# the modulefile name. Pass --intellikit-version <branch|tag|commit> to
# build a different ref.
INTELLIKIT_VERSION="main"
# IntelliKit upstream repo. Each tool is a subdirectory installed via
# pip's git+...#subdirectory= VCS support.
INTELLIKIT_REPO="https://github.com/AMDResearch/intellikit.git"
# The full monorepo tool set. Override with --intellikit-tools "a b c".
INTELLIKIT_TOOLS="accordo kerncap linex metrix nexus rocm_mcp uprof_mcp"
# Optional explicit Python3 minor version (e.g. 12 -> python3.12). Empty
# means "use python3". IntelliKit requires Python 3.10+.
PYTHON_VERSION=""
# --replace 1: rm -rf prior install dir + ${INTELLIKIT_VERSION}.lua before build.
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
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-intellikit [ BUILD_INTELLIKIT ] master gate; 0 = exit NOOP_RC, default $BUILD_INTELLIKIT"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path-no-version [ INTELLIKIT_PATH ] default $INTELLIKIT_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), INTELLIKIT_PATH = ROCMPLUS_PATH/intellikit-\${INTELLIKIT_VERSION}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --intellikit-version [ INTELLIKIT_VERSION ] git ref (branch/tag/commit) to install; also names the install dir + modulefile (default: $INTELLIKIT_VERSION)"
   echo "  --intellikit-tools [ INTELLIKIT_TOOLS ] space-separated subset of monorepo packages to install (default: \"$INTELLIKIT_TOOLS\")"
   echo "  --python-version [ PYTHON_VERSION ] minor version of Python3 to build the venv with (e.g. 12 -> python3.12); IntelliKit needs 3.10+. Default: python3"
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
      "--build-intellikit")
          shift
          BUILD_INTELLIKIT=${1}
          reset-last
          ;;
      "--intellikit-version")
          shift
          INTELLIKIT_VERSION=${1}
          reset-last
          ;;
      "--intellikit-tools")
          shift
          INTELLIKIT_TOOLS=${1}
          reset-last
          ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
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
          INTELLIKIT_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
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

# Resolve INTELLIKIT_PATH: explicit no-version > parent dir + appended
# version > /opt/rocmplus-${ROCM_VERSION}/intellikit-${INTELLIKIT_VERSION}
# default. Matches the same priority order as mdb_setup.sh.
if [ "${INTELLIKIT_PATH_INPUT}" != "" ]; then
   INTELLIKIT_PATH=${INTELLIKIT_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   INTELLIKIT_PATH=${ROCMPLUS_PATH_INPUT}/intellikit-${INTELLIKIT_VERSION}
else
   INTELLIKIT_PATH=/opt/rocmplus-${ROCM_VERSION}/intellikit-${INTELLIKIT_VERSION}
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is ${INTELLIKIT_VERSION}.lua to match the
# `tee ${MODULE_PATH}/${INTELLIKIT_VERSION}.lua` write below.
# ── BUILD_INTELLIKIT=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_INTELLIKIT}" = "0" ]; then
   echo "[intellikit BUILD_INTELLIKIT=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[intellikit --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INTELLIKIT_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${INTELLIKIT_VERSION}.lua"
   ${SUDO} rm -rf "${INTELLIKIT_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${INTELLIKIT_VERSION}.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${INTELLIKIT_PATH}" ]; then
   echo ""
   echo "[intellikit existence-check] ${INTELLIKIT_PATH} already installed; skipping."
   echo "                             pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (INTELLIKIT_BUILD_ROOT, set
# under BUILD_INTELLIKIT=1) PLUS fail-cleanup of partial install +
# modulefile. Replaces inline build-dir-only traps.
_intellikit_on_exit() {
   local rc=$?
   [ -n "${INTELLIKIT_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${INTELLIKIT_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[intellikit fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${INTELLIKIT_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${INTELLIKIT_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[intellikit fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _intellikit_on_exit EXIT

# IntelliKit targets AMD GPUs through ROCm (kerncap needs hipcc, nexus
# needs ROCm LLVM at build time), so we preflight rocm/<ver> here.
#
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
REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" )
preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

echo ""
echo "==================================="
echo "Starting IntelliKit Install with"
echo "ROCM_VERSION:       $ROCM_VERSION"
echo "AMDGPU_GFXMODEL:    $AMDGPU_GFXMODEL"
echo "BUILD_INTELLIKIT:   $BUILD_INTELLIKIT"
echo "INTELLIKIT_VERSION: $INTELLIKIT_VERSION"
echo "INTELLIKIT_TOOLS:   $INTELLIKIT_TOOLS"
echo "INTELLIKIT_PATH:    $INTELLIKIT_PATH"
echo "MODULE_PATH:        $MODULE_PATH"
echo "==================================="
echo ""

# Per-job throwaway build dir; the venv lives here and is discarded by
# the EXIT trap. pip install --target lands the packages in
# ${INTELLIKIT_PATH} so the install survives independently of the venv.
INTELLIKIT_BUILD_ROOT=$(mktemp -d -t intellikit-build.XXXXXX)
# NOTE: build-dir cleanup is consolidated into the _intellikit_on_exit
# trap installed above (so the same EXIT handler also does fail-cleanup
# of any partial install / modulefile).
cd "${INTELLIKIT_BUILD_ROOT}"

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
if [ -f ${CACHE_FILES}/intellikit-${INTELLIKIT_VERSION}.tgz ]; then
   echo ""
   echo "============================"
   echo " Installing Cached IntelliKit"
   echo "============================"
   echo ""

   # Install the cached version. Cache tar must be named
   # intellikit-${INTELLIKIT_VERSION}.tgz and contain a top-level
   # directory intellikit-${INTELLIKIT_VERSION}/ so it lands directly at
   # ${INTELLIKIT_PATH} when extracted under /opt/rocmplus-X.
   ${SUDO} mkdir -p ${INTELLIKIT_PATH}
   cd /opt/rocmplus-${ROCM_VERSION}
   ${SUDO} tar -xzpf ${CACHE_FILES}/intellikit-${INTELLIKIT_VERSION}.tgz
   chown -R root:root ${INTELLIKIT_PATH}
   if [ "${USER}" != "sysadmin" ]; then
      ${SUDO} rm ${CACHE_FILES}/intellikit-${INTELLIKIT_VERSION}.tgz
   fi
else
   echo ""
   echo "============================"
   echo " Building IntelliKit"
   echo "============================"
   echo ""

   # ── Native deps for accordo + nexus ───────────────────────────────
   # accordo and nexus compile C++ (via KernelDB) during pip install and
   # need cmake + libdwarf-dev + libzstd-dev (libdwarf-devel/libzstd-devel
   # on Fedora/RHEL). Mirrors upstream install/tools/install.sh's
   # check_system_deps. Only install when one of those tools is selected.
   #
   # NOTE: cmake is intentionally NOT installed here -- this image ships a
   # pip-installed cmake under /usr/local pinned to a specific version, and
   # an apt cmake would shadow/conflict with it. We assume cmake is already
   # on PATH; only the dwarf/zstd dev headers are installed via the package
   # manager.
   if [[ " ${INTELLIKIT_TOOLS} " == *" accordo "* ]] || [[ " ${INTELLIKIT_TOOLS} " == *" nexus "* ]]; then
      if ! command -v cmake >/dev/null 2>&1; then
         echo "WARNING: cmake not found on PATH; accordo/nexus C++ build needs it"
         echo "         (expected pip-installed cmake under /usr/local)."
      fi
      if command -v apt-get >/dev/null 2>&1; then
         ${SUDO} apt-get update || true
         # DEBIAN_FRONTEND=noninteractive + NEEDRESTART_MODE=a so the
         # post-install needrestart prompt can't block the build (repo
         # convention; see scorep_setup.sh / hpctoolkit_setup.sh).
         ${SUDO} DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -q -y libdwarf-dev libzstd-dev
      elif command -v dnf >/dev/null 2>&1; then
         ${SUDO} dnf install -y libdwarf-devel libzstd-devel
      elif command -v yum >/dev/null 2>&1; then
         ${SUDO} yum install -y libdwarf-devel libzstd-devel
      else
         echo "WARNING: no apt-get/dnf/yum found; ensure libdwarf-dev, libzstd-dev"
         echo "         are present or the accordo/nexus C++ build will fail."
      fi
   fi

   if [ -d "$INTELLIKIT_PATH" ]; then
      # don't use sudo if user has write access to install path
      if [ -w ${INTELLIKIT_PATH} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
      # if install path does not exist yet, the check on write access will fail
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   ${SUDO} mkdir -p $INTELLIKIT_PATH
   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod a+w $INTELLIKIT_PATH
   fi

   # Build inside a per-job venv (cleaner than touching the host python3)
   # and install into ${INTELLIKIT_PATH} via pip --target so the install
   # is self-contained and doesn't depend on the venv surviving past
   # end-of-build. /usr/bin/env python3 (after the shebang rewrite below)
   # will resolve to whichever python the consumer has on PATH at
   # `module load intellikit` time, with ${INTELLIKIT_PATH} on PYTHONPATH.
   PYTHON=python3
   if [ "${PYTHON_VERSION}" != "" ]; then
      PYTHON=python3.${PYTHON_VERSION}
   fi
   ${PYTHON} -m venv "${INTELLIKIT_BUILD_ROOT}/intellikit_build"
   # shellcheck disable=SC1091
   source "${INTELLIKIT_BUILD_ROOT}/intellikit_build/bin/activate"
   python3 -m pip install --upgrade pip

   # nexus needs ROCm LLVM at C++ build time; point its CMake at the
   # loaded ROCm SDK. kerncap picks up hipcc from the same SDK on PATH.
   #
   # accordo + nexus link against the HSA runtime via their FindHSA.cmake,
   # which only hard-codes /opt/rocm{,64}/lib in its PATHS. On this image
   # ROCm lives under ${ROCM_PATH} (e.g. /shared/.../rocm-7.2.3), so the
   # library probe returns HSA_LIBRARY-NOTFOUND even though CPATH lets the
   # header probe succeed (find_library does not search LD_LIBRARY_PATH).
   # Put ${ROCM_PATH} on CMAKE_PREFIX_PATH so find_library/find_path pick
   # up ${ROCM_PATH}/lib and ${ROCM_PATH}/include.
   if [ -n "${ROCM_PATH:-}" ]; then
      export LLVM_INSTALL_DIR="${ROCM_PATH}/llvm"
      export CMAKE_PREFIX_PATH="${ROCM_PATH}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
   fi

   # ── Clone the monorepo once so we can patch accordo's CMake ────────
   # We install each tool from this local checkout (equivalent to pip's
   # git+...#subdirectory= form). A non-shallow clone keeps the .git +
   # tags so setuptools-scm derives proper package versions. --branch
   # handles a branch/tag ref; the fallback handles a bare commit SHA.
   INTELLIKIT_SRC="${INTELLIKIT_BUILD_ROOT}/intellikit-src"
   if ! git clone --branch "${INTELLIKIT_VERSION}" "${INTELLIKIT_REPO}" "${INTELLIKIT_SRC}" 2>/dev/null; then
      git clone "${INTELLIKIT_REPO}" "${INTELLIKIT_SRC}"
      git -C "${INTELLIKIT_SRC}" checkout "${INTELLIKIT_VERSION}"
   fi

   # ── accordo clang-22 / HIP-mode workaround ────────────────────────
   # accordo/src/accordo.hip contains no device kernels -- only HSA + HIP
   # *host* APIs -- but is compiled as the HIP language. AMD clang >= ~20
   # (ROCm 7.2.x) rejects nlohmann/json's implicit conversion operator
   # during HIP-mode host/device overload resolution (the identical TU
   # compiles cleanly as plain `-x c++`; only `-x hip` fails). So compile
   # that device-free TU as C++ and link the HIP host runtime explicitly
   # (HIP-language mode was auto-adding it). TARGET_DIRECTORY is required
   # because the accordo target is created in the parent CMakeLists, so a
   # plain set_source_files_properties in src/CMakeLists.txt is not
   # visible to it. Full write-up + upstream bug report:
   # tools/scripts/intellikit_accordo_clang22_bug.md
   ACCORDO_CML="${INTELLIKIT_SRC}/accordo/src/CMakeLists.txt"
   if [ -f "${ACCORDO_CML}" ] && ! grep -q "TARGET_DIRECTORY accordo" "${ACCORDO_CML}"; then
      echo "[intellikit] applying accordo clang-22 HIP workaround"
      python3 - "${ACCORDO_CML}" <<'PYEOF'
import sys
f = sys.argv[1]
s = open(f).read()
if "find_package(hip REQUIRED)" not in s:
    s = s.replace("find_package(HSA REQUIRED)",
                  "find_package(HSA REQUIRED)\nfind_package(hip REQUIRED)", 1)
anchor = "        ${CMAKE_CURRENT_SOURCE_DIR}/accordo.hip\n)\n"
inject = anchor + (
    "\n# WORKAROUND (HPCTrainingDock): accordo.hip has no device kernels; compile it\n"
    "# as plain C++ to dodge an AMD clang 22 HIP-mode overload-resolution bug that\n"
    "# rejects nlohmann/json's implicit conversion operator. TARGET_DIRECTORY is\n"
    "# required because the accordo target is defined in the parent CMakeLists.\n"
    "set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/accordo.hip\n"
    "    TARGET_DIRECTORY accordo\n"
    "    PROPERTIES LANGUAGE CXX)\n"
)
if anchor in s and "TARGET_DIRECTORY accordo" not in s:
    s = s.replace(anchor, inject, 1)
if "hip::host" not in s:
    s = s.replace("        hsa::hsa\n", "        hsa::hsa\n        hip::host\n", 1)
open(f, "w").write(s)
print("accordo CMake patched")
PYEOF
   fi

   # Install each selected tool from its monorepo subdirectory in the
   # local checkout. The tools are independent packages, so a single tool
   # that fails to build (e.g. a still-unpatched upstream C++/compiler
   # mismatch on a given ROCm toolchain) must NOT abort the whole install
   # -- we record per-tool PASS/FAIL, keep going, and only hard fail (so
   # the EXIT trap wipes the dir) if nothing installed at all.
   INSTALL_OK=()
   INSTALL_FAILED=()
   for tool in ${INTELLIKIT_TOOLS}; do
      echo ""
      echo "---- installing IntelliKit tool: ${tool} ----"
      if [ ! -d "${INTELLIKIT_SRC}/${tool}" ]; then
         echo "WARNING: tool '${tool}' not found in checkout (${INTELLIKIT_SRC}/${tool}); skipping."
         INSTALL_FAILED+=("${tool}")
         continue
      fi
      if python3 -m pip install --target=$INTELLIKIT_PATH \
            "${INTELLIKIT_SRC}/${tool}" --no-cache; then
         INSTALL_OK+=("${tool}")
      else
         echo "WARNING: IntelliKit tool '${tool}' failed to install; continuing with the rest."
         INSTALL_FAILED+=("${tool}")
      fi
   done
   deactivate

   echo ""
   echo "IntelliKit install summary:"
   echo "  installed: ${INSTALL_OK[*]:-<none>}"
   echo "  failed:    ${INSTALL_FAILED[*]:-<none>}"
   if [ ${#INSTALL_OK[@]} -eq 0 ]; then
      echo "ERROR: no IntelliKit tools installed successfully; failing."
      exit 1
   fi
   # The modulefile advertises only the tools that actually installed.
   INTELLIKIT_TOOLS="${INSTALL_OK[*]}"

   export PYTHONPATH=$PYTHONPATH:$INTELLIKIT_PATH

   # ── Shebang rewrite ────────────────────────────────────────────
   # pip console_script wrappers (metrix, kerncap, accordo, *-mcp) get
   # baked with `#!${INTELLIKIT_BUILD_ROOT}/intellikit_build/bin/python3`
   # because pip --target invokes the venv's python. The /tmp build dir
   # disappears with the EXIT trap at end-of-job, so any PATH-resolved
   # entry point afterwards would fail with "bad interpreter". Same root
   # cause + same fix as mdb_setup.sh / pytorch_setup.sh: rewrite to
   # /usr/bin/env python3, which works because the intellikit modulefile
   # prepends ${INTELLIKIT_PATH} onto PYTHONPATH so the packages are
   # importable under the system python3 once `module load intellikit`
   # is in effect.
   if [ -d "${INTELLIKIT_PATH}/bin" ]; then
      ${SUDO} find ${INTELLIKIT_PATH}/bin -maxdepth 1 -type f \
         -exec sed -i '1s|^#!.*python3.*$|#!/usr/bin/env python3|' {} + 2>/dev/null || true
   fi

   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find $INTELLIKIT_PATH -type f -execdir chown root:root "{}" +
      ${SUDO} find $INTELLIKIT_PATH -type d -execdir chown root:root "{}" +
   fi

   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod go-w $INTELLIKIT_PATH
   fi

   # cleanup: trap handles ${INTELLIKIT_BUILD_ROOT}/intellikit_build
   cd /
   module unload ${ROCM_MODULE_NAME}
fi

# Create a module file for intellikit
#
# Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
# see netcdf_setup.sh for the lying-probe failure mode this replaces).
PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

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

# The - option suppresses tabs
cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${INTELLIKIT_VERSION}.lua
	local help_message = [[

	IntelliKit: agent-first GPU profiling and validation tooling for AMD ROCm
	(kerncap, metrix, linex, nexus, rocm_mcp, uprof_mcp, accordo).

	Installed tools: ${INTELLIKIT_TOOLS}
	Git ref: ${INTELLIKIT_VERSION}
	]]

	help(help_message,"\n")

	whatis("Name: intellikit")
	whatis("Upstream: https://github.com/AMDResearch/intellikit")
	whatis("Version:  ${INTELLIKIT_VERSION}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Keywords: Profiling, Validation, GPU, MCP")

	prereq("${ROCM_MODULE_NAME}")
	prepend_path("PYTHONPATH","${INTELLIKIT_PATH}")
	prepend_path("PATH","${INTELLIKIT_PATH}/bin")
	setenv("INTELLIKIT_HOME","${INTELLIKIT_PATH}")
EOF
