#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Variables controlling setup process
ROCM_VERSION=6.2.0
BUILD_TF=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/tensorflow
# AMDGPU_GFXMODEL: defer rocminfo autodetect to AFTER arg parsing so that
# `--amdgpu-gfxmodel ...` callers never trigger rocminfo (it can fail on
# SDK/host glibc skew, e.g. ROCm 7.2.3 binaries requiring GLIBC_2.38 on
# jammy's 2.35, which would dump stderr noise and -- in scripts with
# `set -eo pipefail` -- kill the leaf before main_setup.sh's flag-driven
# value takes effect). See logs_05_11_2026/rocm-7.2.3_9003/ cascade.
AMDGPU_GFXMODEL=""
TF_PATH=/opt/rocmplus-${ROCM_VERSION}/tensorflow
TF_PATH_INPUT=""
# TENSORFLOW_VERSION default is the LAST-RESORT fallback for ROCm rows
# not in TENSORFLOW_SUPPORTED_VERSIONS below. The runtime default is
# auto-derived from the loaded/--rocm-version ROCm major.minor by
# default_tensorflow_version_for_rocm() (defined further below). The
# auto-derive runs when TENSORFLOW_VERSION_USER_SET=0; passing
# --tensorflow-version flips the sentinel and bypasses the auto-derive.
TENSORFLOW_VERSION="2.20.0"
TENSORFLOW_VERSION_USER_SET=0
# GIT_BRANCH default is empty: when empty, the resolver below derives it
# from TENSORFLOW_VERSION's major.minor as `r${MAJ}.${MIN}-rocm-enhanced`,
# which matches ROCm/tensorflow-upstream's branch-naming convention
# (one branch per major.minor; the latest commit on that branch is the
# highest patch release). Pass --git-branch to override (e.g. to pin to
# a specific commit/tag like `v2.18.1-rocm-enhanced`).
GIT_BRANCH=""
# --replace 1: rm -rf prior install dir + ${TENSORFLOW_VERSION}.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

# ── TensorFlow version table: ROCm major.minor → supported TF versions ──
# Source: ROCm install-on-linux docs at
#   https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/3rd-party/tensorflow-install.html
# Each row lists the TensorFlow versions ROCm declares supported for
# that ROCm major.minor, HIGHEST FIRST. The default for each ROCm
# major.minor is therefore the first token (resolved by
# default_tensorflow_version_for_rocm() below).
#
# Off-table ROCm (e.g. 5.x, 7.3+, RC trees like therock-/afar-): the
# resolver returns empty so the file-default 2.20.0 above sticks. The
# resolver also prints a clear "no auto-derive row" line in that case
# so the operator notices.
declare -A TENSORFLOW_SUPPORTED_VERSIONS=(
   [6.3]="2.17.0 2.16.2 2.15.1"
   [6.4]="2.18.1 2.17.1 2.16.2"
   [7.0]="2.19.1 2.18.1 2.17.1"
   [7.1]="2.20.0 2.19.1 2.18.1"
   [7.2]="2.20.0 2.19.1 2.18.1"
)

default_tensorflow_version_for_rocm() {
   local rocm_mm="$1"
   local row="${TENSORFLOW_SUPPORTED_VERSIONS[${rocm_mm}]:-}"
   [ -z "${row}" ] && return 0
   # First token = highest supported version per the ROCm docs row.
   awk '{print $1}' <<< "${row}"
}

is_tensorflow_supported_for_rocm() {
   local rocm_mm="$1" tf_ver="$2" row tok
   row="${TENSORFLOW_SUPPORTED_VERSIONS[${rocm_mm}]:-}"
   [ -z "${row}" ] && return 1
   for tok in ${row}; do
      [ "${tok}" = "${tf_ver}" ] && return 0
   done
   return 1
}

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
   echo "  --build-tensorflow [ BUILD_TF ] default $BUILD_TF "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --install-path [ TF_PATH ] default $TF_PATH "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --tensorflow-version [ TENSORFLOW_VERSION ] TensorFlow release (e.g. 2.20.0). Default is auto-derived"
   echo "    from the loaded ROCm major.minor via default_tensorflow_version_for_rocm() (highest"
   echo "    supported version per the ROCm install-on-linux docs). Mapping (ROCm -> highest TF):"
   echo "      6.3 -> 2.17.0    6.4 -> 2.18.1    7.0 -> 2.19.1    7.1 -> 2.20.0    7.2 -> 2.20.0"
   echo "    Pass --tensorflow-version VER to override the auto-derive. The leaf clones the"
   echo "    matching r\${MAJOR}.\${MINOR}-rocm-enhanced upstream branch unless --git-branch is given."
   echo "    File-default fallback (when no auto-derive row matches): $TENSORFLOW_VERSION"
   echo "  --git-branch [ GIT_BRANCH ] override the upstream git branch/tag to clone. Default is empty,"
   echo "    which makes the leaf script derive r\${MAJOR}.\${MINOR}-rocm-enhanced from TENSORFLOW_VERSION."
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
      "--build-tensorflow")
          shift
          BUILD_TF=${1}
	  reset-last
          ;;
      "--git-branch")
          shift
          GIT_BRANCH=${1}
	  reset-last
          ;;
      "--tensorflow-version")
          shift
          TENSORFLOW_VERSION=${1}
          TENSORFLOW_VERSION_USER_SET=1
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
          TF_PATH_INPUT=${1}
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

