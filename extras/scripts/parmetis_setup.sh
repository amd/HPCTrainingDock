#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/LinuxPlus/parmetis
BUILD_PARMETIS=1
ROCM_VERSION=6.4.0
PARMETIS_VERSION="3.14"
INSTALL_PATH=/opt/parmetis-v${PARMETIS_VERSION}
INSTALL_PATH_INPUT=""
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
MPI_MODULE="openmpi"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  WARNING: when selecting the module to supply to --mpi-module, make sure it sets the MPI_PATH environment variable"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --install-path [ INSTALL_PATH_INPUT ] default $INSTALL_PATH"
   echo "  --parmetis_version [ PARMETIS_VERSION ] default $PARMETIS_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-parmetis [ BUILD_PARMETIS ] default is 0"
   echo "  --help: this usage information"
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
      "--build-parmetis")
          shift
          BUILD_PARMETIS=${1}
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
      "--parmetis-version")
          shift
          PARMETIS_VERSION=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
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

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case PARMETIS_VERSION has been supplied as input
   INSTALL_PATH=/opt/parmetis-v${PARMETIS_VERSION}
fi

echo ""
echo "==================================="
echo "Starting PARMETIS Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_PARMETIS: $BUILD_PARMETIS"
echo "Installing PARMETIS in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "PARMETIS_VERSION: $PARMETIS_VERSION"
echo "MPI_MODULE: $MPI_MODULE"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_PARMETIS}" = "0" ]; then

   echo "PARMETIS will not be built, according to the specified value of BUILD_PARMETIS"
   echo "BUILD_PARMETIS: $BUILD_PARMETIS"
   exit

else
   if [ -f ${CACHE_FILES}/parmetis.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached PARMETIS"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xpzf ${CACHE_FILES}/parmetis.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/parmetis.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building PARMETIS"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh
      module load gcc
      module load $MPI_MODULE
      if [[ $MPI_PATH == "" ]]; then
         echo "MPI module $MPI_MODULE is not setting the MPI_PATH env variable, aborting..."
         exit 1
      fi

      ${SUDO} rm -rf parmetis
      ${SUDO} rm -rf $INSTALL_PATH
      #cp gklib_force_fpic.patch .

      mkdir parmetis
      cd parmetis

      # Two-line build/install pattern: build as user (no sudo) so the
      # compiler emits user-owned .o/.a in the build dir, then sudo only
      # the install step (file copies into ${INSTALL_PATH}).  The previous
      # `${SUDO} make install -j16` form ran the implicit parallel BUILD
      # under root, leaving root-owned object files in
      # ${PWD}/parmetis/{gklib,metis,parmetis}/ that the non-sudo
      # `rm -rf gklib metis parmetis` below could not clean up.
      git clone https://github.com/KarypisLab/GKlib.git gklib
      cd gklib
      git checkout 8bd6bad750b2b0d908
      git apply ../../gklib_force_fpic.patch
      make config cc=${CC} prefix=$INSTALL_PATH
      make -j16
      ${SUDO} make install
      cd ..

      git clone https://github.com/KarypisLab/METIS.git metis
      cd metis
      make config shared=1 cc=${CC} prefix=$INSTALL_PATH gklib_path=$INSTALL_PATH i64=1
      make -j16
      ${SUDO} make install
      cd ..

      export CC=$MPI_PATH/bin/mpicc
      git clone https://github.com/KarypisLab/ParMETIS.git parmetis
      cd parmetis
      make config shared=1 cc=${CC} prefix=$INSTALL_PATH gklib_path=$INSTALL_PATH metis_path=$INSTALL_PATH
      make -j16
      ${SUDO} make install
      cd ..

      cd ..
      rm -rf gklib metis parmetis
      rm -f gklib_force_fpic.patch

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi
   fi

   # Create a module file for fftw
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
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${PARMETIS_VERSION}.lua
        whatis("PARMETIS package")
        whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

        local base = "${INSTALL_PATH}"

        setenv("PARMETIS", base)
        setenv("PARMETIS_PATH", base)
        setenv("PARMETIS_DIR", base)
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
EOF

fi
