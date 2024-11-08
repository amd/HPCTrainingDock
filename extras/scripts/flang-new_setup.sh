#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/amdflang-new-beta-drop
BUILD_FLANGNEW=0
ROCM_VERSION=6.0
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
ARCHIVE_NAME="rocm-afar-5891-drop-4.0.5"
ARCHIVE_DIR="rocm-afar-5891-0.5"

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --archive-name [ ARCHIVE NAME ] default $ARCHIVE_NAME "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --build-flang-new [ BUILD_FLANGNEW ] default $BUILD_FLANGNEW "
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
      "--build-flang-new")
          shift
          BUILD_FLANGNEW=${1}
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

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

echo ""
echo "========================================="
echo "Starting flang-new Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_FLANGNEW: $BUILD_FLANGNEW"
echo "Searching for archive: $ARCHIVE_NAME.tgz"
echo "In directory: $CACHE_FILES"
echo "========================================="
echo ""

if [ "${BUILD_FLANGNEW}" = "0" ]; then
      echo "flang-new will not be build, according to the specified value of BUILD_FLANGNEW"
      echo "BUILD_FLANGNEW: $BUILD_FLANGNEW"
      exit 
else  
      if [ -f ${CACHE_FILES}/${ARCHIVE_NAME}-${DISTRO}* ]; then
         echo ""
         echo "================================================"
         echo " Archive $ARCHIVE_NAME-${DISTRO} found in $CACHE_FILES"
         echo "         Installing Cached flang-new            "
         echo "================================================"
         echo ""
	
         #install the cached version
	 if [ ! -d "/opt/rocmplus-${ROCM_VERSION}" ]; then
	    ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}
         fi
         cd /opt/rocmplus-${ROCM_VERSION}
     
         ${SUDO} tar -xvjf ${CACHE_FILES}/${ARCHIVE_NAME}-${DISTRO}.tar.bz2
 
         ${SUDO} chown -R root:root /opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}

         if [ "${USER}" != "sysadmin" ]; then
            ${SUDO} rm ${CACHE_FILES}/${ARCHIVE_NAME}-${DISTRO}.tar.bz2
         fi

         # Create a module file for flang-new
         ${SUDO} mkdir -p ${MODULE_PATH}

         cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/4.0.lua
		whatis("AMD AFAR drop #4.0 Beta Fortran OpenMP Compiler based on LLVM")
		local help_message = [[
		   PRE-PRODUCTION SOFTWARE:  The software accessible on this page may be a pre-production version, intended to provide advance access to features that may or may not eventually be included into production version of the software.  Accordingly, pre-production software may not be fully functional, may contain errors, and may have reduced or different security, privacy, accessibility, availability, and reliability standards relative to production versions of the software. Use of pre-production software may result in unexpected results, loss of data, project delays or other unpredictable damage or loss.  Pre-production software is not intended for use in production, and your use of pre-production software is at your own risk.
		]]
		prepend_path("PATH","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/bin")
		setenv("CC","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/bin/amdclang")
		setenv("CXX","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/bin/amdclang++")
		setenv("FC","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/bin/amdflang-new")
		setenv("F77","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/bin/amdflang-new")
		setenv("F90","/opt/rocmplus-${ROCM_VERSION}/${ARCHVE_NAME}/bin/amdflang-new")
		prepend_path("PATH","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/bin")
		prepend_path("LD_LIBRARY_PATH","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/libexec")
		prepend_path("LD_LIBRARY_PATH","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/lib")
		prepend_path("MANPATH","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/share/man")
		prepend_path("C_INCLUDE_PATH","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/include")
		prepend_path("CPLUS_INCLUDE_PATH","/opt/rocmplus-${ROCM_VERSION}/${ARCHIVE_DIR}/include")
		load("rocm/${ROCM_VERSION}")
		family("compiler")
EOF
   else 
         echo " The pre-production flang-new software can currently only be installed from a cached archive"
	 exit
   fi	   

fi