if [ "${TF_PATH_INPUT}" != "" ]; then
   TF_PATH=${TF_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   TF_PATH=/opt/rocmplus-${ROCM_VERSION}/tensorflow
fi

# ── Resolve TENSORFLOW_VERSION + GIT_BRANCH + versioned install path ──
# Auto-derive TENSORFLOW_VERSION from the loaded ROCm if the user did
# NOT pass --tensorflow-version. Mapping in
# default_tensorflow_version_for_rocm() near the top of this script.
# User flag wins (TENSORFLOW_VERSION_USER_SET=1 short-circuits this
# branch); off-table ROCm leaves the file default untouched and prints
# a clear "no auto-derive row" line.
ROCM_MAJOR_MINOR=$(echo "${ROCM_VERSION}" | cut -f1-2 -d'.')
if [ "${TENSORFLOW_VERSION_USER_SET}" -eq 1 ]; then
   echo "tensorflow: TENSORFLOW_VERSION=${TENSORFLOW_VERSION} (user --tensorflow-version)"
   if ! is_tensorflow_supported_for_rocm "${ROCM_MAJOR_MINOR}" "${TENSORFLOW_VERSION}"; then
      _supp_row="${TENSORFLOW_SUPPORTED_VERSIONS[${ROCM_MAJOR_MINOR}]:-<no row>}"
      echo "WARNING: TensorFlow ${TENSORFLOW_VERSION} is NOT in the ROCm-docs supported list" >&2
      echo "         for ROCm ${ROCM_MAJOR_MINOR}. Supported: ${_supp_row}" >&2
      echo "         Build will proceed (off-list versions are not blocked) but no compatibility" >&2
      echo "         is promised by the ROCm install-on-linux docs." >&2
      unset _supp_row
   fi
else
   _tf_default=$(default_tensorflow_version_for_rocm "${ROCM_MAJOR_MINOR}")
   if [ -n "${_tf_default}" ]; then
      TENSORFLOW_VERSION="${_tf_default}"
      echo "tensorflow: TENSORFLOW_VERSION auto-derived from ROCm ${ROCM_MAJOR_MINOR} -> ${TENSORFLOW_VERSION}"
   else
      echo "tensorflow: no auto-derive row for ROCm ${ROCM_MAJOR_MINOR}; using file default ${TENSORFLOW_VERSION}"
   fi
   unset _tf_default
fi

# Derive GIT_BRANCH from TENSORFLOW_VERSION if the user did not pin one
# explicitly via --git-branch. ROCm/tensorflow-upstream uses one branch
# per major.minor (`r2.18-rocm-enhanced`, `r2.19-rocm-enhanced`, ...);
# the latest commit on that branch corresponds to the highest patch
# release, which is what the ROCm docs publish.
if [ -z "${GIT_BRANCH}" ]; then
   _tf_mm=$(echo "${TENSORFLOW_VERSION}" | cut -f1-2 -d'.')
   GIT_BRANCH="r${_tf_mm}-rocm-enhanced"
   echo "tensorflow: GIT_BRANCH auto-derived from TENSORFLOW_VERSION ${TENSORFLOW_VERSION} -> ${GIT_BRANCH}"
   unset _tf_mm
else
   echo "tensorflow: GIT_BRANCH=${GIT_BRANCH} (user --git-branch)"
fi

# Version-suffix the install dir: TF_PATH was either provided by the
# parent (--install-path) as a version-agnostic parent dir (e.g.
# ${ROCMPLUS}/tensorflow) or defaulted above. Append `-v${VER}` so
# multiple versions can coexist on the same rocmplus tree, mirroring
# the pytorch-v${VER} / ftorch-v${VER} layout. inventory_packages.py's
# tensorflow row reads the version straight out of this dir basename.
TF_PATH="${TF_PATH}-v${TENSORFLOW_VERSION}"

# Fallback gfx autodetect: only fire if --amdgpu-gfxmodel was not supplied.
# Stderr-silenced + `|| true` so a broken rocminfo (SDK/host glibc skew)
# can't kill the script. AMDGPU_GFXMODEL stays empty if both autodetect
# and the flag fail to provide a value; downstream consumers report the
# real error (`./configure` etc.) rather than a cryptic pipefail rc.
if [ -z "${AMDGPU_GFXMODEL}" ]; then
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is ${GIT_BRANCH}.lua to match the
# `tee ${MODULE_PATH}/${GIT_BRANCH}.lua` write below.
# ── BUILD_TF=0 short-circuit: operator opt-out (see hypre_setup.sh) ──
# Note: the in-script variable is BUILD_TF (--build-tensorflow); the
# corresponding main_setup.sh variable is BUILD_TENSORFLOW. They are
# threaded by main_setup.sh as `--build-tensorflow ${BUILD_TENSORFLOW}`.
NOOP_RC=43
if [ "${BUILD_TF}" = "0" ]; then
   echo "[tensorflow BUILD_TF=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[tensorflow --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${TF_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${TENSORFLOW_VERSION}.lua"
   ${SUDO} rm -rf "${TF_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${TENSORFLOW_VERSION}.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${TF_PATH}" ]; then
   echo ""
   echo "[tensorflow existence-check] ${TF_PATH} already installed; skipping."
   echo "                             pass --replace 1 to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (TF_BUILD_ROOT, set later
