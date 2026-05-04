#!/bin/bash

# Fail fast on errors (errexit) and surface failures inside pipes
# (pipefail). Without this the audited PnetCDF + netcdf-c failures in
# job 7865 were hidden under rc=0 and the modulefiles were still
# written. Note: NOT using -u (nounset); some conditional code paths
# below intentionally use unset variables.
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
NETCDF_C_MODULE_PATH=/etc/lmod/modules/ROCmPlus/netcdf-c
NETCDF_F_MODULE_PATH=/etc/lmod/modules/ROCmPlus/netcdf-fortran
BUILD_NETCDF=0
ROCM_VERSION=6.2.0
ROCM_MODULE="rocm"
C_COMPILER=gcc
C_COMPILER_INPUT=""
CXX_COMPILER=g++
CXX_COMPILER_INPUT=""
F_COMPILER=gfortran
F_COMPILER_INPUT=""
NETCDF_C_VERSION="4.9.3"
NETCDF_F_VERSION="4.6.2"
HDF5_MODULE="hdf5"
# netcdf depends on hdf5, which itself depends on openmpi. Without
# loading openmpi explicitly here, the only MPI on the build path was
# whatever hdf5's modulefile happened to drag in -- when hdf5 was
# rebuilt against a /nfsapps rocm SDK that exposed mismatched libstdc++,
# netcdf's PnetCDF + netcdf-c configure picked up the wrong toolchain.
# Loading the openmpi module up front fixes that and matches what
# hdf5_setup.sh, hypre_setup.sh, petsc_setup.sh, etc. already do.
MPI_MODULE="openmpi"
# NETCDF_INSTALL_BASE is the rocmplus parent directory under which the
# three netcdf components land at top level so multiple versions can
# coexist:
#   ${NETCDF_INSTALL_BASE}/netcdf-c-v${NETCDF_C_VERSION}
#   ${NETCDF_INSTALL_BASE}/netcdf-fortran-v${NETCDF_F_VERSION}
#   ${NETCDF_INSTALL_BASE}/pnetcdf       (build-time-only dep, unversioned)
NETCDF_INSTALL_BASE=/opt/rocmplus-${ROCM_VERSION}
NETCDF_INSTALL_BASE_INPUT=""
ENABLE_PNETCDF="OFF"
# Per-component --replace flags. netcdf is multi-component (similar in
# spirit to openmpi_setup.sh's --replace-xpmem/--replace-ucx/...), so
# rather than a single coarse --replace we expose one knob per
# top-level install dir under ${NETCDF_INSTALL_BASE}:
#   --replace-netcdf-c   removes netcdf-c-v${NETCDF_C_VERSION} + its .lua
#   --replace-netcdf-f   removes netcdf-fortran-v${NETCDF_F_VERSION} + .lua
#   --replace-pnetcdf    removes the (unversioned) pnetcdf build-only dep
# --replace is kept as a convenience alias that flips ALL three on (and
# is what main_setup.sh threads through from --replace-existing).
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
REPLACE_NETCDF_C=0
REPLACE_NETCDF_F=0
REPLACE_PNETCDF=0
KEEP_FAILED_INSTALLS=0

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_CODENAME=`cat /etc/os-release | grep '^VERSION_CODENAME' | sed -e 's/VERSION_CODENAME=//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path, --netcdf-c-module-path,  and --netcdf-f-module-path the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --rocm-module [ ROCM_MODULE ] default $ROCM_MODULE"
   echo "  --netcdf-c-version [ NETCDF_C_VERSION ] default $NETCDF_C_VERSION"
   echo "  --netcdf-f-version [ NETCDF_F_VERSION ] default $NETCDF_F_VERSION"
   echo "  --netcdf-c-module-path [ NETCDF_C_MODULE_PATH ] default $NETCDF_C_MODULE_PATH"
   echo "  --netcdf-f-module-path [ NETCDF_F_MODULE_PATH ] default $NETCDF_F_MODULE_PATH"
   echo "  --hdf5-module [ HDF5_MODULE ] default $HDF5_MODULE"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --install-path [ NETCDF_INSTALL_BASE ] BASE dir; netcdf-c lands in <base>/netcdf-c-v\$NETCDF_C_VERSION, netcdf-fortran in <base>/netcdf-fortran-v\$NETCDF_F_VERSION, pnetcdf in <base>/pnetcdf; default $NETCDF_INSTALL_BASE"
   echo "  --c-compiler [ C_COMPILER ] default ${C_COMPILER}"
   echo "  --cxx-compiler [ CXX_COMPILER ] default ${CXX_COMPILER}"
   echo "  --f-compiler [ F_COMPILER ] default ${F_COMPILER}"
   echo "  --build-netcdf [ BUILD_NETCDF ], set to 1 to build netcdf-c and netcdf-fortran, default is 0"
   echo "  --replace [ 0|1 ] convenience: same as --replace-netcdf-c 1 --replace-netcdf-f 1 --replace-pnetcdf 1, default $REPLACE"
   echo "  --replace-netcdf-c [ 0|1 ] remove prior netcdf-c install + modulefile before building, default $REPLACE_NETCDF_C"
   echo "  --replace-netcdf-f [ 0|1 ] remove prior netcdf-fortran install + modulefile before building, default $REPLACE_NETCDF_F"
   echo "  --replace-pnetcdf  [ 0|1 ] remove prior pnetcdf install before building, default $REPLACE_PNETCDF"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial installs on failure, default $KEEP_FAILED_INSTALLS"
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
      "--build-netcdf")
          shift
          BUILD_NETCDF=${1}
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
      "--netcdf-c-module-path")
          shift
          NETCDF_C_MODULE_PATH=${1}
          reset-last
          ;;
      "--netcdf-f-module-path")
          shift
          NETCDF_F_MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          NETCDF_INSTALL_BASE_INPUT=${1}
          reset-last
          ;;
      "--hdf5-module")
          shift
          HDF5_MODULE=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
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
      "--netcdf-c-version")
          shift
          NETCDF_C_VERSION=${1}
          reset-last
          ;;
      "--netcdf-f-version")
          shift
          NETCDF_F_VERSION=${1}
          reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
          reset-last
          ;;
      "--replace-netcdf-c")
          shift
          REPLACE_NETCDF_C=${1}
          reset-last
          ;;
      "--replace-netcdf-f")
          shift
          REPLACE_NETCDF_F=${1}
          reset-last
          ;;
      "--replace-pnetcdf")
          shift
          REPLACE_PNETCDF=${1}
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

if [ "${NETCDF_INSTALL_BASE_INPUT}" != "" ]; then
   NETCDF_INSTALL_BASE=${NETCDF_INSTALL_BASE_INPUT}
else
   # override base in case ROCM_VERSION has been supplied as input
   NETCDF_INSTALL_BASE=/opt/rocmplus-${ROCM_VERSION}
fi
# Strip a trailing "/netcdf" for backward compatibility with callers
# (e.g. older main_setup.sh) that pre-appended the leaf dir.
NETCDF_INSTALL_BASE=${NETCDF_INSTALL_BASE%/}
NETCDF_INSTALL_BASE=${NETCDF_INSTALL_BASE%/netcdf}

NETCDF_C_PATH=${NETCDF_INSTALL_BASE}/netcdf-c-v${NETCDF_C_VERSION}
NETCDF_F_PATH=${NETCDF_INSTALL_BASE}/netcdf-fortran-v${NETCDF_F_VERSION}
PNETCDF_PATH=${NETCDF_INSTALL_BASE}/pnetcdf

# ── BUILD_NETCDF=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_NETCDF}" = "0" ]; then
   echo "[netcdf BUILD_NETCDF=0] operator opt-out; skipping (no source build, no cache restore for any of netcdf-c, netcdf-fortran, pnetcdf)."
   exit ${NOOP_RC}
fi

# ── --replace: remove prior installs + modulefiles BEFORE building ────
# --replace 1 acts as a convenience alias that flips all three
# component knobs on. Individual --replace-netcdf-{c,f}/--replace-pnetcdf
# flags still win if the operator wants finer-grained control.
if [ "${REPLACE}" = "1" ]; then
   REPLACE_NETCDF_C=1
   REPLACE_NETCDF_F=1
   REPLACE_PNETCDF=1
fi
if [ "${REPLACE_NETCDF_C}" = "1" ]; then
   echo "[netcdf --replace-netcdf-c 1] removing prior netcdf-c install + modulefile if present"
   echo "  install dir: ${NETCDF_C_PATH}"
   echo "  modulefile:  ${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}.lua"
   ${SUDO} rm -rf "${NETCDF_C_PATH}"
   ${SUDO} rm -f  "${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}.lua"
fi
if [ "${REPLACE_NETCDF_F}" = "1" ]; then
   echo "[netcdf --replace-netcdf-f 1] removing prior netcdf-fortran install + modulefile if present"
   echo "  install dir: ${NETCDF_F_PATH}"
   echo "  modulefile:  ${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}.lua"
   ${SUDO} rm -rf "${NETCDF_F_PATH}"
   ${SUDO} rm -f  "${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}.lua"
fi
if [ "${REPLACE_PNETCDF}" = "1" ]; then
   echo "[netcdf --replace-pnetcdf 1] removing prior pnetcdf install"
   echo "  install dir: ${PNETCDF_PATH}"
   ${SUDO} rm -rf "${PNETCDF_PATH}"
fi

# ── Existence guard (see hypre_setup.sh) ─────────────────────────────
# Multi-component: skip ONLY if all three components (netcdf-c-v${VER},
# netcdf-fortran-v${VER}, pnetcdf) are already on disk. If any one is
# missing we proceed -- the per-component build branches below
# short-circuit on the components that are already present. This is
# more correct than the old main_setup.sh `[[ ! -d netcdf-c-v${VER} ]]`
# guard, which could leave netcdf-fortran or pnetcdf permanently
# unbuilt if netcdf-c happened to land first.
NOOP_RC=43
if [ -d "${NETCDF_C_PATH}" ] && [ -d "${NETCDF_F_PATH}" ] && [ -d "${PNETCDF_PATH}" ]; then
   echo ""
   echo "[netcdf existence-check] all three components already installed; skipping."
   echo "  netcdf-c:       ${NETCDF_C_PATH}"
   echo "  netcdf-fortran: ${NETCDF_F_PATH}"
   echo "  pnetcdf:        ${PNETCDF_PATH}"
   echo "  pass --replace 1 (or per-component --replace-netcdf-{c,f}/--replace-pnetcdf) to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of all three components ──────────────────
# On non-zero exit, remove any partial install + modulefile this script
# may have written for ANY of the three components, since we don't know
# in advance which one was in flight. Replaces main_setup.sh
# PKG_CLEAN_*[netcdf]/[netcdf-fortran]/[pnetcdf]. Skipped when
# --keep-failed-installs 1.
_netcdf_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[netcdf fail-cleanup] rc=${rc}: removing partial netcdf-c/netcdf-fortran/pnetcdf installs + modulefiles"
      ${SUDO:-sudo} rm -rf "${NETCDF_C_PATH}" "${NETCDF_F_PATH}" "${PNETCDF_PATH}"
      ${SUDO:-sudo} rm -f  "${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}.lua" \
                           "${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[netcdf fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _netcdf_on_exit EXIT

if [ "${BUILD_NETCDF}" = "0" ]; then

   echo "NETCDF will not be built, according to the specified value of BUILD_NETCDF"
   echo "BUILD_NETCDF: $BUILD_NETCDF"
   echo "Make sure to set '--build-netcdf 1' when running this install script"
   exit

else

   echo ""
   echo "==============================================="
   echo " Installing NETCDF"
   echo " Install base directory: $NETCDF_INSTALL_BASE"
   echo " Netcdf-c Version: $NETCDF_C_VERSION"
   echo " Netcdf-c Install Directory: $NETCDF_C_PATH"
   echo " Netcdf-c Module Directory: $NETCDF_C_MODULE_PATH"
   echo " Netcdf-fortran Version: $NETCDF_F_VERSION"
   echo " Netcdf-fortran Install Directory: $NETCDF_F_PATH"
   echo " Netcdf-fortran Module Directory: $NETCDF_F_MODULE_PATH"
   echo " PnetCDF Install Directory: $PNETCDF_PATH"
   echo " ROCm Version: $ROCM_VERSION"
   echo "==============================================="
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

   NETCDF_C_TGZ=${CACHE_FILES}/netcdf-c-v${NETCDF_C_VERSION}.tgz
   NETCDF_F_TGZ=${CACHE_FILES}/netcdf-fortran-v${NETCDF_F_VERSION}.tgz
   PNETCDF_TGZ=${CACHE_FILES}/pnetcdf.tgz
   if [ -f ${NETCDF_C_TGZ} ] && [ -f ${NETCDF_F_TGZ} ]; then
      echo ""
      echo "============================"
      echo " Installing Cached NETCDF"
      echo "============================"
      echo ""

      # Install the cached version. Each cache tar must contain a single
      # top-level directory matching its install path so it lands directly
      # under ${NETCDF_INSTALL_BASE} when extracted there:
      #   netcdf-c-v${NETCDF_C_VERSION}.tgz       -> netcdf-c-v.../
      #   netcdf-fortran-v${NETCDF_F_VERSION}.tgz -> netcdf-fortran-v.../
      #   pnetcdf.tgz (optional, build-time-only) -> pnetcdf/
      # PnetCDF is shared across netcdf versions (like PDT for scorep),
      # hence unversioned; only present when the cache build had
      # HDF5_ENABLE_PARALLEL=ON.
      cd ${NETCDF_INSTALL_BASE}
      tar -xzf ${NETCDF_C_TGZ}
      tar -xzf ${NETCDF_F_TGZ}
      chown -R root:root ${NETCDF_C_PATH} ${NETCDF_F_PATH}
      if [ -f ${PNETCDF_TGZ} ]; then
         tar -xzf ${PNETCDF_TGZ}
         chown -R root:root ${PNETCDF_PATH}
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${NETCDF_C_TGZ} ${NETCDF_F_TGZ} ${PNETCDF_TGZ}
      fi

   else
      echo ""
      echo "================================"
      echo " Installing NETCDF from source"
      echo "================================"
      echo ""

      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh

      # don't use sudo if user has write access to install base
      if [ -d "$NETCDF_INSTALL_BASE" ]; then
         # don't use sudo if user has write access to install base
         if [ -w ${NETCDF_INSTALL_BASE} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      # install libcurl. PKG_SUDO: apt/yum need root regardless of the
      # install-path-derived SUDO. The previous `[[ ${SUDO} == "" ]]`
      # guards skipped libcurl whenever the install path was
      # admin-writable, which would silently produce a netcdf without
      # curl support. See openmpi_setup.sh / audit_2026_05_01.md Issue 2.
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
      if [ "${DISTRO}" = "ubuntu" ]; then
         echo "...installing libcurl..."
         ${PKG_SUDO} apt-get update
         ${PKG_SUDO} apt-get install -y libcurl4-gnutls-dev
      elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
         echo "...installing libcurl..."
         ${PKG_SUDO} yum install -y libcurl-devel
      elif [ "${DISTRO}" = "opensuse" ]; then
	 echo "opensuse is not tested yet, not installing libcurl"
      fi

      ${SUDO} mkdir -p ${NETCDF_C_PATH}
      ${SUDO} mkdir -p ${NETCDF_F_PATH}
      ${SUDO} mkdir -p ${PNETCDF_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${NETCDF_C_PATH} ${NETCDF_F_PATH} ${PNETCDF_PATH}
      fi

      # Order matters: ROCm first (extends MODULEPATH with rocmplus-<v>
      # so MPI / HDF5 / etc. are findable), then MPI before HDF5 so
      # mpicc / mpifort and openmpi's runtime libs are first on
      # PATH / LD_LIBRARY_PATH (otherwise the hdf5 module's MPI hints
      # can be inconsistent with what PnetCDF / netcdf-c pick up via
      # `which mpicc`).
      REQUIRED_MODULES=( "${ROCM_MODULE}/${ROCM_VERSION}" "${MPI_MODULE}" "${HDF5_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?
      if [[ `which h5dump | wc -l` -eq 0 ]]; then
         echo "h5dump was not found in PATH after loading the hdf5 module"
         echo "hdf5 is a requirement for netcdf, please make sure hdf5"
         echo "is installed and present in PATH, then retry"
         exit
      else
         C_COMPILER=$HDF5_C_COMPILER
         CXX_COMPILER=$HDF5_CXX_COMPILER
         F_COMPILER=$HDF5_F_COMPILER
      fi

      # override flags with user defined values if present
      if [ "${C_COMPILER_INPUT}" != "" ]; then
         C_COMPILER=${C_COMPILER_INPUT}
      fi
      if [ "${CXX_COMPILER_INPUT}" != "" ]; then
         CXX_COMPILER=${CXX_COMPILER_INPUT}
      fi
      if [ "${F_COMPILER_INPUT}" != "" ]; then
         F_COMPILER=${F_COMPILER_INPUT}
      fi

      # Use all available cores for the netcdf builds. Without -j, each of
      # pnetcdf, netcdf-c, netcdf-fortran ran serially on one core (~10min
      # combined on sh5); with -j$(nproc) it drops to a couple of minutes.
      MAKE_JOBS=$(nproc 2>/dev/null || echo 16)

      # Build all three sources (PnetCDF, netcdf-c, netcdf-fortran) under
      # a fresh /tmp dir so failed builds don't leave a PnetCDF/,
      # netcdf-c/, or netcdf-fortran/ tree polluting the HPCTrainingDock
      # checkout. Audited as the netcdf rc=128 cause in
      # slurm-7950-rocmplus-7.0.2.out (log_netcdf line 36):
      #   "fatal: destination path 'PnetCDF' already exists"
      # came from a leftover PnetCDF/ in the repo root from a prior
      # aborted run; git clone refused to overwrite. Mirrors the scorep
      # S6.C / openmpi S7.B / kokkos /tmp-build patterns. EXIT trap
      # guarantees cleanup even on `set -e` aborts.
      NETCDF_BUILD_DIR=$(mktemp -d -t netcdf-build.XXXXXX)
      trap '[ -n "${NETCDF_BUILD_DIR:-}" ] && rm -rf "${NETCDF_BUILD_DIR}"' EXIT
      cd "${NETCDF_BUILD_DIR}"

      if [ "${HDF5_ENABLE_PARALLEL}" = "ON" ]; then
         ENABLE_PNETCDF="ON"
         # HDF5_MPI_MODULE was historically referenced here but never set
         # by main_setup.sh -- a latent no-op. The MPI_MODULE load above
         # is what was actually wanted. Keep the conditional load only if
         # an explicit override is provided (defensive).
         if [ -n "${HDF5_MPI_MODULE:-}" ]; then
            module load "${HDF5_MPI_MODULE}"
         fi
         # install pnetcdf
         git clone --branch checkpoint.1.14.0 https://github.com/Parallel-NetCDF/PnetCDF.git
         cd PnetCDF
         autoreconf -i

         # ---------------------------------------------------------------------
         # PnetCDF Fortran-runtime fix (audit_2026_05_01.md Issue 4):
         #
         # MPIF90 wraps amdflang (per the openmpi build), so PnetCDF's *.f90
         # objects emit references to LLVM-flang runtime symbols
         # (Fortran::runtime::*, _FortranA*).  libtool then drives the final
         # link of libpnetcdf.so with gcc, which does NOT auto-link flang's
         # runtime, leaving those symbols UNDEFINED in libpnetcdf.so.  When
         # netcdf-c later links ncdump/ncgen against -lpnetcdf, the runtime
         # symbols cannot be resolved (collect2: ld returned 1) and the whole
         # netcdf install aborts.  Verified failing log:
         #   logs_04_30_2026/rocm-7.0.2_7957/log_netcdf_04_30_2026.txt
         # vs. passing log:
         #   logs_05_01_2026/rocm-7.2.1_7959/log_netcdf_05_01_2026.txt
         #
         # Fix: discover the amdflang runtime archive(s) and pass them via LIBS
         # so libtool/ld bakes the symbols into libpnetcdf.so itself.  ROCm
         # relocated the runtime between 7.0.x and 7.2.x:
         #   * 7.0.x / 7.1.x : ${ROCM_PATH}/llvm/lib/libFortranRuntime.a
         #                     ${ROCM_PATH}/llvm/lib/libFortranDecimal.a
         #   * 7.2.x+        : ${ROCM_PATH}/lib/llvm/lib/clang/<ver>/lib/<triple>/libflang_rt.runtime.a
         # ---------------------------------------------------------------------
         PNETCDF_FORTRAN_LIBS=""
         if [ -n "${ROCM_PATH:-}" ]; then
            # 7.2.x+ : single combined runtime archive in clang resource dir
            for f in "${ROCM_PATH}"/lib/llvm/lib/clang/*/lib/*/libflang_rt.runtime.a \
                     "${ROCM_PATH}"/llvm/lib/clang/*/lib/*/libflang_rt.runtime.a; do
               if [ -f "${f}" ]; then
                  PNETCDF_FORTRAN_LIBS="${f}"
                  break
               fi
            done
            # 7.0.x / 7.1.x : split FortranRuntime + FortranDecimal archives
            if [ -z "${PNETCDF_FORTRAN_LIBS}" ] && [ -f "${ROCM_PATH}/llvm/lib/libFortranRuntime.a" ]; then
               PNETCDF_FORTRAN_LIBS="${ROCM_PATH}/llvm/lib/libFortranRuntime.a"
               if [ -f "${ROCM_PATH}/llvm/lib/libFortranDecimal.a" ]; then
                  PNETCDF_FORTRAN_LIBS="${PNETCDF_FORTRAN_LIBS} ${ROCM_PATH}/llvm/lib/libFortranDecimal.a"
               fi
            fi
         fi
         if [ -n "${PNETCDF_FORTRAN_LIBS}" ]; then
            echo "PnetCDF: linking amdflang Fortran runtime: ${PNETCDF_FORTRAN_LIBS}"
            ./configure --prefix=${PNETCDF_PATH} MPICC=`which mpicc` MPIF90=`which mpifort` \
                        LIBS="${PNETCDF_FORTRAN_LIBS}"
         else
            echo "WARNING: could not locate amdflang Fortran runtime under ROCM_PATH=${ROCM_PATH:-<unset>};"
            echo "         libpnetcdf.so may have unresolved Fortran::runtime::* / _FortranA* symbols"
            echo "         and the subsequent netcdf-c utility link will fail."
            ./configure --prefix=${PNETCDF_PATH} MPICC=`which mpicc` MPIF90=`which mpifort`
         fi
         make -j ${MAKE_JOBS}
         make install
         cd ..
      fi

      echo ""
      echo "================================="
      echo " Installing NETCDF-C"
      echo "================================="
      echo ""

      git clone --branch v${NETCDF_C_VERSION} https://github.com/Unidata/netcdf-c.git
      cd netcdf-c
      sed -i 's/if\ (H5FD_HTTP_g)/if\ (H5FD_HTTP_g\ \&\&\ (H5Iis_valid(H5FD_HTTP_g)\ >\ 0))/g' libhdf5/H5FDhttp.c
      mkdir build && cd build

      cmake -DCMAKE_INSTALL_PREFIX=${NETCDF_C_PATH} \
	    -DNETCDF_ENABLE_HDF5=ON -DNETCDF_ENABLE_DAP=ON \
	    -DNETCDF_BUILD_UTILITIES=ON -DNETCDF_ENABLE_CDF5=ON \
	    -DNETCDF_ENABLE_TESTS=OFF -DNETCDF_ENABLE_PARALLEL_TESTS=OFF \
	    -DZLIB_INCLUDE_DIR=${HDF5_ROOT}/zlib/include \
	    -DCMAKE_C_FLAGS="-I ${HDF5_ROOT}/include/" \
	    -DCMAKE_C_COMPILER=${C_COMPILER} \
	    -DNETCDF_ENABLE_PNETCDF=${ENABLE_PNETCDF} \
	    -DPNETCDF_LIBRARY=${PNETCDF_PATH}/lib/libpnetcdf.so \
	    -DPNETCDF_INCLUDE_DIR=${PNETCDF_PATH}/include \
	    -DNETCDF_ENABLE_FILTER_SZIP=OFF -DNETCDF_ENABLE_NCZARR=OFF ..

      cmake --build . -j ${MAKE_JOBS}
      make install

      cd ../..

      # put netcdf-c install path in PATH for netcdf-fortran install
      export PATH=${NETCDF_C_PATH}:$PATH
      export HDF5_PLUGIN_PATH=${NETCDF_C_PATH}/hdf5/lib/plugin/

      git clone --branch v${NETCDF_F_VERSION} https://github.com/Unidata/netcdf-fortran.git
      cd netcdf-fortran

      # netcdf-fortran is looking for nc_def_var_szip even if SZIP is OFF
      LINE=`sed -n '/if (NOT HAVE_DEF_VAR_SZIP)/=' CMakeLists.txt | grep -n ""`
      LINE=`echo ${LINE} | cut -c 3-`
      sed -i ''"${LINE}"'i set(HAVE_DEF_VAR_SZIP TRUE)' CMakeLists.txt

      mkdir build && cd build
      cmake -DCMAKE_INSTALL_PREFIX=${NETCDF_F_PATH} \
	    -DENABLE_TESTS=OFF -DBUILD_EXAMPLES=OFF \
	    -DCMAKE_Fortran_COMPILER=$F_COMPILER ..

      cmake --build . -j ${MAKE_JOBS}
      make install

      cd ../..
      rm -rf netcdf-c
      rm -rf netcdf-fortran
      ${SUDO} rm -rf PnetCDF

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         for D in ${NETCDF_C_PATH} ${NETCDF_F_PATH} ${PNETCDF_PATH}; do
            ${SUDO} find ${D} -type f -execdir chown root:root "{}" +
            ${SUDO} find ${D} -type d -execdir chown root:root "{}" +
         done
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${NETCDF_C_PATH} ${NETCDF_F_PATH} ${PNETCDF_PATH}
      fi

   fi

   # Sanity gate: only write modulefiles if the install actually produced
   # the expected libraries. Catches the silent-failure case where
   # PnetCDF / netcdf-c failed mid-build (audit P1 in 7865) but the
   # script still went on to publish broken modulefiles.
   for lib in \
      "${NETCDF_C_PATH}/lib/libnetcdf.so" \
      "${NETCDF_F_PATH}/lib/libnetcdff.so"; do
      if ! { [ -f "${lib}" ] || [ -f "${lib}.0" ] || [ -L "${lib}" ]; }; then
         echo "ERROR: expected netcdf library not found: ${lib}" >&2
         echo "       Refusing to write netcdf-c / netcdf-fortran modulefiles." >&2
         exit 1
      fi
   done
   if [ "${ENABLE_PNETCDF}" = "ON" ] && [ ! -f "${PNETCDF_PATH}/lib/libpnetcdf.so" ] \
        && [ ! -f "${PNETCDF_PATH}/lib/libpnetcdf.a" ]; then
      echo "ERROR: PnetCDF was requested (HDF5_ENABLE_PARALLEL=ON) but" >&2
      echo "       ${PNETCDF_PATH}/lib/libpnetcdf.{so,a} is missing." >&2
      echo "       Refusing to write netcdf-c / netcdf-fortran modulefiles." >&2
      exit 1
   fi

   # Create a module file for netcdf-c
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit).
   # The previous "if [ -d ] / if [ ! -w ] / else / SUDO=sudo / else
   # / SUDO=sudo / echo / fi" block was a known-broken probe: in 8063
   # the netcdf-c module dir was owned root:root mode 755, [ ! -w ]
   # at probe time evaluated FALSE (printed "user has write access
   # to netcdf-c module path"), then `tee` returned EACCES, and the
   # whole script exited rc=1 -- failing AFTER a successful library
   # build, the worst possible failure mode. Replaced with the same
   # PKG_SUDO computation used at install-time elsewhere in this
   # script (line 435): one source of truth, no probes that lie.
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${NETCDF_C_MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}.lua
	whatis("Netcdf-c Library")

        load("hdf5")
        local base = "${NETCDF_C_PATH}"
        local base_pnetcdf = "${PNETCDF_PATH}"
        prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
        prepend_path("LD_LIBRARY_PATH", pathJoin(base_pnetcdf, "lib"))
        prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("PATH", pathJoin(base, "bin"))
        prepend_path("PATH", base)
        prepend_path("PATH", pathJoin(base_pnetcdf, "bin"))
	setenv("NETCDF_C_ROOT", base)
	setenv("PNETCDF_ROOT", base_pnetcdf)
EOF

   # Create a module file for netcdf-fortran
   # See netcdf-c block above for the rationale on PKG_SUDO_MOD; the
   # netcdf-fortran modulefile dir is a sibling of netcdf-c's and
   # has the exact same lying-probe failure mode. Reusing the same
   # PKG_SUDO_MOD value computed for netcdf-c (computed once per
   # process, no race window).
   ${PKG_SUDO_MOD} mkdir -p ${NETCDF_F_MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}.lua
	whatis("Netcdf-fortran Library")

	load("netcdf-c")
	local base = "${NETCDF_F_PATH}"
	local base_pnetcdf = "${PNETCDF_PATH}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base_pnetcdf, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("PATH", base)
	prepend_path("PATH", pathJoin(base_pnetcdf, "bin"))
	setenv("NETCDF_F_ROOT", base)
	setenv("PNETCDF_ROOT", base_pnetcdf)
EOF

fi

