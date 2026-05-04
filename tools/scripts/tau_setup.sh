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
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus/tau
BUILD_TAU=0
ROCM_VERSION=6.2.0
TAU_PATH=/opt/rocmplus-${ROCM_VERSION}/tau
PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
TAU_PATH_INPUT=""
C_COMPILER=amdclang
CXX_COMPILER=amdclang++
F_COMPILER=amdflang
PDT_PATH_INPUT=""
GIT_COMMIT="fb4abfffa6683dd82a2b6ffddbfc497e6e1f5d60"
# TAU's modulefile is currently named dev.lua (no version baked in).
# PDT is a build-time-only dep shared with scorep, so we expose a
# separate --replace-pdt flag (analogous to scorep_setup.sh).
# --replace cleans tau + dev.lua; --replace-pdt cleans the shared PDT.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
REPLACE_PDT=0
KEEP_FAILED_INSTALLS=0
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
 echo "  WARNING: when specifying --tau-install-path, --pdt-install-path  and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-tau: default $BUILD_TAU"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --tau-install-path [ TAU_PATH_INPUT ] default $TAU_PATH"
   echo "  --c-compiler [ C_COMPILER ] default $C_COMPILER"
   echo "  --f-compiler [ F_COMPILER ] default $F_COMPILER"
   echo "  --cxx-compiler [ CXX_COMPILER ] default $CXX_COMPILER"
   echo "  --pdt-install-path [ PDT_PATH_INPUT ] default $PDT_PATH"
   echo "  --git-commit [ GIT_COMMIT ] specify what commit hash you want to build from, default is $GIT_COMMIT"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL_INPUT ] default autodetected"
   echo "  --replace [ 0|1 ] remove prior tau install + modulefile before building, default $REPLACE (PDT NOT removed)"
   echo "  --replace-pdt [ 0|1 ] also remove and rebuild the shared PDT install, default $REPLACE_PDT"
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
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--build-tau")
          shift
          BUILD_TAU=${1}
          reset-last
          ;;
      "--git-commit")
          shift
          GIT_COMMIT=${1}
          reset-last
          ;;
      "--c-compiler")
          shift
          C_COMPILER=${1}
          reset-last
          ;;
      "--f-compiler")
          shift
          F_COMPILER=${1}
          reset-last
          ;;
      "--cxx-compiler")
          shift
          CXX_COMPILER=${1}
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
      "--tau-install-path")
          shift
          TAU_PATH_INPUT=${1}
          reset-last
          ;;
      "--pdt-install-path")
          shift
          PDT_PATH_INPUT=${1}
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
      "--replace-pdt")
          shift
          REPLACE_PDT=${1}
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

TAU_PATH=/opt/rocmplus-${ROCM_VERSION}/tau
if [ "${TAU_PATH_INPUT}" != "" ]; then
   TAU_PATH=${TAU_PATH_INPUT}
fi

PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
if [ "${PDT_PATH_INPUT}" != "" ]; then
   PDT_PATH=${PDT_PATH_INPUT}
fi

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# TAU modulefile is dev.lua; PDT is shared (see scorep_setup.sh).
# ── BUILD_TAU=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_TAU}" = "0" ]; then
   echo "[tau BUILD_TAU=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[tau --replace 1] removing prior tau install + modulefile if present"
   echo "  install dir: ${TAU_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/dev.lua"
   ${SUDO} rm -rf "${TAU_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/dev.lua"
fi
if [ "${REPLACE_PDT}" = "1" ]; then
   echo "[tau --replace-pdt 1] removing prior PDT install"
   echo "  install dir: ${PDT_PATH}"
   ${SUDO} rm -rf "${PDT_PATH}"
fi

# ── Existence guard (see hypre_setup.sh) ─────────────────────────────
# Only the tau half is checked. PDT is shared with scorep and is
# intentionally preserved across re-installs; see scorep_setup.sh's
# existence-check comment block for the full rationale.
NOOP_RC=43
if [ -d "${TAU_PATH}" ]; then
   echo ""
   echo "[tau existence-check] ${TAU_PATH} already installed; skipping."
   echo "                      pass --replace 1 to force a clean rebuild."
   echo "                      (PDT existence not part of this check; see tau_setup.sh comments.)"
   echo ""
   exit ${NOOP_RC}
fi

