#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"
if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
    echo "Usage:"
    echo "  --admin-user [ ADMIN_USER ] default autodetected"
    echo "  --amdgpu-gfxmodel-string [ AMDGPU_GFXMODEL_STRING ]"
    echo "  --identity-file [ IDENTITY_FILE ]"
    echo "  --port-number [ PORT_NUMBER ]"
    echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
      "--admin-user")
         shift
         ADMIN_USER=${1}
         reset-last
         ;;
      "--amdgpu-gfxmodel-string")
         shift
         AMDGPU_GFXMODEL_STRING=${1}
         reset-last
         ;;
      "--distro")
         shift
         DISTRO=${1}
         reset-last
         ;;
      "--distro-version")
         shift
         DISTRO_VERSION=${1}
         reset-last
         ;;
      "--identity-file")
          shift
          IDENTITY_FILE=${1}
          reset-last
          ;;
      "--port-number")
          shift
          PORT_NUMBER=${1}
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

if [ "${IDENTITY_FILE}" != "" ]; then
   IDENTITY_FILE="-i ${IDENTITY_FILE}"
fi

ssh-copy-id ${IDENTITY_FILE} -p ${PORT_NUMBER} -o UpdateHostKeys=yes ${ADMIN_USER}@localhost

PACKAGE_LIST=`ssh -p ${PORT_NUMBER} ${IDENTITY_FILE} ${ADMIN_USER}@localhost -t "ls /opt/rocmplus-${ROCM_VERSION}"`
# Remove trailing line break
PACKAGE_LIST=`echo ${PACKAGE_LIST} | tr -d '\r'`
echo "local rocmplus package.list"
echo ":${PACKAGE_LIST}:"

app=rocm-${ROCM_VERSION}
if [ ! -f "HPCTrainingDock/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}/${app}.tgz" ]; then
   PACKAGE_SIZE=`ssh -p ${PORT_NUMBER} ${IDENTITY_FILE} ${ADMIN_USER}@localhost -t "du -sk /opt/${app} | cut -f1 | tr -d $'\n'" `
   echo "Package size for ${app} is ${PACKAGE_SIZE}"
   if [ "${PACKAGE_SIZE}" -gt "100" ]; then
      echo "Retrieving ${app}"
      ssh -p ${PORT_NUMBER} ${IDENTITY_FILE} ${ADMIN_USER}@localhost -t "cd /opt && tar -czpf /users/${ADMIN_USER}/${app}.tgz ${app}"
      rsync -avz -e "ssh -p ${PORT_NUMBER} ${IDENTITY_FILE}"  ${ADMIN_USER}@localhost:${app}.tgz HPCTrainingDock/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}/${app}.tgz
   fi
fi

for app in ${PACKAGE_LIST}
do
   if [ ! -f "HPCTrainingDock/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}/${app}.tgz" ]; then
      PACKAGE_SIZE=`ssh -p ${PORT_NUMBER} ${IDENTITY_FILE} ${ADMIN_USER}@localhost -t "du -sk /opt/rocmplus-${ROCM_VERSION}/${app} | cut -f1 | tr -d $'\n'" `
      echo "Package size for ${app} is ${PACKAGE_SIZE}"
      if [ "${PACKAGE_SIZE}" -gt "100" ]; then
         echo "Retrieving ${app}"
         ssh -p ${PORT_NUMBER} ${IDENTITY_FILE} ${ADMIN_USER}@localhost -t "cd /opt/rocmplus-${ROCM_VERSION} && tar -czf /users/${ADMIN_USER}/${app}.tgz ${app}"
         rsync -avz -e "ssh -p ${PORT_NUMBER} ${IDENTITY_FILE}" ${ADMIN_USER}@localhost:${app}.tgz HPCTrainingDock/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}/${app}.tgz
      fi
   fi
done

PACKAGE_LIST=`ssh -p ${PORT_NUMBER} ${IDENTITY_FILE} ${ADMIN_USER}@localhost -t "ls /opt"`
# Remove trailing line break
PACKAGE_LIST=`echo ${PACKAGE_LIST} | tr -d '\r'`
echo "local linux package.list"
echo ":${PACKAGE_LIST}:"

for app in ${PACKAGE_LIST}
do
   if [[ "$app" == *rocm* ]]; then
      continue
   fi
   if [ ! -f "HPCTrainingDock/CacheFiles/${DISTRO}-${DISTRO_VERSION}/${app}.tgz" ]; then
      PACKAGE_SIZE=`ssh -p ${PORT_NUMBER} ${IDENTITY_FILE} ${ADMIN_USER}@localhost -t "du -sk /opt/${app} | cut -f1 | tr -d $'\n'" `
      echo "Package size for ${app} is ${PACKAGE_SIZE}"
      if [ "${PACKAGE_SIZE}" -gt "100" ]; then
         echo "Retrieving ${app}"
         ssh -p ${PORT_NUMBER} ${IDENTITY_FILE} ${ADMIN_USER}@localhost -t "cd /opt && tar -czf /users/${ADMIN_USER}/${app}.tgz ${app}"
         rsync -avz -e "ssh -p ${PORT_NUMBER} ${IDENTITY_FILE}" ${ADMIN_USER}@localhost:${app}.tgz HPCTrainingDock/CacheFiles/${DISTRO}-${DISTRO_VERSION}/${app}.tgz
      fi
   fi
done

