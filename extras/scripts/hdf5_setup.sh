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
MODULE_PATH=/etc/lmod/modules/ROCmPlus/hdf5
BUILD_HDF5=0
ROCM_VERSION=6.2.0
ROCM_MODULE="rocm"
C_COMPILER=`which gcc`
C_COMPILER_INPUT=""
CXX_COMPILER=`which g++`
CXX_COMPILER_INPUT=""
F_COMPILER=`which gfortran`
F_COMPILER_INPUT=""
ENABLE_PARALLEL_INPUT=""
HDF5_VERSION=1.14.6
MPI_MODULE="openmpi"
HDF5_PATH=/opt/rocmplus-${ROCM_VERSION}/hdf5-v${HDF5_VERSION}
HDF5_PATH_INPUT=""
# --install-path: parent dir; the script appends hdf5-v${HDF5_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf prior install dir + ${HDF5_VERSION}.lua before building.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --rocm-module [ ROCM_MODULE ] default $ROCM_MODULE"
   echo "  --hdf5-version [ HDF5_VERSION ] default $HDF5_VERSION"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --enable-parallel [ ENABLE_PARALLEL ], set to ON or OFF, ON by default if MPI is installed"
   echo "  --install-path-no-version [ HDF5_PATH ] default $HDF5_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), HDF5_PATH = ROCMPLUS_PATH/hdf5-v\${HDF5_VERSION}"
   echo "  --c-compiler [ C_COMPILER ] default ${C_COMPILER}"
   echo "  --cxx-compiler [ CXX_COMPILER ] default ${CXX_COMPILER}"
   echo "  --f-compiler [ F_COMPILER ] default ${F_COMPILER}"
   echo "  --build-hdf5 [ BUILD_HDF5 ], set to 1 to build HDF5, default is 0"
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
      "--build-hdf5")
          shift
          BUILD_HDF5=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
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
          HDF5_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--enable-parallel")
          shift
          ENABLE_PARALLEL_INPUT=${1}
          reset-last
          ;;
      "--c-compiler")
          shift
          C_COMPILER=${1}
          reset-last
          ;;
      "--cxx-compiler")
          shift
          CXX_COMPILER=${1}
          reset-last
          ;;
      "--f-compiler")
          shift
          F_COMPILER=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--rocm-module")
          shift
          ROCM_MODULE=${1}
          reset-last
          ;;
      "--hdf5-version")
          shift
          HDF5_VERSION=${1}
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

if [ "${HDF5_PATH_INPUT}" != "" ]; then
   HDF5_PATH=${HDF5_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends hdf5-v${HDF5_VERSION} from its own default.
   # Lets main_setup.sh stay version-agnostic for hdf5.
   HDF5_PATH=${ROCMPLUS_PATH_INPUT}/hdf5-v${HDF5_VERSION}
else
   # override path in case HDF5_VERSION has been supplied as input
   HDF5_PATH=/opt/rocmplus-${ROCM_VERSION}/hdf5-v${HDF5_VERSION}
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# ── BUILD_HDF5=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_HDF5}" = "0" ]; then
   echo "[hdf5 BUILD_HDF5=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[hdf5 --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HDF5_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${HDF5_VERSION}.lua"
   ${SUDO} rm -rf "${HDF5_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${HDF5_VERSION}.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${HDF5_PATH}" ]; then
   echo ""
   echo "[hdf5 existence-check] ${HDF5_PATH} already installed; skipping."
   echo "                       pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