# under BUILD_TF=1) + fail-cleanup. Replaces inline
# `trap '... rm TF_BUILD_ROOT ...' EXIT`.
_tensorflow_on_exit() {
   local rc=$?
   [ -n "${TF_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${TF_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[tensorflow fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${TF_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${TENSORFLOW_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[tensorflow fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _tensorflow_on_exit EXIT

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

# Load the ROCm version for this TensorFlow build
#source /etc/profile.d/lmod.sh
#source /etc/profile.d/z00_lmod.sh
module load ${ROCM_MODULE_NAME}

# Put clang in your PATH
module load amdclang

echo ""
echo "==================================="
echo "Starting TensorFlow Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_TF: $BUILD_TF"
echo "TENSORFLOW_VERSION: $TENSORFLOW_VERSION"
echo "TF_PATH: $TF_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "Building from source off of git branch: $GIT_BRANCH"
echo "==================================="
echo ""

if [ "${BUILD_TF}" = "0" ]; then

   echo "TensorFlow will not be built, according to the specified value of BUILD_TF"
   echo "BUILD_TF: $BUILD_TF"
   exit

else
   # Per-job throwaway build dir; replaces a fixed `cd /tmp` (with a
   # later `rm -rf tensorflow-upstream`) that would race with -- and
   # could clobber -- any other concurrent tensorflow build on the
   # same node.
   TF_BUILD_ROOT=$(mktemp -d -t tensorflow-build.XXXXXX)
   # NOTE: build-dir cleanup is consolidated into _tensorflow_on_exit
   # installed above (so the same EXIT handler also does fail-cleanup
   # of any partial install / modulefile).
   cd "${TF_BUILD_ROOT}"

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   # Cache tarball is keyed on TENSORFLOW_VERSION so that multiple
   # versions can coexist on the same rocmplus tree (mirrors the
   # versioned install dir tensorflow-v<VER>/). Legacy unversioned
   # `tensorflow.tgz` caches are no longer consumed here -- a newly
   # versioned build replaces them on the next cache refresh.
   TF_CACHE_BASENAME="$(basename "${TF_PATH}")"   # tensorflow-v${VER}
   TF_CACHE_TGZ="${CACHE_FILES}/${TF_CACHE_BASENAME}.tgz"
   TF_CACHE_PARENT="$(dirname "${TF_PATH}")"
   if [ -f "${TF_CACHE_TGZ}" ]; then
      echo ""
      echo "============================"
      echo " Installing Cached TensorFlow"
      echo " cache file: ${TF_CACHE_TGZ}"
      echo " unpack dir: ${TF_CACHE_PARENT}"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p "${TF_CACHE_PARENT}"
      cd "${TF_CACHE_PARENT}"
      ${SUDO} tar -xzpf "${TF_CACHE_TGZ}"
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm "${TF_CACHE_TGZ}"
      fi
   else
      echo ""
      echo "============================"
      echo " Building TensorFlow"
      echo "============================"
      echo ""


      if [ -d "$TF_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${TF_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      if [ ${SUDO} == "" ]; then
         echo " WARNING: not using sudo, the build may fail due to some dependencies not being already present in your system "
      fi

      ${SUDO} mkdir -p $TF_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $TF_PATH
      fi

      # get tensorflow dependencies. PKG_SUDO: apt needs root regardless
      # of the install-path-derived SUDO. See openmpi_setup.sh /
      # audit_2026_05_01.md Issue 2.
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
      ${PKG_SUDO} apt-get update
      ${PKG_SUDO} apt-get install -y python3-dev python3-pip openjdk-8-jdk openjdk-8-jre unzip wget git python-is-python3 patchelf 'argcomplete>=1.9.4'

      pip3 install -v --target=$TF_PATH numpy wheel mock future pyyaml setuptools requests keras_preprocessing keras_applications jupyter

      # install bazel
      curl -Lo bazelisk https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-$(uname -s | tr '[:upper:]' '[:lower:]')-amd64
      chmod +x bazelisk
      export BAZEL_PATH=${TF_PATH}/bazel
      ${SUDO} mkdir -p ${BAZEL_PATH}
      export PATH=$PATH:${BAZEL_PATH}
      ${SUDO} mv bazelisk ${BAZEL_PATH}
      pushd ${BAZEL_PATH}
      ${SUDO} mv bazelisk bazel
      popd

      git clone --recursive -b $GIT_BRANCH https://github.com/ROCm/tensorflow-upstream

      # set the bazel version to use
      export USE_BAZEL_VERSION=`cat tensorflow-upstream/.bazelversion | head -n 1`

      cd tensorflow-upstream

      if [[ "${GIT_BRANCH}" != "r2.20-rocm-enhanced" ]]; then

         sed -i '/name = "net_zstd"/,/tf_mirror_urls/{
         s|build_file = "@local_xla//third_party:net_zstd.BUILD"|build_file = "@local_xla//third_party:net_zstd.BUILD"|
         s|sha256 = ".*"|sha256 = "b6c537b53356a3af3ca3e621457751fa9a6ba96daf3aebb3526ae0f610863532"|
         s|strip_prefix = ".*"|strip_prefix = "zstd-1.4.5/lib"|
         s|urls = tf_mirror_urls("https://github.com/facebook/zstd/archive/.*"|urls = tf_mirror_urls("https://github.com/facebook/zstd/archive/v1.4.5.zip" |
}' tensorflow//workspace2.bzl

      fi

      export CLANG_COMPILER=`which clang`
      sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|" .bazelrc

      result=`echo ${ROCM_VERSION} | awk '$1>6.3.9'` && echo $result
      if [[ "${result}" ]]; then
	 # need this for ROCm greater than 6.4.0 due to upgrade in clang version
         sed -i '$a build:rocm --copt=-Wno-error=c23-extensions' .bazelrc
      fi

      # ── HIP kernel-arg API guard for ROCm 7.13+ ──────────────────────
      # ROCm 7.13.0 introduced a breaking change in the kernel-arg packing
      # API exposed by <rocm>/include/hip/amd_detail/amd_hip_runtime.h:
      #
      #   pArgs                <= 7.2.x: template <size_t n, typename... Ts>
      #                                  void pArgs(const std::tuple<Ts...>&, void**)
      #                                  (recursive, explicit <n>, returns void)
      #                        >= 7.13:  template <typename... Ts>
      #                                  std::array<void*, sizeof...(Ts)>
      #                                      pArgs(std::tuple<Ts...>& formals)
      #                                  (returns the array, no explicit <n>)
      #
      #   validateArgsCountType <= 7.2.x: (kernel, std::tuple<Actuals...>)
      #                         >= 7.13:  (kernel, Actuals... actuals)   (variadic)
      #
      # The TF r2.20-rocm-enhanced (and earlier) callsites in
      # tensorflow/core/util/gpu_kernel_helper.h (lines ~137-141) only
      # compile against the old API. Without this patch, a ROCm 7.13+
      # build dies at fill_empty_rows_functor_gpu.cu.cc with:
      #   amd_hip_runtime.h:174: static_assert(sizeof...(Formals) ==
      #                                        sizeof...(Actuals))
      #                                        fails ('7 == 1', etc.)
      #   gpu_kernel_helper.h:141: no matching function for call to 'pArgs'
      # First diagnosed in slurm job 11561 (rocm-7.13.0, 2026-06-05).
      #
      # The patch wraps the existing call sites in
      #   #if HIP_VERSION >= 71300000   // ROCm 7.13.0+ new API
      #     ... new-API call ...
      #   #else                          // ROCm <= 7.2.x legacy API
      #     ... existing code ...
      #   #endif
      # so the SAME patched header compiles against BOTH API generations.
      # HIP_VERSION is MAJOR*10_000_000 + MINOR*100_000 + PATCH (defined in
      # <rocm>/include/hip/hip_version.h). 71300000 = 7.13.0.
      #
      # Branch gate: apply only on known pre-fix TF branches. When ROCm/
      # tensorflow-upstream ships a branch with the fix, that branch will
      # NOT match the case below and we leave its source untouched.
      # If/when a new pre-fix branch shows up, extend the case.
      #
      # Verified syntax-only against both rocm-7.13.0 and rocm-7.2.3
      # headers; preprocessor selects the right branch in each.
      case "${GIT_BRANCH}" in
         r2.20-rocm-enhanced|r2.19-rocm-enhanced|r2.18-rocm-enhanced|r2.17-rocm-enhanced|r2.16-rocm-enhanced|r2.15-rocm-enhanced)
            _GKH_NEEDS_HIP713_PATCH=1
            ;;
         *)
            _GKH_NEEDS_HIP713_PATCH=0
            ;;
      esac
      if [[ "${_GKH_NEEDS_HIP713_PATCH}" == "1" ]]; then
         _GKH_PATCH_FILE=tensorflow/core/util/gpu_kernel_helper.h
         echo ""
         echo "tensorflow: applying HIP 7.13+ kernel-arg API guard to ${_GKH_PATCH_FILE}"
         echo "            (branch=${GIT_BRANCH}; see comment block in tensorflow_setup.sh)"
         # Dry-run first so we fail loudly with a clear diagnostic if
         # upstream has moved the call sites under us.
         if ! patch --dry-run -p1 >/dev/null 2>&1 <<'GKH_PATCH_EOF'
--- a/tensorflow/core/util/gpu_kernel_helper.h
+++ b/tensorflow/core/util/gpu_kernel_helper.h
@@ -134,11 +134,21 @@
       return errors::Internal(cudaGetErrorString(result));
     }
 #elif TENSORFLOW_USE_ROCM
+#if HIP_VERSION >= 71300000
+    // ROCm 7.13+: new HIP kernel-arg API. validateArgsCountType is variadic;
+    // pArgs takes a single std::tuple<> reference and returns
+    // std::array<void*, N>. See <rocm>/include/hip/amd_detail/amd_hip_runtime.h.
+    auto tup = validateArgsCountType(function, arguments...);
+    auto _ArgsArr = pArgs(tup);
+    void** _Args = _ArgsArr.data();
+#else
+    // ROCm <= 7.2.x: legacy HIP kernel-arg API (tuple form + explicit <0> index).
     constexpr size_t count = sizeof...(Args);
     auto tup_ = std::tuple<Args...>{arguments...};
     auto tup = validateArgsCountType(function, tup_);
     void* _Args[count];
     pArgs<0>(tup, _Args);
+#endif
     auto k = reinterpret_cast<void*>(function);
     auto result =
         hipLaunchKernel(k, grid_dim, block_dim, _Args, shared_memory_size_bytes, stream);
GKH_PATCH_EOF
         then
            echo "ERROR: gpu_kernel_helper.h HIP 7.13+ patch dry-run failed."
            echo "       Upstream may have moved the call sites; inspect ${_GKH_PATCH_FILE}"
            echo "       around the 'pArgs<0>(tup, _Args)' / 'validateArgsCountType(function, tup_)'"
            echo "       call sites and refresh the patch hunk. (branch=${GIT_BRANCH})"
            exit 1
         fi
         patch -p1 <<'GKH_PATCH_EOF'
--- a/tensorflow/core/util/gpu_kernel_helper.h
+++ b/tensorflow/core/util/gpu_kernel_helper.h
@@ -134,11 +134,21 @@
       return errors::Internal(cudaGetErrorString(result));
     }
 #elif TENSORFLOW_USE_ROCM
