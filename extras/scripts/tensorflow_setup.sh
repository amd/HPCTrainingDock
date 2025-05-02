#/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.0
BUILD_TF=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/tensorflow
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
TF_PATH=/opt/rocmplus-${ROCM_VERSION}/tensorflow
TF_PATH_INPUT=""
GIT_BRANCH="merge-250318"

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
   echo "  --git-branch [ GIT_BRANCH ] specify what commit git branch you want to build, default is $GIT_BRANCH"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
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

# Load the ROCm version for this TensorFlow build
source /etc/profile.d/lmod.sh
source /etc/profile.d/z01_lmod.sh
module load rocm/${ROCM_VERSION}
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
   cd /tmp

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

      # get tensorflow dependencies
      ${SUDO} apt-get update
      ${SUDO} apt-get install -y python3-dev python3-pip openjdk-8-jdk openjdk-8-jre unzip wget git python-is-python3 patchelf

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

      mkdir wheel_path_dir
      cd wheel_path_dir
      export WHEEL_PATH_DIR=$PWD
      cd ..

      export CLANG_COMPILER=`which clang`
      sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|" .bazelrc

      result=`echo ${ROCM_VERSION} | awk '$1>6.3.9'` && echo $result
      if [[ "${result}" ]]; then
	 # need this for ROCm greater than 6.4.0 due to upgrade in clang version
         sed -i '$a build:rocm --copt=-Wno-error=c23-extensions' .bazelrc
      fi

      # configure tensorflow
      yes "" | TF_NEED_CLANG=1 ROCM_PATH=$ROCM_PATH TF_NEED_ROCM=1 PYTHON_BIN_PATH=/usr/bin/python3 ./configure

      # build and install tensorflow
      bazel build --config=opt --config=rocm --repo_env=WHEEL_NAME=tensorflow_rocm \
	          --action_env=project_name=tensorflow_rocm/ //tensorflow/tools/pip_package:wheel \
		  --verbose_failures --repo_env=CC=$CLANG_COMPILER --repo_env=BAZEL_COMPILER=$CLANG_COMPILER \
		  --repo_env=OUTPUT_PATH=$WHEEL_DIR_PATH --repo_env=CLANG_COMPILER_PATH=$CLANG_COMPILER

      pip3 install -v --target=$TF_PATH --upgrade $WHEEL_DIR_PATH/tensorflow*.whl

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find $TF_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $TF_PATH -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w $TF_PATH
      fi

      # cleanup
      cd ..
      rm -rf tensorflow-upstream
      module unload rocm/${ROCM_VERSION}
      module unload amdclang
   fi

   # Create a module file for tensorflow
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

   TF_VERSION=`cat "$TF_PATH/tensorflow/_version.py"  | cut -f3 -d' ' |  tr -d "'"`
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${TF_VERSION}.lua
	whatis("Tensorflow with ROCm support")

	load("rocm/${ROCM_VERSION}")
	prepend_path("PYTHONPATH","$TF_PATH")
EOF

fi