_hdf5_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hdf5 fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${HDF5_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${HDF5_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[hdf5 fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _hdf5_on_exit EXIT

if [ "${BUILD_HDF5}" = "0" ]; then

   echo "HDF5 will not be built, according to the specified value of BUILD_HDF5"
   echo "BUILD_HDF5: $BUILD_HDF5"
   echo "Make sure to set '--build-hdf5 1' when running this install script"
   exit

else

   echo ""
   echo "==============================="
   echo " Installing HDF5"
   echo " Install directory: $HDF5_PATH"
   echo " Module directory: $MODULE_PATH"
   echo " HDF5 Version: $HDF5_VERSION"
   echo " ROCm Version: $ROCM_VERSION"
   echo "==============================="
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

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
   #   3. ${ROCM_MODULE}/${ROCM_VERSION}: standalone-invocation fallback when
   #      neither LOADEDMODULES nor ROCM_PATH is populated.
   ROCM_MODULE_NAME=""
   if [[ -n "${LOADEDMODULES:-}" ]]; then
      _OLD_IFS="${IFS}"; IFS=":"
      for _m in ${LOADEDMODULES}; do
         case "${_m}" in
            ${ROCM_MODULE:-rocm}/*) ROCM_MODULE_NAME="${_m}"; break ;;
         esac
      done
      IFS="${_OLD_IFS}"; unset _OLD_IFS _m
   fi
   if [[ -z "${ROCM_MODULE_NAME}" ]]; then
      if [[ -n "${ROCM_PATH:-}" ]]; then
         _rp_bn="${ROCM_PATH##*/}"
         ROCM_MODULE_NAME="${ROCM_MODULE}/${_rp_bn#rocm-}"
         unset _rp_bn
      else
         ROCM_MODULE_NAME="${ROCM_MODULE}/${ROCM_VERSION}"
      fi
   fi

   if [ -f ${CACHE_FILES}/hdf5-v${HDF5_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HDF5"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # hdf5-v${HDF5_VERSION}.tgz and contain a top-level directory
      # hdf5-v${HDF5_VERSION}/ so it lands directly at ${HDF5_PATH}
      # when extracted under /opt/rocmplus-X. (Previous code cd'd into
      # /opt and chown'd /opt/hdf5-v..., which left the install in the
      # wrong place; corrected here as part of the multi-version pass.)
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/hdf5-v${HDF5_VERSION}.tgz
      chown -R root:root ${HDF5_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/hdf5-v${HDF5_VERSION}.tgz
      fi

   else
      echo ""
      echo "==============================="
      echo " Installing HDF5 from source"
      echo "==============================="
      echo ""

      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh

      # don't use sudo if user has write access to install path
      if [ -d "$HDF5_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${HDF5_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${HDF5_PATH}
      ${SUDO} mkdir -p ${HDF5_PATH}/zlib
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${HDF5_PATH}
      fi

      # Build under /tmp (compute-node local disk) so the hdf5
      # source clone, the zlib build, and the main cmake build
      # don't all round-trip through NFS for every .o, .a, .so.
      # Only `make install` writes hit NFS via the absolute
      # CMAKE_INSTALL_PREFIX=${HDF5_PATH}. EXIT trap guarantees
      # cleanup even on build failure (we have set -e). Audit basis:
      # 7950 hdf5 took ~11m50s with build under
      # /home/admin/repos/HPCTrainingDock/hdf5/...
      HDF5_BUILD_DIR=$(mktemp -d -t hdf5-build.XXXXXX)
      trap '[ -n "${HDF5_BUILD_DIR:-}" ] && ${SUDO:-sudo} rm -rf "${HDF5_BUILD_DIR}"' EXIT
      cd "${HDF5_BUILD_DIR}"

      # --depth=1 to skip ~10 years of history we don't need; the
      # branch tag pins us to the exact release.
      #
      # Tag-name probe: the HDF Group used `hdf5_X.Y.Z` for the 1.14
      # series (e.g. hdf5_1.14.6) but for HDF5 2.1.1 ship the bare
      # numeric tag `2.1.1`. Probe both forms and use whichever
      # exists; fail hard if neither does so we don't silently land
      # on the default branch (which would float past the requested
      # release on every build).
      HDF5_TAG=""
      for _cand in "hdf5_${HDF5_VERSION}" "${HDF5_VERSION}"; do
         if git ls-remote --exit-code --tags https://github.com/HDFGroup/hdf5.git \
               "refs/tags/${_cand}" >/dev/null 2>&1; then
            HDF5_TAG="${_cand}"
            break
         fi
      done
      unset _cand
      if [ -z "${HDF5_TAG}" ]; then
         echo "ERROR: no git tag matching HDF5 ${HDF5_VERSION} (tried 'hdf5_${HDF5_VERSION}' and '${HDF5_VERSION}')." >&2
         exit 1
      fi
      echo "HDF5: using git tag '${HDF5_TAG}'"
      git clone --depth=1 --branch "${HDF5_TAG}" https://github.com/HDFGroup/hdf5.git
      cd hdf5

      # install dependencies

      # get ZLIB
      # -q to drop wget dot-progress noise from the per-package log,
      # matching the precedent in comm/scripts/openmpi_setup.sh and the
      # S6.E fix in tools/scripts/scorep_setup.sh.
      wget -q https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
      tar zxf zlib-1.3.1.tar.gz
      cd zlib-1.3.1
      ./configure --prefix=${HDF5_PATH}/zlib
      # zlib's autotools install target depends on `all`, so a
      # parallel install is equivalent to `make -j && make install`
      # here. Saves ~30s on a 96-core node vs serial.
      make -j $(nproc) install

      # get LIBAEC -- support for szip library is currently broken: https://github.com/HDFGroup/hdf5/issues/4614
      #wget https://github.com/MathisRosenhauer/libaec/releases/download/v1.1.3/libaec-1.1.3.tar.gz
      #tar zxf libaec-1.1.3.tar.gz
      #${SUDO} mkdir -p ${HDF5_PATH}/libaec
      #cd libaec-1.1.3
      #${SUDO} ./configure --prefix=${HDF5_PATH}/libaec
      #${SUDO} make install

      # default build is serial hdf5
      ENABLE_PARALLEL="OFF"
      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?
      if [[ `which mpicc | wc -l` -eq 1 ]]; then
	 # if mpicc is found in the path, build hdf5 parallel
         ENABLE_PARALLEL="ON"
	 C_COMPILER=`which mpicc`
	 CXX_COMPILER=`which mpicxx`
	 F_COMPILER=`which mpifort`

	 # OpenMPI's mpifort/mpicxx have the Fortran/C++ compiler name
	 # baked in at OpenMPI configure-time. On the rocmplus-6.x trees
	 # the openmpi/5.0.10 install was configured against amdflang,
	 # but ROCm 6.3.x SDKs only ship amdflang under ${ROCM_PATH}/llvm/bin/,
	 # which is NOT on PATH after `module load rocm/6.3.x` (the module
	 # prepends ${ROCM_PATH}/bin only). ROCm 6.4.x DOES ship amdflang
	 # under ${ROCM_PATH}/bin/, so it works there.
	 #
	 # Result on 6.3.x: mpifort -> "Open MPI wrapper compiler was
	 # unable to find the specified compiler amdflang in your PATH"
	 # and the HDF5 cmake Fortran-ABI probe fails (sweep 10220-10224,
	 # 2026-05-20). Fix: when amdflang is missing from PATH but the
	 # rocm SDK ships one under llvm/bin, extend PATH so mpifort
	 # finds the SDK's own amdflang. This is the SAME compiler the
	 # openmpi/mpifort wrapper was originally configured against, so
	 # the mpi.mod is in the correct Flang module format and no
	 # OMPI_FC override is needed (which would have introduced a
	 # different incompatibility -- gfortran can't read amdflang-
	 # classic's V34 .mod files; verified slurm 10237, 2026-05-20).
	 #
	 # No-op on ROCm 7.x (amdflang already on PATH) and on 6.4.x
	 # (same).
	 if ! command -v amdflang >/dev/null 2>&1 \
	      && [ -n "${ROCM_PATH:-}" ] \
	      && [ -x "${ROCM_PATH}/llvm/bin/amdflang" ]; then
	    export PATH="${ROCM_PATH}/llvm/bin:${PATH}"
	    echo "HDF5: amdflang not on PATH; prepending ${ROCM_PATH}/llvm/bin (mpifort wrapper depends on it)"
	 fi
      fi

      # override flags with user defined values if present
      if [ "${ENABLE_PARALLEL_INPUT}" != "" ]; then
         ENABLE_PARALLEL=${ENABLE_PARALLEL_INPUT}
      fi
      if [ "${C_COMPILER_INPUT}" != "" ]; then
         C_COMPILER=${C_COMPILER_INPUT}
      fi
      if [ "${CXX_COMPILER_INPUT}" != "" ]; then
         CXX_COMPILER=${CXX_COMPILER_INPUT}
      fi
      if [ "${F_COMPILER_INPUT}" != "" ]; then
         F_COMPILER=${F_COMPILER_INPUT}
      fi

      cd ..
      mkdir build && cd build

      # HDF5 2.x: per HDF5 issue #6019, the rename story we had
      # before was WRONG. HDF5_ENABLE_PARALLEL is STILL the
      # build-time KNOB in 2.x (same as 1.x). HDF5_PROVIDES_PARALLEL
      # is a read-only STATE variable that the HDF5 build SETS for
      # downstream consumers to query -- it does NOT enable parallel
      # when passed in as a -D flag. The 2.x docs (INSTALL_CMake.md)
      # still say `HDF5_ENABLE_PARALLEL` is the option.
      #
      # The 2026-05-20 sweep (slurm 10200) silently produced a
      # SERIAL hdf5/2.1.1 because we passed
      # -DHDF5_PROVIDES_PARALLEL:BOOL=ON (the state var, ignored),
      # and the resulting H5pubconf.h has /* #undef H5_HAVE_PARALLEL */
      # -- meaning H5Pset_dxpl_mpio / H5Pset_fapl_mpio /
      # H5Pset_coll_metadata_write / H5Pset_all_coll_metadata_ops
      # are not declared, downstream parallel-IO consumers fail to
      # compile, and h5perf_serial gets installed instead of h5pcc.
      # See verification under /shared/apps/ubuntu/opt/rocmplus-7.2.3/
      # hdf5-v2.1.1/HDF_Group/HDF5/2.1.1/include/H5pubconf.h.
      #
      # Fix: always pass -DHDF5_ENABLE_PARALLEL:BOOL=ON for both 1.x
      # and 2.x. Also pass HDF5_PROVIDES_PARALLEL defensively for
      # 2.x, in case a future minor release actually does honor it
      # as a build knob (cheap, harmless overlap).
      HDF5_PARALLEL_VAR="HDF5_ENABLE_PARALLEL"
      HDF5_IS_2X=0
      HDF5_PARALLEL_EXTRA_ARGS=()
      if [ "$(printf '%s\n%s\n' "2.0.0" "${HDF5_VERSION}" | sort -V | head -n1)" = "2.0.0" ]; then
         HDF5_IS_2X=1
         # Belt-and-suspenders: also set the state var explicitly
         # so any downstream find_package(HDF5) probe that looks at
         # HDF5_PROVIDES_PARALLEL gets the right answer.
         HDF5_PARALLEL_EXTRA_ARGS+=( "-DHDF5_PROVIDES_PARALLEL:BOOL=${ENABLE_PARALLEL}" )
      fi
      echo "HDF5: parallel CMake var = ${HDF5_PARALLEL_VAR} (HDF5_VERSION=${HDF5_VERSION}, HDF5_IS_2X=${HDF5_IS_2X})"

      # ZLIB enable: HDF5 2.x no longer honors ZLIB_ROOT (CMake
      # "Manually-specified variables were not used" warning, audited
      # in slurm 9711). The 2.x knobs (per the AutotoolsToCMakeOptions
      # migration guide for HDF5 2.0.0 and issue HDFGroup/hdf5#5155):
      #   HDF5_ENABLE_ZLIB_SUPPORT=ON     -- enable zlib filter
      #   ZLIB_USE_EXTERNAL=OFF           -- "OFF" tells HDF5 to use an
      #                                      installed/external zlib
      #                                      rather than build one
      #                                      in-tree
      #   HDF5_ALLOW_EXTERNAL_SUPPORT=NO  -- don't FetchContent zlib
      #   H5_ZLIB_INCLUDE_DIR / H5_ZLIB_LIBRARY -- point at the zlib
      #                                      we just built under
      #                                      ${HDF5_PATH}/zlib/
      # Without H5_HAVE_ZLIB_H landing in H5public.h, netcdf-c 4.10.0
      # configure aborts with "HDF5 was built without zlib." For HDF5
      # 1.x we keep ZLIB_ROOT (which 1.x's FindZLIB.cmake honors).
      HDF5_ZLIB_CMAKE_ARGS=()
      if [ "${HDF5_IS_2X}" = "1" ]; then
         # Prefer the shared library (.so.1.3.1 from our zlib build).
         _h5_zlib_so="$(ls "${HDF5_PATH}/zlib/lib/"libz.so.* 2>/dev/null | head -n1)"
         if [ -z "${_h5_zlib_so}" ] || [ ! -f "${_h5_zlib_so}" ]; then
            _h5_zlib_so="${HDF5_PATH}/zlib/lib/libz.a"
         fi
         HDF5_ZLIB_CMAKE_ARGS=(
            -DHDF5_ENABLE_ZLIB_SUPPORT:BOOL=ON
            -DZLIB_USE_EXTERNAL:BOOL=OFF
            -DHDF5_ALLOW_EXTERNAL_SUPPORT:STRING=NO
            -DH5_ZLIB_INCLUDE_DIR:PATH="${HDF5_PATH}/zlib/include"
            -DH5_ZLIB_LIBRARY:FILEPATH="${_h5_zlib_so}"
            -DZLIB_INCLUDE_DIR:PATH="${HDF5_PATH}/zlib/include"
            -DZLIB_LIBRARY:FILEPATH="${_h5_zlib_so}"
         )
         echo "HDF5: zlib hint = ${_h5_zlib_so}"
         unset _h5_zlib_so
      else
         HDF5_ZLIB_CMAKE_ARGS=( -DZLIB_ROOT="${HDF5_PATH}/zlib" )
      fi

      # -fPIC for the Fortran compile + CMAKE_POSITION_INDEPENDENT_CODE for
      # HDF5's own libs: required because Ubuntu 22.04 ships a PIE-default
      # toolchain (gcc/g++ links executables -fPIE), and on rocm 6.4.x
      # mpifort resolves to amdflang (classic Flang 99.99.1) which does
      # NOT default to PIC. CMake's internal FortranCInterface check
      # compiles VerifyFortran.f -> libVerifyFortran.a (no -fPIC), then
      # tries to link it into a PIE executable VerifyFortranC, which
      # fails with `relocation R_X86_64_32 against .rodata can not be
      # used when making a PIE object; recompile with -fPIE` (slurm 8388
      # / 8391, 2026-05-06). Setting CMAKE_Fortran_FLAGS=-fPIC ensures the
      # FortranCInterface test compile gets PIC; CMAKE_POSITION_INDEPENDENT_CODE
      # ensures HDF5's own Fortran static libs do too.
      # No-op cost on rocm 7.x (amdflang-new defaults to PIC) and on
      # gfortran (also no-op since only used for static libs here).
      cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE:STRING=Release \
  			        -DHDF5_BUILD_TOOLS:BOOL=ON -DCMAKE_INSTALL_PREFIX=${HDF5_PATH} \
                                "${HDF5_ZLIB_CMAKE_ARGS[@]}" \
				-DHDF5_ENABLE_SZIP_SUPPORT:BOOL=OFF \
                                -DCMAKE_CXX_COMPILER=${CXX_COMPILER} \
                                -DCMAKE_C_COMPILER=${C_COMPILER} \
				-DCMAKE_Fortran_COMPILER=${F_COMPILER} \
				-DCMAKE_Fortran_FLAGS="-fPIC" \
				-DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON \
				-DBUILD_TESTING:BOOL=OFF \
				-D${HDF5_PARALLEL_VAR}:BOOL=${ENABLE_PARALLEL} \
				"${HDF5_PARALLEL_EXTRA_ARGS[@]}" \
				-DHDF5_BUILD_FORTRAN:BOOL=ON ..


      # --parallel $(nproc): cmake --build with the "Unix Makefiles"
      # generator does NOT pass -j to make by default, so the build
      # was running serially despite a 96-core node. Audit basis:
      # 7950 hdf5 cmake build dominated the 11m50s total.
      cmake --build . --config Release --parallel $(nproc)

      cpack -C Release CPackConfig.cmake

      ./HDF5-${HDF5_VERSION}-Linux.sh --prefix=${HDF5_PATH} --skip-license

      # HDF5_BUILD_DIR (under /tmp) is removed by the EXIT trap
      # above; no need to rm the source clone explicitly.
      cd ../..

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${HDF5_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${HDF5_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${HDF5_PATH}
      fi

   fi

   # Create a module file for hdf5
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
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${HDF5_VERSION}.lua
	whatis("HDF5 Data Model")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prereq("${ROCM_MODULE_NAME}")
	local base = "${HDF5_PATH}/HDF_Group/HDF5/${HDF5_VERSION}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	setenv("HDF5_PATH", base)
	setenv("HDF5_ROOT", base)
	setenv("HDF5_C_COMPILER", "${C_COMPILER}")
	setenv("HDF5_F_COMPILER", "${F_COMPILER}")
	setenv("HDF5_CXX_COMPILER", "${CXX_COMPILER}")
	setenv("HDF5_ENABLE_PARALLEL", "${ENABLE_PARALLEL}")
	setenv("HDF5_MPI_MODULE", "${MPI_MODULE}")
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("PATH", base)
EOF

fi