_tau_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[tau fail-cleanup] rc=${rc}: removing partial tau install + modulefile (PDT preserved)"
      ${SUDO:-sudo} rm -rf "${TAU_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/dev.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[tau fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _tau_on_exit EXIT

echo ""
echo "==================================="
echo "Starting TAU Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_TAU: $BUILD_TAU"
echo "TAU_PATH: $TAU_PATH"
echo "PDT_PATH: $PDT_PATH"
echo "Building TAU off of this commit: $GIT_COMMIT"
echo "==================================="
echo ""


if [ "${BUILD_TAU}" = "0" ]; then

   echo "TAU will not be build, according to the specified value of BUILD_TAU"
   echo "BUILD_TAU: $BUILD_TAU"
   exit

else
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/pdt.tgz ] && [ -f ${CACHE_FILES}/tau.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached TAU"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/pdt.tgz
      tar -xpzf ${CACHE_FILES}/tau.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/pdt.tgz ${CACHE_FILES}/tau.tgz
      fi

   else

      echo ""
      echo "============================"
      echo " Building TAU"
      echo "============================"
      echo ""

      # rocm + openmpi are required at build time. openmpi is loaded
      # later (line ~252) but pre-flighting it here surfaces the missing
      # dep early rather than after a multi-minute PDT/spack download.
      REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" "openmpi" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

     # don't use sudo if user has write access to both install paths
      if [ -d "$TAU_PATH" ]; then
         if [ -d "$PDT_PATH" ]; then
            # don't use sudo if user has write access to both install paths
            if [ -w ${TAU_PATH} ]; then
               if [ -w ${PDT_PATH} ]; then
                  SUDO=""
                  echo "WARNING: not using sudo since user has write access to install path, some dependencies may fail to get installed without sudo"
               else
                  echo "WARNING: using install paths that require sudo"
               fi
            fi
         fi
      else
         # if install paths do not both exist yet
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      export TAU_LIB_DIR=${TAU_PATH}/x86_64/lib
      ${SUDO} mkdir -p ${TAU_PATH}
      ${SUDO} mkdir -p ${PDT_PATH}

      # Build everything (spack clone + PDT install scratch +
      # tau2 source + 8 build flavors of compile artifacts) under
      # /tmp on compute-node local disk to avoid NFS round-trips.
      # Only `spack install pdt` and `make install` writes hit NFS,
      # via the absolute install paths in --prefix / install_tree.
      # Combined EXIT trap covers TAU_BUILD_DIR plus the two spack
      # user-scope isolation dirs created below. Audit basis: 7950
      # tau took 39m11s with build under
      # /home/admin/repos/HPCTrainingDock/tau2/...
      TAU_BUILD_DIR=$(mktemp -d -t tau-build.XXXXXX)

      # Spack user-scope isolation: redirect ~/.spack to per-job
      # throwaway dirs so `spack external find --all` and the
      # `spack config add "config:install_tree:root:..."` below
      # write to those throwaway dirs instead of polluting
      # ~/.spack/{packages,config}.yaml across rocm versions. Without
      # this, the user-scope install_tree.root from a prior build
      # makes `spack location -i pdt` return another rocm tree's path
      # (observed cross-contamination in rocmplus-7.0.1 scorep
      # modulefile pointing at /nfsapps/opt/rocmplus-7.0.2/pdt/...).
      SPACK_USER_CONFIG_PATH=$(mktemp -d -t spack-user-config.XXXXXX)
      SPACK_USER_CACHE_PATH=$(mktemp -d -t spack-user-cache.XXXXXX)
      export SPACK_USER_CONFIG_PATH SPACK_USER_CACHE_PATH
      trap '${SUDO:-sudo} rm -rf "${TAU_BUILD_DIR:-/nonexistent}" "${SPACK_USER_CONFIG_PATH:-/nonexistent}" "${SPACK_USER_CACHE_PATH:-/nonexistent}"' EXIT

      cd "${TAU_BUILD_DIR}"
      git clone --depth 1 https://github.com/spack/spack.git

      # load spack environment
      source spack/share/spack/setup-env.sh

      # find already installed libs for spack
      spack external find --all

      # change spack install dir for PDT
      # With SPACK_USER_CONFIG_PATH set above, this writes to the
      # per-job throwaway user config dir, isolated from other builds.
      spack config add "config:install_tree:root:${PDT_PATH}"

      # open permissions to use spack to install PDT
      if [[ "${USER}" != "root" ]]; then
	 ${SUDO} chmod -R a+rwX $PDT_PATH
	 ${SUDO} chmod -R a+rwX $TAU_PATH
      fi

      # install PDT with spack
      spack install pdt

      # get PDT install dir created by spack
      PDT_PATH_ORIGINAL=$PDT_PATH
      PDT_PATH=$(spack location -i pdt)
      export PDTDIR=$PDT_PATH

      # We are already in ${TAU_BUILD_DIR} from the spack section
      # above; tau2 will be cloned into ${TAU_BUILD_DIR}/tau2.
      #
      # Partial clone (--filter=blob:none) skips downloading blobs
      # for history we don't need; the subsequent `git checkout
      # $GIT_COMMIT` lazily fetches just the blobs for that commit.
      # Reduces clone wall-time and disk by ~5-10x vs full clone
      # while still supporting checkout of any specific commit
      # (unlike --depth 1, which only gives the tip of the default
      # branch).
      git clone --filter=blob:none https://github.com/UO-OACISS/tau2.git || { echo "ERROR: git clone of tau2 failed"; exit 1; }
      cd tau2
      git checkout $GIT_COMMIT || { echo "ERROR: git checkout $GIT_COMMIT failed"; exit 1; }

      # Patch tau's vendored plugins/llvm/Makefile to (a) embed the
      # ROCm LLVM include dir into CMAKE_CXX_FLAGS, and (b) split
      # `make install` into separate build/install passes via cmake.
      #
      # Background (audit_2026_05_01.md, jobs 7974 and 7975
      # log_tau_05_01_2026.txt):
      # The TAU plugins/llvm CMake setup is intermittent about how it
      # computes LLVM_INCLUDE_DIRS. In job 7974 the first compile pass
      # succeeded with -I${ROCM_PATH}/lib/llvm/include on the command
      # line, then `make install` triggered a cmake re-stat that
      # rebuilt with that -I dropped, failing at "clang/Basic/
      # SourceManager.h: No such file" at log line 3459. The first
      # mitigation (commit 8ff591b's tau_setup.sh) replaced
      #   && make VERBOSE=1 -j install
      # with
      #   && cmake --build . --parallel && cmake --install .
      # but in job 7975 the FIRST compile pass already drops the -I
      # (log:3457) before the install pass even runs, so the cmake-
      # split alone is insufficient.
      #
      # The robust fix is to embed -I${ROCM_PATH}/lib/llvm/include into
      # CMAKE_CXX_FLAGS via the cmake invocation itself. CMAKE_CXX_FLAGS
      # is appended to every g++ compile by cmake's generated rules and
      # SURVIVES any reconfigure (it's stored in CMakeCache.txt and
      # regenerated identically), unlike LLVM_INCLUDE_DIRS which is
      # auto-detected per cmake run from -DLLVM_DIR's CMake config and
      # CAN be lost on a re-stat. The clang headers exist at
      #   ${ROCM_PATH}/lib/llvm/include/clang/Basic/SourceManager.h
      # for every ROCm 7.x; making the include path part of the compile
      # flag itself bypasses the LLVM_INCLUDE_DIRS code path entirely.
      #
      # Single sed replacing the trailing
      #   -DCMAKE_BUILD_TYPE=Debug && make VERBOSE=1 -j install
      # with
      #   -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS=-I${ROCM_PATH}/lib/llvm/include
      #     && cmake --build . --parallel && cmake --install .
      # Double-quoted so ${ROCM_PATH} expands at sed time; cmake-3.15+
      # provides --install, which is available in the bundled
      # /usr/local/bin/cmake (Python pip cmake) that tau's
      # plugins/llvm/Makefile invokes (job 7974/7975 log line 3215/3433).
      if [ -f plugins/llvm/Makefile ]; then
         sed -i "s|-DCMAKE_BUILD_TYPE=Debug && make VERBOSE=1 -j install|-DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS=-I${ROCM_PATH}/lib/llvm/include \\&\\& cmake --build . --parallel \\&\\& cmake --install .|" plugins/llvm/Makefile
      fi

      # install third party dependencies
      # -q to drop wget dot-progress noise from the per-package log,
      # matching the precedent in comm/scripts/openmpi_setup.sh and the
      # S6.E fix in tools/scripts/scorep_setup.sh.
      wget -q http://tau.uoregon.edu/ext.tgz

      tar zxf ext.tgz

      # PKG_SUDO: apt needs root regardless of the install-path-derived
      # SUDO. The previous code passed ${SUDO} to apt directly, so a
      # build to an admin-writable install path (SUDO='') would have
      # tried `apt-get update` without sudo and failed with
      # /var/lib/apt/lists/lock Permission denied. See openmpi_setup.sh
      # / audit_2026_05_01.md Issue 2 for the original case.
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")

      # install OpenMPI if not in the system already
      # openmpi already loaded by preflight_modules above.
      if [[ `which mpicc | wc -l` -eq 0 ]]; then
         ${PKG_SUDO} apt-get update
         ${PKG_SUDO} apt-get install -q -y libopenmpi-dev
      fi

      # install java to use paraprof
      ${PKG_SUDO} apt-get update
      ${PKG_SUDO} apt install -q -y default-jre

      ROCM_FLAGS="-rocm=${ROCM_PATH} -hip=${ROCM_PATH} -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -rocprofiler=${ROCM_PATH}"
      result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
      if [[ "${result}" ]]; then # ROCM_VERSION >= 6.2
         ROCM_FLAGS="-rocm=${ROCM_PATH} -hip=${ROCM_PATH} -rocmsmi=${ROCM_PATH} -rocprofsdk=${ROCM_PATH} -llvm_src=${ROCM_PATH}/llvm/lib/cmake/llvm"
      fi

      # configure with: MPI OMPT OPENMP PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download ${ROCM_FLAGS} -mpi -ompt -openmp -pdt=${PDT_PATH} -iowrapper

      make -j $(nproc)
      ${SUDO} env PATH=$PATH make install

      # configure with: MPI PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download ${ROCM_FLAGS} -mpi -pdt=${PDT_PATH} -iowrapper

      make -j $(nproc)
      ${SUDO} env PATH=$PATH make install

      # configure with: OMPT OPENMP PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -ompt -openmp -pdt=${PDT_PATH} -iowrapper

      make -j $(nproc)
      ${SUDO} env PATH=$PATH make install

      # configure with: PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -pdt=${PDT_PATH} -iowrapper

      make -j $(nproc)
      ${SUDO} env PATH=$PATH make install

      # configure with: ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -iowrapper

      make -j $(nproc)
      ${SUDO} env PATH=$PATH make install

      # configure with: OMPT OPENMP ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -ompt -openmp -iowrapper

      make -j $(nproc)
      ${SUDO} env PATH=$PATH make install

      # configure with: MPI ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -mpi -iowrapper

      make -j $(nproc)
      ${SUDO} env PATH=$PATH make install

      # configure with: MPI OMPT OPENMP ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download ${ROCM_FLAGS} -mpi -ompt -openmp -iowrapper

      make -j $(nproc)
      ${SUDO} env PATH=$PATH make install

      # the configure flag -no_pthread_create
      # still creates linking options for the pthread wrapper
      # that are breaking the instrumentation tests in C and C++
      ${SUDO} rm ${TAU_PATH}/x86_64/lib/wrappers/pthread_wrapper/link_options.tau

      # TAU_BUILD_DIR (under /tmp, contains tau2/ and the spack clone)
      # is removed by the EXIT trap above. No need to rm -rf tau2 or
      # spack explicitly here.

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find $PDT_PATH_ORIGINAL -type f -execdir chown root:root "{}" +
         ${SUDO} find $PDT_PATH_ORIGINAL -type d -execdir chown root:root "{}" +
         ${SUDO} find $TAU_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $TAU_PATH -type d -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w $PDT_PATH_ORIGINAL
         ${SUDO} chmod go-w $TAU_PATH
      fi

      module unload rocm/${ROCM_VERSION}

   fi

   # Create a module file for TAU
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/dev.lua
	whatis(" TAU - portable profiling and tracing toolkit ")

	prereq("rocm/${ROCM_VERSION}")
	prepend_path("PATH","${TAU_PATH}/x86_64/bin")
	prepend_path("PATH","${PDT_PATH}/bin")
	setenv("TAU_LIB_DIR","${TAU_LIB_DIR}")
EOF

fi
