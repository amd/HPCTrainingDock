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
TENSORFLOW_VERSION="r2.20-rocm-enhanced"
GIT_BRANCH="${TENSORFLOW_VERSION}"
# --replace 1: rm -rf prior install dir + ${GIT_BRANCH}.lua before build.
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
   echo "  --build-tensorflow [ BUILD_TF ] default $BUILD_TF "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --install-path [ TF_PATH ] default $TF_PATH "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --tensorflow-version [ TENSORFLOW_VERSION ] git branch/tag of the upstream TensorFlow tree to build (synonym for --git-branch), default $TENSORFLOW_VERSION"
   echo "  --git-branch [ GIT_BRANCH ] specify what commit git branch you want to build, default is $GIT_BRANCH"
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
          GIT_BRANCH=${1}
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
   echo "  modulefile:  ${MODULE_PATH}/${GIT_BRANCH}.lua"
   ${SUDO} rm -rf "${TF_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${GIT_BRANCH}.lua"
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
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${GIT_BRANCH}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[tensorflow fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _tensorflow_on_exit EXIT

# Derive ROCM_MODULE_NAME from the actual ROCM_PATH basename so RC
# trees (rocm-therock-*, rocm-afar-*) match their loaded module name
# instead of the SDK numeric. Falls back to the rocm/<version> form
# for direct standalone invocation where ROCM_PATH is unset.
if [[ -n "${ROCM_PATH:-}" ]]; then
   _rp_bn="${ROCM_PATH##*/}"
   ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
   unset _rp_bn
else
   ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
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
   if [ -f ${CACHE_FILES}/tensorflow.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached TensorFlow"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/tensorflow
      cd /opt/rocmplus-${ROCM_VERSION}
      #${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/tensorflow.tgz
      #chown -R root:root /opt/rocmplus-${ROCM_VERSION}/tensorflow
      #${SUDO} chmod og-w /opt/rocmplus-${ROCM_VERSION}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/tensorflow.tgz
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
      yes "" | TF_NEED_CLANG=1 ROCM_PATH=$ROCM_PATH TF_NEED_ROCM=1 PYTHON_BIN_PATH=/usr/bin/python3 TF_ROCM_AMDGPU_TARGETS=${AMDGPU_GFXMODEL_SINGLE} HERMETIC_PYTHON_VERSION=${HERMETIC_PYTHON_VERSION} ./configure

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
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${GIT_BRANCH}.lua
	whatis("Tensorflow with ROCm support")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prereq("${ROCM_MODULE_NAME}")
	prepend_path("PYTHONPATH","$TF_PATH")
        setenv("TF_CPP_MIN_LOG_LEVEL","2")
EOF

fi
