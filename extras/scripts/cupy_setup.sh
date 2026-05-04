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
ROCM_VERSION=6.2.0
BUILD_CUPY=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/cupy
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
CUPY_PATH=""           # default derived after CUPY_VERSION auto-resolve below
CUPY_PATH_INPUT=""
# Sentinel default; resolved to a concrete version after the ROCm version
# is parsed (see _resolve_cupy_version below).  ROCm-version-aware default
# matrix:
#   ROCm >= 7.0.0  ->  CUPY_VERSION=14.0.1   (upstream cupy v14)
#   ROCm <  7.0.0  ->  CUPY_VERSION=13.6.0   (upstream cupy v13)
# Use "--cupy-version ?" to print the available combinations and exit.
CUPY_VERSION="auto"
# --replace 1: rm -rf prior install dir + ${CUPY_VERSION}.lua before building.
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
   echo "  --build-cupy [ BUILD_CUPY ] default $BUILD_CUPY "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ CUPY_PATH ] default $CUPY_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --cupy-version [ CUPY_VERSION ] specify the version of CuPy, default is $CUPY_VERSION"
   echo "                                  (auto = 14.0.1 for ROCm >=7.0, 13.6.0 for ROCm <7.0;"
   echo "                                   pass '?' to list available combinations and exit)"
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
      "--build-cupy")
          shift
          BUILD_CUPY=${1}
	  reset-last
          ;;
      "--cupy-version")
          shift
          CUPY_VERSION=${1}
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
          CUPY_PATH_INPUT=${1}
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

# NOTE: default CUPY_PATH is deferred to AFTER the auto-resolve block
# below, because the install dir name is ${ROCMPLUS}/cupy-v${CUPY_VERSION}
# and CUPY_VERSION may still be the literal string "auto" at this point.
if [ "${CUPY_PATH_INPUT}" != "" ]; then
   CUPY_PATH=${CUPY_PATH_INPUT}
fi

# ── CuPy version <-> ROCm version compatibility resolver ──────────────
# Placed BEFORE preflight_modules so that `--cupy-version ?` works as a
# pure documentation query without needing a real rocm/<ver> module to
# exist on the current host.  Auto-default and the ROCm 6.x + cupy 14.x
# rejection are also resolved here (only ROCM_VERSION is needed -- the
# rocm module itself is not).
#
# Returns 0 (true) iff ROCM_VERSION >= "$1" (semver compare via sort -V).
_rocm_ge() {
   [ "$(printf '%s\n%s\n' "$1" "${ROCM_VERSION}" | sort -V | head -1)" = "$1" ]
}