+#if HIP_VERSION >= 71300000
+    // ROCm 7.13+: new HIP kernel-arg API. validateArgsCountType is variadic;
+    // pArgs takes a single std::tuple<> reference and returns
+    // std::array<void*, N>. See <rocm>/include/hip/amd_detail/amd_hip_runtime.h.
+    auto tup = validateArgsCountType(function, arguments...);
+    auto _ArgsArr = pArgs(tup);
+    void** _Args = _ArgsArr.data();
+#else
+    // ROCm <= 7.2.x: legacy HIP kernel-arg API (tuple form + explicit <0> index).
     constexpr size_t count = sizeof...(Args);
     auto tup_ = std::tuple<Args...>{arguments...};
     auto tup = validateArgsCountType(function, tup_);
     void* _Args[count];
     pArgs<0>(tup, _Args);
+#endif
     auto k = reinterpret_cast<void*>(function);
     auto result =
         hipLaunchKernel(k, grid_dim, block_dim, _Args, shared_memory_size_bytes, stream);
GKH_PATCH_EOF
         echo "tensorflow: HIP 7.13+ kernel-arg API guard applied."
         echo ""
         unset _GKH_PATCH_FILE
      fi
      unset _GKH_NEEDS_HIP713_PATCH

      # ── ROCm 7.13+ flatbuffers shadowing fix ─────────────────────────
      # ROCm 7.13.0 is the FIRST ROCm release that ships a flatbuffers
      # header tree at <rocm>/include/flatbuffers/ (v25.9.23, consumed
      # internally by hipdnn/flatbuffers_sdk). Older ROCm (6.x .. 7.2.x)
      # ships no such directory (verified by direct file listing on
      # /shared/apps/ubuntu/opt/rocm-*.*.x/include).
      #
      # TF's XLA `rocm_headers_includes` cc_library glob in
      # third_party/xla/third_party/gpus/rocm/BUILD.tpl:
      #
      #   cc_library(
      #     name = "rocm_headers_includes",
      #     hdrs = glob(["%{rocm_root}/include/**"]),
      #     strip_include_prefix = "%{rocm_root}/include",
      #   )
      #
      # picks up <rocm>/include/flatbuffers/base.h on 7.13.0 and, because
      # of `strip_include_prefix`, exposes it as a bare
      # `flatbuffers/base.h` on the -isystem path. That SHADOWS TF's
      # bundled flatbuffers v24 (vendored under the @flatbuffers external
      # repo at v24) and trips the static_assert in
      # tensorflow/compiler/mlir/lite/schema/schema_generated.h:25
      #
      #   static_assert(FLATBUFFERS_VERSION_MAJOR == 24 && ...);
      #
      # which fires `25 == 24` and kills the
      # //tensorflow/compiler/mlir/lite:tensorflow_lite_optimize compile
      # (first diagnosed in slurm job 11562, rocm-7.13.0, 2026-06-05).
      #
      # The patch adds an `exclude = ["%{rocm_root}/include/flatbuffers/**"]`
      # arg to the same glob. On older ROCm this is a no-op (nothing to
      # exclude). TF code that needs flatbuffers continues to resolve it
      # through @flatbuffers (the bundled v24). TF code never wants
      # ROCm's flatbuffers tree -- only hipdnn does, and TF does not
      # consume hipdnn.
      #
      # Branch gate: same set as the HIP API patch above. Future ROCm/
      # tensorflow-upstream branches that change the BUILD.tpl shape
      # will fail the dry-run; abort with a loud diagnostic.
      if [[ "${_GKH_NEEDS_HIP713_PATCH:-}" == "1" || \
            "${GIT_BRANCH}" == "r2.20-rocm-enhanced" || \
            "${GIT_BRANCH}" == "r2.19-rocm-enhanced" || \
            "${GIT_BRANCH}" == "r2.18-rocm-enhanced" || \
            "${GIT_BRANCH}" == "r2.17-rocm-enhanced" || \
            "${GIT_BRANCH}" == "r2.16-rocm-enhanced" || \
            "${GIT_BRANCH}" == "r2.15-rocm-enhanced" ]]; then
         _ROCM_FB_PATCH_FILE=third_party/xla/third_party/gpus/rocm/BUILD.tpl
         echo ""
         echo "tensorflow: applying ROCm-flatbuffers shadowing fix to ${_ROCM_FB_PATCH_FILE}"
         echo "            (branch=${GIT_BRANCH}; see comment block in tensorflow_setup.sh)"
         if ! patch --dry-run -p1 >/dev/null 2>&1 <<'ROCM_FB_PATCH_EOF'
