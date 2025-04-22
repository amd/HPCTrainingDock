#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/amdflang-new
BUILD_FLANGNEW=0
ROCM_VERSION=6.0
UNTAR_DIR=/opt/rocmplus-${ROCM_VERSION}
UNTAR_DIR_INPUT=""
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_SHORT=$DISTRO
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
ARCHIVE_NAME="rocm-afar-7450-drop-6.0.0"
ARCHIVE_DIR="rocm-afar-6.0.0"

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --install-path [ UNTAR_DIR_INPUT ] default $UNTAR_DIR "
   echo "  --archive-name [ ARCHIVE NAME ] default $ARCHIVE_NAME "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --build-flang-new [ BUILD_FLANGNEW ] default $BUILD_FLANGNEW "
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
      "--build-flang-new")
          shift
          BUILD_FLANGNEW=${1}
          reset-last
          ;;
      "--install-path")
          shift
          UNTAR_DIR_INPUT=${1}
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
      "--archive-name")
          shift
          ARCHIVE_NAME=${1}
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

if [ "${UNTAR_DIR_INPUT}" != "" ]; then
   UNTAR_DIR=${UNTAR_DIR_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   UNTAR_DIR=/opt/rocmplus-${ROCM_VERSION}
fi

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

echo ""
echo "========================================="
echo "Starting flang-new Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_FLANGNEW: $BUILD_FLANGNEW"
echo "Archive will be untarred in: $UNTAR_DIR"
echo "========================================="
echo ""

if [ "${BUILD_FLANGNEW}" = "0" ]; then
      echo "flang-new will not be build, according to the specified value of BUILD_FLANGNEW"
      echo "BUILD_FLANGNEW: $BUILD_FLANGNEW"
      exit
else
      echo ""
      echo "================================================"
      echo "         Installing flang-new                   "
      echo "================================================"
      echo ""

      if [ -d "$UNTAR_DIR" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${UNTAR_DIR} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

       ${SUDO} mkdir -p ${UNTAR_DIR}
      cd ${UNTAR_DIR}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${UNTAR_DIR}
      fi

      if [[ ${DISTRO} == "ubuntu" ]]; then
         if [[ ${ARCHIVE_NAME} == "rocm-afar-7450-drop-6.0.0" ]]; then
            DISTRO_SHORT="ubu"
         fi
      fi

      wget -q https://repo.radeon.com/rocm/misc/flang/${ARCHIVE_NAME}-${DISTRO_SHORT}.tar.bz2
      tar -xjf ${ARCHIVE_NAME}-${DISTRO_SHORT}.tar.bz2
      rm -f ${ARCHIVE_NAME}-${DISTRO_SHORT}.tar.bz2

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chown -R root:root ${UNTAR_DIR}/${ARCHIVE_DIR}
         ${SUDO} chmod go-w ${UNTAR_DIR}
      fi

      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/${ARCHIVE_NAME}-${DISTRO_SHORT}.tar.bz2
      fi

      # Create a module file for flang-new
      if [ -d "$MODULE_PATH" ]; then
         # use sudo if user does not have write access to module path
         if [ ! -w ${MODULE_PATH} ]; then
            SUDO="sudo"
         else
            echo "WARNING: not using sudo since user has write access to module path"
         fi
      else
         # if module path dir does not exist yet, the check on write access will fail
         SUDO="sudo"
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${MODULE_PATH}

      # - on next line suppresses tab in the following lines
      cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ARCHIVE_DIR}.lua
	whatis("AMD AFAR drop #4.0 Beta Fortran OpenMP Compiler based on LLVM")
	local help_message = [[
	   PRE-PRODUCTION SOFTWARE:  The software accessible on this page may be a pre-production version, intended to provide advance access to features that may or may not eventually be included into production version of the software.  Accordingly, pre-production software may not be fully functional, may contain errors, and may have reduced or different security, privacy, accessibility, availability, and reliability standards relative to production versions of the software. Use of pre-production software may result in unexpected results, loss of data, project delays or other unpredictable damage or loss.  Pre-production software is not intended for use in production, and your use of pre-production software is at your own risk.
	]]
	load("rocm/${ROCM_VERSION}")
	setenv("CC","${UNTAR_DIR}/${ARCHIVE_DIR}/bin/amdclang")
	setenv("CXX","${UNTAR_DIR}/${ARCHIVE_DIR}/bin/amdclang++")
	setenv("FC","${UNTAR_DIR}/${ARCHIVE_DIR}/bin/amdflang-new")
	setenv("OMPI_CC","${UNTAR_DIR}/${ARCHIVE_DIR}/bin/amdclang")
	setenv("OMPI_CXX","${UNTAR_DIR}/${ARCHIVE_DIR}/bin/amdclang++")
	setenv("OMPI_FC","${UNTAR_DIR}/${ARCHIVE_DIR}/bin/amdflang-new")
	setenv("F77","${UNTAR_DIR}/${ARCHIVE_DIR}/bin/amdflang-new")
	setenv("F90","${UNTAR_DIR}/${ARCHIVE_DIR}/bin/amdflang-new")
	prepend_path("PATH","${UNTAR_DIR}/${ARCHIVE_DIR}/bin")
	prepend_path("LD_LIBRARY_PATH","${UNTAR_DIR}/${ARCHIVE_DIR}/libexec")
	prepend_path("LD_LIBRARY_PATH","${UNTAR_DIR}/${ARCHIVE_DIR}/lib")
	prepend_path("MANPATH","${UNTAR_DIR}/${ARCHIVE_DIR}/share/man")
	prepend_path("C_INCLUDE_PATH","${UNTAR_DIR}/${ARCHIVE_DIR}/include")
	prepend_path("CPLUS_INCLUDE_PATH","${UNTAR_DIR}/${ARCHIVE_DIR}/include")
	family("compiler")
EOF

fi