# Print the supported CuPy options for the *currently-resolved* ROCm
# version.  Used by --cupy-version ? and by the unsupported-combo
# error path below.
_print_cupy_options() {
   echo ""
   echo "================================================================"
   echo " Available CuPy options for ROCm ${ROCM_VERSION}"
   echo "================================================================"
   if _rocm_ge 7.0.0; then
      cat <<EOF
   ROCm 7.x detected.  Two source paths are supported:

   --cupy-version 14.0.1   (RECOMMENDED, default)
       Upstream CuPy v14 (https://github.com/cupy/cupy, tag v14.0.1).
       CuPy v14 dropped official support for ROCm <= 6.x; ROCm 7.x is
       the supported target.  Optimized for AMD Instinct MI300/MI350.

   --cupy-version 13.x     (LEGACY API, AMD ROCm fork)
       e.g. --cupy-version 13.5.1 or 13.6.0.  Cloned from the AMD
       fork at https://github.com/ROCm/cupy on branch
       release/rocmds-25.10.  This branch backports the ROCm 7.x
       support that was upstreamed in CuPy v14, so users who need
       the v13 API surface can still run on ROCm 7.x.  The actual
       installed package version is taken from the wheel's dist-info,
       not from --cupy-version, so the modulefile name will reflect
       whatever the AMD fork ships (currently amd-cupy 13.5.1).
EOF
   else
      cat <<EOF
   ROCm 6.x or earlier detected.  Upstream CuPy v13.x is supported:

   --cupy-version 13.6.0   (RECOMMENDED, default for ROCm 6.x)
       Upstream CuPy v13 (https://github.com/cupy/cupy, tag v13.6.0).
       Any 13.x tag (13.0.0 .. 13.6.0) is valid; this is the last
       major series with first-class ROCm 6.x support.

   --cupy-version 14.x     NOT SUPPORTED on ROCm <7.0
       CuPy v14 dropped ROCm 6.x.  If you need v14, bump the ROCm
       module to >= 7.0.0; otherwise stay on a 13.x release.
EOF
   fi
   echo "================================================================"
   echo ""
}

# Handle the explicit `?` query first (`--cupy-version ?`): print options
# and exit successfully without doing any install work.
if [ "${CUPY_VERSION}" = "?" ]; then
   _print_cupy_options
   exit 0
fi

# Resolve the auto default to a concrete version based on ROCm.
if [ "${CUPY_VERSION}" = "auto" ]; then
   if _rocm_ge 7.0.0; then
      CUPY_VERSION="14.0.1"
   else
      CUPY_VERSION="13.6.0"
   fi
   echo "CUPY_VERSION resolved from 'auto' -> ${CUPY_VERSION} (ROCm ${ROCM_VERSION})"
fi

# Reject the unsupported combination CuPy 14 + ROCm 6.x up front so the
# build doesn't waste ~10 min cloning / configuring something that is
# guaranteed to fail downstream.  CuPy 13 + ROCm 7.x is *supported*
# (via the AMD fork) so it's not rejected here -- the source-selection
# block below routes it.
_cupy_major="${CUPY_VERSION%%.*}"
if [ "${_cupy_major}" = "14" ] && ! _rocm_ge 7.0.0; then
   echo "ERROR: CuPy v${CUPY_VERSION} does not support ROCm < 7.0 (you have ${ROCM_VERSION})."
   _print_cupy_options
   exit 1
fi

# Default install path now that CUPY_VERSION is concrete (not "auto").
# Caller-supplied --install-path still wins (handled above as
# CUPY_PATH=${CUPY_PATH_INPUT}).
if [ -z "${CUPY_PATH}" ]; then
   CUPY_PATH=/opt/rocmplus-${ROCM_VERSION}/cupy-v${CUPY_VERSION}
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Now that CUPY_VERSION + CUPY_PATH are finalized we can install both.
# ── BUILD_CUPY=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_CUPY}" = "0" ]; then
   echo "[cupy BUILD_CUPY=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[cupy --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${CUPY_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${CUPY_VERSION}.lua"
   ${SUDO} rm -rf "${CUPY_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${CUPY_VERSION}.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${CUPY_PATH}" ]; then
   echo ""
   echo "[cupy existence-check] ${CUPY_PATH} already installed; skipping."
   echo "                       pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (CUPY_BUILD_ROOT, set later
# under the BUILD_CUPY=1 path) PLUS fail-cleanup of partial install +
# modulefile. Replaces the inline `trap '... rm CUPY_BUILD_ROOT ...' EXIT`
# that used to live next to the mktemp call.
_cupy_on_exit() {
   local rc=$?
   [ -n "${CUPY_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${CUPY_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[cupy fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${CUPY_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${CUPY_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[cupy fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _cupy_on_exit EXIT

# Now that we have a valid (CUPY_VERSION, ROCM_VERSION) combination,
# require the rocm/<ver> module to actually be loadable.  This is the
# point at which any further work touches a real ROCm install.
REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" )
preflight_modules "${REQUIRED_MODULES[@]}" || exit $?
ROCM_HOME=${ROCM_PATH}

echo ""
echo "==================================="
echo "Starting CuPy Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_CUPY: $BUILD_CUPY"
echo "CUPY_PATH: $CUPY_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "CUPY_VERSION: $CUPY_VERSION"
echo "==================================="
echo ""

if [ "${BUILD_CUPY}" = "0" ]; then

   echo "CuPy will not be built, according to the specified value of BUILD_CUPY"
   echo "BUILD_CUPY: $BUILD_CUPY"
   exit

else
   # Per-job throwaway build dir; replaces a fixed `cd /tmp` (with a
   # later `rm -rf cupy cupy_build`) that would race with any other
   # concurrent cupy build on the same node.
   CUPY_BUILD_ROOT=$(mktemp -d -t cupy-build.XXXXXX)
   # NOTE: build-dir cleanup is consolidated into the _cupy_on_exit trap
   # installed above (after CUPY_PATH was finalized) so the same EXIT
   # handler also does fail-cleanup of any partial install / modulefile.
   cd "${CUPY_BUILD_ROOT}"

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/cupy-v${CUPY_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached CuPy"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # cupy-v${CUPY_VERSION}.tgz and contain a top-level directory
      # cupy-v${CUPY_VERSION}/ so it lands directly at ${CUPY_PATH}
      # when extracted under /opt/rocmplus-X.
      ${SUDO} mkdir -p ${CUPY_PATH}
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/cupy-v${CUPY_VERSION}.tgz
      chown -R root:root ${CUPY_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/cupy-v${CUPY_VERSION}.tgz
      fi
      SAVED_ROCM_HOME=${ROCM_HOME}
   else
      echo ""
      echo "============================"
      echo " Building CuPy"
      echo "============================"
      echo ""


      # Load the ROCm version for this CuPy build -- use hip compiler, path to ROCm and the GPU model
      export CUPY_INSTALL_USE_HIP=1
      export ROCM_HOME=${ROCM_PATH}
      export HIPCC=${ROCM_HOME}/bin/hipcc
      export HCC_AMDGPU_ARCH=$(echo ${AMDGPU_GFXMODEL} | cut -d';' -f1)
      OFFLOAD_ARCH_FLAGS=""
      for arch in $(echo ${AMDGPU_GFXMODEL} | tr ';' ' '); do
          OFFLOAD_ARCH_FLAGS+=" --offload-arch=${arch}"
      done
      export HIPCC_COMPILE_FLAGS_APPEND="${OFFLOAD_ARCH_FLAGS} ${HIPCC_COMPILE_FLAGS_APPEND}"
      # Detect a system `uv` if present, but make the lookup non-fatal
      # under set -eo pipefail (line 5).  The previous form
      #   UV_LOC=`which uv`
      # silently aborted the entire script whenever `uv` was not
      # installed (Debian `which` exits 1 with no diagnostic on either
      # stream), so the `if [ "x$UV_LOC" == "x" ]` fallback below was
      # dead code -- the script terminated before reaching it. Audit
      # ref: 7973 cupy rc=1 with log truncated at the "Building CuPy"
      # banner. `command -v` is a POSIX builtin (no external `which`
      # dep); `2>/dev/null || true` keeps set -e quiet on a miss.
      UV_LOC=$(command -v uv 2>/dev/null || true)
      python3 -m venv cupy_build
      source cupy_build/bin/activate
      if [ "x$UV_LOC" == "x" ]; then
         pip3 install uv
         PATH="${PATH}:~/.local/bin"
      fi

      if [ -d "$CUPY_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${CUPY_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p $CUPY_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $CUPY_PATH
      fi
      uv pip install -v --target=$CUPY_PATH pytest mock xarray[complete] build numpy-allocator --no-cache
      export PYTHONPATH=$PYTHONPATH:$CUPY_PATH

      # ── Source selection ─────────────────────────────────────────────
      # Decision matrix (ROCM_VERSION x CUPY_VERSION):
      #   ROCm >=7.0  +  CuPy 14.x  ->  upstream cupy/cupy  v${CUPY_VERSION}    (default for 7.x)
      #   ROCm >=7.0  +  CuPy 13.x  ->  AMD fork ROCm/cupy  release/rocmds-25.10
      #   ROCm <7.0   +  CuPy 13.x  ->  upstream cupy/cupy  v${CUPY_VERSION}    (default for 6.x)
      #   ROCm <7.0   +  CuPy 14.x  ->  REJECTED above (CuPy v14 dropped ROCm 6.x)
      # The AMD fork pinning at release/rocmds-25.10 is intentional: it
      # is the branch the ROCm team maintains as the "v13 API on ROCm 7"
      # backport, and it does not honor the user-supplied 13.x tag (the
      # branch ships whatever version it ships -- currently amd-cupy
      # 13.5.1).  Modulefile naming uses the actually-installed
      # dist-info version (see _detect_installed_cupy_version below),
      # so users see the truth.
      if _rocm_ge 7.0.0 && [ "${_cupy_major}" = "13" ]; then
         echo "Source selection: CuPy 13.x on ROCm >=7.0 -> AMD ROCm/cupy fork (release/rocmds-25.10)"
         git clone -q --depth 1 -b release/rocmds-25.10 https://github.com/ROCm/cupy.git
         cd cupy
         git submodule update --init --recursive
      else
         # Upstream cupy at the requested tag.  Covers two cases:
         #   - ROCm >=7.0 + CuPy 14.x (default for ROCm 7.x)
         #   - ROCm <7.0  + CuPy 13.x (default for ROCm 6.x)
         echo "Source selection: upstream cupy/cupy tag v${CUPY_VERSION}"
         git clone -q --depth 1 -b v$CUPY_VERSION --recursive https://github.com/cupy/cupy.git
         cd cupy
      fi
      uv build --wheel
      uv pip install -v --upgrade --target=$CUPY_PATH dist/*.whl
      uv pip install -v --target=$CUPY_PATH cupy-xarray --no-deps
      deactivate
      cd /
      # clean-up: trap handles ${CUPY_BUILD_ROOT}/{cupy,cupy_build}
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find $CUPY_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $CUPY_PATH -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w $CUPY_PATH
      fi

      SAVED_ROCM_HOME=${ROCM_HOME}
      module unload rocm/${ROCM_VERSION}
   fi

   # Determine the version label for the modulefile from what was
   # actually installed in ${CUPY_PATH}, NOT from the user-supplied
   # CUPY_VERSION variable.  Rationale: for ROCm >= 6.5 the build
   # branch above ignores CUPY_VERSION and clones the AMD ROCm/cupy
   # fork at a fixed branch (currently release/rocmds-25.10), which
   # ships as e.g. amd-cupy 13.5.1.  Prior to this fix, the modulefile
   # was named "cupy/${CUPY_VERSION}" -- e.g. cupy/14.0.1 -- even though
   # the installed package was amd-cupy 13.5.1.  That made `module
   # avail`/`module whatis` lie about which cupy a user actually got.
   # Detection scans for amd_cupy-*.dist-info (AMD fork wheel layout)
   # or cupy-*.dist-info (upstream cupy wheel layout); pip normalizes
   # the package name to use '_' in the dist-info dir name (PEP 503/427).
   # cupy_xarray-*.dist-info is excluded by the explicit prefix match.
   # Two prior bugs in this detector under `set -eo pipefail`:
   #   1) `s|...(amd_cupy|cupy)...|...|` -- sed treated the `|` inside
   #      the alternation as the s-delimiter, exiting rc=2 with
   #      "unknown option to 's'".  Job 8019 cupy rc=1 (2026-05-02 11:31).
   #      Fixed by switching the s-delimiter to `#`.
   #   2) `ls -d amd_cupy-*.dist-info cupy-*.dist-info` -- when only one
   #      glob matches (e.g. only cupy-14.0.1 is present, no amd_cupy
   #      because we built upstream cupy 14.x not the AMD fork), GNU
   #      `ls` returns rc=2 because one of its arguments was unfindable.
   #      `pipefail` propagated that, `set -e` killed the script
   #      silently right before the result echo.  Job 8025 cupy rc=2
   #      (2026-05-02 12:53).  Fixed by using bash glob expansion with
   #      `shopt -s nullglob`, which expands non-matching globs to the
   #      empty string and never errors -- bypassing the ls/pipefail
   #      interaction entirely.  Cleaner and avoids the subprocess.
   shopt -s nullglob
   _dist_info_dirs=( "${CUPY_PATH}"/amd_cupy-*.dist-info "${CUPY_PATH}"/cupy-*.dist-info )
   shopt -u nullglob
   INSTALLED_CUPY_VERSION=""
   if [ "${#_dist_info_dirs[@]}" -gt 0 ]; then
      INSTALLED_CUPY_VERSION=$(basename "${_dist_info_dirs[0]}" \
         | sed -nE 's#^(amd_cupy|cupy)-([0-9][^/]+)\.dist-info$#\2#p')
   fi
   unset _dist_info_dirs
   if [ -z "${INSTALLED_CUPY_VERSION}" ]; then
      echo "WARNING: could not detect installed cupy version from dist-info under ${CUPY_PATH};"
      echo "         falling back to user-supplied CUPY_VERSION='${CUPY_VERSION}' for the modulefile name."
      INSTALLED_CUPY_VERSION="${CUPY_VERSION}"
   else
      echo "Detected installed cupy version: ${INSTALLED_CUPY_VERSION} (modulefile will be named cupy/${INSTALLED_CUPY_VERSION}.lua)"
   fi

   # Create a module file for cupy
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${INSTALLED_CUPY_VERSION}.lua
	whatis("CuPy with ROCm support (installed package: ${INSTALLED_CUPY_VERSION})")

	prereq("rocm/${ROCM_VERSION}")
	prepend_path("PYTHONPATH","$CUPY_PATH")
	prepend_path("CPATH","/usr/lib/gcc/x86_64-linux-gnu/12/include")
        setenv("ROCM_HOME","$SAVED_ROCM_HOME")
EOF

fi