--- a/third_party/xla/third_party/gpus/rocm/BUILD.tpl
+++ b/third_party/xla/third_party/gpus/rocm/BUILD.tpl
@@ -75,9 +75,20 @@
 # and remove include prefix that is used to include rocm headers.
 cc_library(
     name = "rocm_headers_includes",
-    hdrs = glob([
-        "%{rocm_root}/include/**",
-    ]),
+    hdrs = glob(
+        include = ["%{rocm_root}/include/**"],
+        # ROCm 7.13.0 ships a `flatbuffers/` header tree (v25.9.23)
+        # under <rocm>/include/. TF's schema_generated.h was generated
+        # against flatbuffers v24 and contains
+        #   static_assert(FLATBUFFERS_VERSION_MAJOR == 24 && ...);
+        # Without this exclude, ROCm 7.13's flatbuffers/base.h shadows
+        # TF's bundled v24 via -isystem on _virtual_includes/
+        # rocm_headers_includes and the static_assert fires.
+        # Older ROCm (<=7.2.x) ships no flatbuffers/ tree, so the
+        # exclude is a no-op there. Patched by HPCTrainingDock
+        # extras/scripts/tensorflow_setup.sh.
+        exclude = ["%{rocm_root}/include/flatbuffers/**"],
+    ),
     strip_include_prefix = "%{rocm_root}/include",
 )
 
