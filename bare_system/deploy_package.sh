#!/bin/bash
SELECTION_STRING=""
PACKAGE_BASEDIR=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi


usage()
{
   echo "Usage:"
   echo "  --package-basedir: directory base for package installation"
   echo "  --selection-string: substring to select packages"
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
      "--help")
          usage
          ;;
      "--package-basedir")
          shift
          PACKAGE_BASEDIR_INPUT=${1}
          reset-last
          ;;
      "--selection-string")
          shift
          SELECTION_STRING=${1}
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

# Load the ROCm version for this build
source /etc/profile.d/lmod.sh
module load rocm/${ROCM_VERSION}

if [[ "${PACKAGE_BASEDIR_INPUT}" == "" ]]; then
   PACKAGE_BASEDIR=/opt/rocmplus-${ROCM_VERSION}
else
   PACKAGE_BASEDIR=${PACKAGE_BASEDIR_INPUT}
fi

cd ${PACKAGE_BASEDIR}

for package in `find . -maxdepth 1 -type d `; do
   package=`basename $package`
   if [[ "${package}" =~ "$SELECTION_STRING" ]]; then
      CACHE_DIR=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}
      if [ ! -f "${CACHE_DIR}/${package}.tgz" ]; then
         echo "Packing up $package"
         ${SUDO} tar -czvpf ${CACHE_DIR}/${package}.tgz ${package}
         echo "" > /tmp/InstallLog.txt
         echo "Package $package built on " `date` >> /tmp/InstallLog.txt
         PACKAGE_MD5SUM=`md5sum ${CACHE_DIR}/${package}.tgz`
         echo "MD5SUM: ${PACKAGE_MD5SUM}" >> /tmp/InstallLog.txt
         FILE_COUNT=`find $package -type f | wc -l`
         echo "FILES in $package: $FILE_COUNT" >> /tmp/InstallLog.txt
         PACKAGE_SIZE=`du -skh $package`
         echo "SIZE of $package: $PACKAGE_SIZE" >> /tmp/InstallLog.txt

         cat /tmp/InstallLog.txt
         ${SUDO} cat /tmp/InstallLog.txt >> ${CACHE_DIR}/InstallLog.txt
      else
         echo "${CACHE_DIR}/${package}.tgz already exists"
      fi
   fi
done