ROCM_FB_PATCH_EOF
         then
            echo "ERROR: BUILD.tpl flatbuffers-exclude patch dry-run failed."
            echo "       Upstream may have changed the rocm_headers_includes shape;"
            echo "       inspect ${_ROCM_FB_PATCH_FILE} around the"
            echo "       'name = \"rocm_headers_includes\"' cc_library and refresh"
            echo "       the patch hunk. (branch=${GIT_BRANCH})"
            exit 1
         fi
         patch -p1 <<'ROCM_FB_PATCH_EOF'
--- a/third_party/xla/third_party/gpus/rocm/BUILD.tpl
+++ b/third_party/xla/third_party/gpus/rocm/BUILD.tpl
@@ -75,9 +75,20 @@
 # and remove include prefix that is used to include rocm headers.
 cc_library(
     name = "rocm_headers_includes",
-    hdrs = glob([
-        "%{rocm_root}/include/**",
-    ]),
+    hdrs = glob(
+        include = ["%{rocm_root}/include/**"],
+        # ROCm 7.13.0 ships a `flatbuffers/` header tree (v25.9.23)
+        # under <rocm>/include/. TF's schema_generated.h was generated
+        # against flatbuffers v24 and contains
+        #   static_assert(FLATBUFFERS_VERSION_MAJOR == 24 && ...);
+        # Without this exclude, ROCm 7.13's flatbuffers/base.h shadows
+        # TF's bundled v24 via -isystem on _virtual_includes/
+        # rocm_headers_includes and the static_assert fires.
+        # Older ROCm (<=7.2.x) ships no flatbuffers/ tree, so the
+        # exclude is a no-op there. Patched by HPCTrainingDock
+        # extras/scripts/tensorflow_setup.sh.
+        exclude = ["%{rocm_root}/include/flatbuffers/**"],
+    ),
     strip_include_prefix = "%{rocm_root}/include",
 )
 
ROCM_FB_PATCH_EOF
         echo "tensorflow: ROCm-flatbuffers shadowing fix applied."
         echo ""
         unset _ROCM_FB_PATCH_FILE
      fi

      # AMDGPU_GFXMODEL is auto-detected from `rocminfo` (line 7) and on
      # multi-GPU nodes can be a `;`-separated list, e.g. "gfx942;gfx90a".
      # TensorFlow's MLIR `hlo_to_kernel` (the kernel-gen tool fed
      # --rocm_amdgpu_targets) only accepts a SINGLE chipset; passing the
      # list yields:
      #   <unknown>:0: error: Invalid chipset name: gfx942;gfx90a
      #   INTERNAL: Lowering to low-level device IR failed.
      # which then propagates to "Build did NOT complete successfully"
      # and the wheel target may or may not produce an artifact (race-y;
      # observed both outcomes in jobs 7959 and 7973). Reduce to the
      # FIRST gfx model in the list -- the most common deployment is
      # gfx942-primary (MI300) with gfx90a as a secondary device used
      # only for compatibility.
      #
      # The substitution `${AMDGPU_GFXMODEL%%;*}` strips the longest
      # match of `;*` from the tail. With no `;` it leaves the input
      # unchanged, so a plain "gfx942" is handled correctly without a
      # branch.
      #
      # TODO(audit_2026_05_01.md): Kokkos handles the same multi-arch
      # rejection by retrying single-arch on cmake failure
      # (kokkos_setup.sh "Falling back to single-arch"). For TF a
      # cleaner long-term fix is to BUILD ONCE PER ARCH and ship a
      # separate modulefile per gfx model (e.g. tensorflow/2.20-gfx942,
      # tensorflow/2.20-gfx90a) so a user `module load tensorflow/...
      # -gfx90a` selects the right wheel for their target device.
      # That is deferred -- it requires (a) iterating the build with
      # AMDGPU_GFXMODEL_SINGLE pinned to each entry, (b) installing
      # each wheel under a distinct ${TENSORFLOW_PATH}-<arch> prefix,
      # and (c) emitting per-arch modulefiles. For now we build a
      # single-arch wheel against the primary device only.
      AMDGPU_GFXMODEL_SINGLE="${AMDGPU_GFXMODEL%%;*}"
      echo "tensorflow: AMDGPU_GFXMODEL='${AMDGPU_GFXMODEL}' -> AMDGPU_GFXMODEL_SINGLE='${AMDGPU_GFXMODEL_SINGLE}' (TF MLIR kernel-gen requires single arch)"

      export TF_ROCM_AMDGPU_TARGETS=${AMDGPU_GFXMODEL_SINGLE}

      # Pin HERMETIC_PYTHON_VERSION to the system python3's MAJOR.MINOR.
      # Without this, TF's configure / bazel startup logs the warning
      #   HERMETIC_PYTHON_VERSION variable was not set correctly,
      #   using default version.
      # which lets TF pick its hardcoded default (currently 3.11) and
      # then bazel's hermetic_python rule downloads + builds an
      # interpreter that doesn't match PYTHON_BIN_PATH=/usr/bin/python3
      # used in ./configure -- silent ABI / extension-module mismatches
      # can sneak in. Audited from job 7974 log_tensorflow_05_01_2026.txt.
      # The system python3 on the Warewulf ubuntu-22.04 image is 3.10.
      HERMETIC_PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
      export HERMETIC_PYTHON_VERSION
      echo "tensorflow: HERMETIC_PYTHON_VERSION=${HERMETIC_PYTHON_VERSION}"

      # configure tensorflow
      #
      # CLANG_COMPILER_PATH: force TF's configure.py to use the ROCm
      # clang we already resolved at line 470 (`export CLANG_COMPILER`),
      # instead of letting it auto-detect.
      #
      # configure.py:819 (set_clang_compiler_path) defaults to
      # /usr/lib/llvm-18/bin/clang, then /usr/lib/llvm-17/, then
      # /usr/lib/llvm-16/, then shutil.which('clang'). On compute nodes
      # where Ubuntu ships a STUB /usr/lib/llvm-18/bin/clang (the
      # ubuntu-22.04 image has a 140KB binary at that path on some
      # Warewulf-deployed nodes -- a normal clang is 50-100MB), the
      # default is picked, the stub returns empty `--version` output,
      # and configure.py crashes at line 922 with
      #   IndexError: string index out of range
      # at curr_version[0] in retrieve_clang_version().
      # Repro: slurm job 11563 (rocm-7.2.3, 2026-06-05) on node
      # sh5-pl1-s12-15. Job 11562 (rocm-7.13.0) on sh5-pl1-s12-09
      # happened to succeed only because that node lacks the stub and
      # the fallback `shutil.which('clang')` picked the ROCm clang. So
      # the prior "success path" was a node-side accident, not a
      # robust configure.
      #
      # prompt_loop_or_load_from_env (configure.py:583) uses
      # `environ_cp.get(var_name) or var_default` -- if
      # CLANG_COMPILER_PATH is set in the environment, it bypasses the
      # default chain AND the prompt entirely. Setting it here is
      # idempotent across all ROCm versions.
      yes "" | TF_NEED_CLANG=1 ROCM_PATH=$ROCM_PATH TF_NEED_ROCM=1 PYTHON_BIN_PATH=/usr/bin/python3 TF_ROCM_AMDGPU_TARGETS=${AMDGPU_GFXMODEL_SINGLE} HERMETIC_PYTHON_VERSION=${HERMETIC_PYTHON_VERSION} CLANG_COMPILER_PATH=${CLANG_COMPILER} ./configure

      # build and install tensorflow
      #
      # Bazel performance tuning (audit_2026_05_01.md, bazel-perf inventory
      # items B + C). Each --host_jvm_args appears once and Bazel
      # accumulates them.
      #
      # JVM startup args (sized for the long "Computing main repo mapping"
      # / "Loading"/ "Analyzing" phases that hold up TF for 25-30 min on a
      # cold workspace):
      #   -Xmx16g            : default heap is too small for TF's ~600
      #                         transitive externals; the resolution phase
      #                         spends a large fraction of wall time in GC
      #                         on the default sizing.
      #   -XX:+UseG1GC       : reduces resolve-phase pause clusters vs the
      #                         default ParallelGC; better latency for the
      #                         many short allocations that Skyframe makes.
      #   -XX:+AlwaysPreTouch: pre-faults the heap pages at JVM start so
      #                         the resolution loop doesn't stall on lazy
      #                         page faults.
      #
      # Build flag:
      #   --noexperimental_check_external_repository_files :
      #     Bazel by default re-stats every file in every just-extracted
      #     external repo (millions of files for TF) before each build to
      #     detect on-disk drift. Safe to skip here because each setup-
      #     script run extracts externals fresh into the per-job mktemp
      #     workspace -- there is no opportunity for drift between
      #     extraction and analysis. Saves ~5-15 min on TF wall time.
      # Force bazel's output_base off NFS. By default bazel uses
      #   ${HOME}/.cache/bazel/_bazel_${USER}/<workspace-hash>
      # and on this cluster ${HOME} = /home/admin is an NFS mount, which
      # produces the explicit warning in job 7974:
      #   WARNING: Output base '/home/admin/.cache/bazel/_bazel_admin/...'
      #     is on NFS. This may lead to surprising failures and undetermined
      #     behavior.
      # NFS for the bazel server's working state hurts both correctness
      # (file locks, mtime granularity, shutil.copy2 over NFS-to-NFS) and
      # performance (millions of action-cache stat()s). Putting it under
      # the per-job mktemp ${TF_BUILD_ROOT} keeps each build fully
      # independent (no shared state between concurrent or back-to-back
      # jobs) AND off NFS. Cleaned up by the EXIT trap on TF_BUILD_ROOT
      # alongside the workspace.
      BAZEL_OUTPUT_BASE="${TF_BUILD_ROOT}/bazel-output"
      mkdir -p "${BAZEL_OUTPUT_BASE}"
      echo "tensorflow: bazel --output_base=${BAZEL_OUTPUT_BASE} (off NFS, per-job)"

      # Bazel build: explicitly capture rc and fail loudly if non-zero.
      # The leaf-script does NOT use `set -e`, so without this check
      # a Bazel failure (e.g. the librocm_smi64.so.1.0.* duplicate-
      # identifier abort in 7.2.2, or the hermetic-clang GLIBC_2.36
      # abort in 7.2.3) would silently continue into the wheel install,
      # the wheel-glob would not expand, pip3 would print
      # `ERROR: tensorflow*.whl is not a valid wheel filename.` and
      # *still* exit 0 because pip in 22.0.2 treats "no candidates" as
      # success when -v is set. The script would then write the
      # modulefile and main_setup.sh would mark tensorflow OK -- a
      # silent broken install. Audited in slurm-9002 (7.2.2) and
      # slurm-9003 (7.2.3) sweeps last evening.
      bazel \
         --output_base="${BAZEL_OUTPUT_BASE}" \
         --host_jvm_args=-Xmx16g \
         --host_jvm_args=-XX:+UseG1GC \
         --host_jvm_args=-XX:+AlwaysPreTouch \
         build --config=opt --config=rocm --repo_env=WHEEL_NAME=tensorflow_rocm \
               --action_env=project_name=tensorflow_rocm/ \
               --noexperimental_check_external_repository_files \
               //tensorflow/tools/pip_package:wheel --verbose_failures
      bazel_rc=$?
      if [ ${bazel_rc} -ne 0 ]; then
         echo ""
         echo "ERROR: bazel build of //tensorflow/tools/pip_package:wheel failed (rc=${bazel_rc})." >&2
         echo "       Refusing to write a modulefile for a tensorflow install that has no wheel." >&2
         echo "       See the bazel output above for the failing target. Common causes:" >&2
         echo "         - duplicate librocm_smi64.so.1.0.* SONAME in the ROCm install (delta merge stale lib)" >&2
         echo "         - hermetic clang in rocm/llvm/bin requires GLIBC newer than host" >&2
         exit ${bazel_rc}
      fi

      # Wheel-existence guard: glob to a real path BEFORE invoking pip3,
      # so a missing wheel becomes a hard failure instead of pip3 silently
      # accepting the literal "tensorflow*.whl" pattern and exiting 0.
      shopt -s nullglob
      tf_wheels=(bazel-bin/tensorflow/tools/pip_package/wheel_house/tensorflow*.whl)
      shopt -u nullglob
      if [ ${#tf_wheels[@]} -eq 0 ]; then
         echo "" >&2
         echo "ERROR: bazel reported success but produced no wheel at" >&2
         echo "       bazel-bin/tensorflow/tools/pip_package/wheel_house/tensorflow*.whl" >&2
         exit 1
      fi
      echo "tensorflow: built wheel(s): ${tf_wheels[*]}"

      pip3 install -v --target=$TF_PATH --upgrade "${tf_wheels[@]}"
      pip_rc=$?
      if [ ${pip_rc} -ne 0 ]; then
         echo "" >&2
         echo "ERROR: pip3 install of tensorflow wheel failed (rc=${pip_rc})." >&2
         exit ${pip_rc}
      fi

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find $TF_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $TF_PATH -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w $TF_PATH
      fi

      # cleanup: trap handles ${TF_BUILD_ROOT}/tensorflow-upstream
      cd /
      module unload ${ROCM_MODULE_NAME}
      module unload amdclang
   fi

   # Create a module file for tensorflow
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
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${TENSORFLOW_VERSION}.lua
	whatis("TensorFlow version ${TENSORFLOW_VERSION} with ROCm support")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Upstream branch: ${GIT_BRANCH}")

	prereq("${ROCM_MODULE_NAME}")
	prepend_path("PYTHONPATH","$TF_PATH")
	prepend_path("PATH","${TF_PATH}/bin")
        setenv("TF_CPP_MIN_LOG_LEVEL","2")
EOF

fi
