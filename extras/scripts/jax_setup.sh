#/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.2.0
BUILD_JAX=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/jax
AMDGPU_GFXMODEL_INPUT=""
JAX_VERSION=6.0
JAX_PATH=/opt/rocmplus-${ROCM_VERSION}/jax
JAX_PATH_INPUT=""
JAXLIB_PATH=/opt/rocmplus-${ROCM_VERSION}/jaxlib
JAXLIB_PATH_INPUT=""
PATCHELF_VERSION=0.18.0

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --jax-install-path, --jaxlib-install-path, and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected, specify as a comma separated list"
   echo "--build-jax [ BUILD_JAX ] set to 1 to build jax default is 0"
   echo "--jax-version [ JAX_VERSION ] version of JAX, XLA, and JAXLIB, default is $JAX_VERSION"
   echo "--jax-install-path [ JAX_PATH ] directory where JAX will be installed, default is $JAX_PATH"
   echo "--jaxlib-install-path [ JAXLIB_PATH ] directory where JAX will be installed, default is $JAXLIB_PATH"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "--help: print this usage information"
}

compat_info()
{
   echo " List of compatible versions according to https://github.com/ROCm/jax/releases: "
   echo " JAX version 7.1 --> ROCm version 7.1.0 and Python higher than 3.10 "
   echo " JAX version 5.0 --> ROCm versions 6.0.3, 6.2.4 and 6.3.1 "
   echo " JAX version 4.35 --> ROCm versions 6.0.3, 6.1.3 and 6.2.4 "
   echo " JAX version 4.34 --> ROCm versions 6.0.3, 6.1.3 and 6.2.3 "
   echo " JAX version 4.33 --> ROCm versions 6.0.3, 6.1.3 and 6.2.3 "
   echo " JAX version 4.31 --> ROCm versions 6.0.3, 6.1.3 and 6.2.3 "
   echo " JAX version 4.30 --> ROCm versions 6.1.1, 6.0.2 "
   echo " ... see https://github.com/ROCm/jax/releases for full list ... "
   echo " NOTE: ROCm versions not listed in the compatibility matrix might still work! "
   echo " For instance, ROCm 6.4.0 can be selected in this script with JAX version 5.0 and 4.35 "
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
      "--build-jax")
          shift
          BUILD_JAX=${1}
	  reset-last
          ;;
      "--jax-version")
          shift
          JAX_VERSION=${1}
	  reset-last
          ;;
      "--jax-install-path")
          shift
          JAX_PATH_INPUT=${1}
	  reset-last
          ;;
      "--jaxlib-install-path")
          shift
          JAXLIB_PATH_INPUT=${1}
	  reset-last
          ;;
      "--help")
          usage
          compat_info
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
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

if [ "${JAX_PATH_INPUT}" != "" ]; then
   JAX_PATH=${JAX_PATH_INPUT}
else
   # override jax path in case ROCM_VERSION has been supplied as input
   JAX_PATH=/opt/rocmplus-${ROCM_VERSION}/jax
fi

if [ "${JAXLIB_PATH_INPUT}" != "" ]; then
   JAXLIB_PATH=${JAXLIB_PATH_INPUT}
else
   # override jaxlib path in case ROCM_VERSION has been supplied as input
   JAXLIB_PATH=/opt/rocmplus-${ROCM_VERSION}/jaxlib
fi

# Load the ROCm version for this JAX build
source /etc/profile.d/lmod.sh
source /etc/profile.d/z01_lmod.sh
module load rocm/${ROCM_VERSION}
if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi

echo ""
echo "====================================="
echo " Installing JAXLIB and JAX"
echo " JAX Install directory: $JAX_PATH"
echo " JAXLIB Install directory: $JAXLIB_PATH"
echo " JAX Module directory: $MODULE_PATH"
echo " ROCm Version: $ROCM_VERSION"
echo "====================================="
echo ""

if [ "${BUILD_JAX}" = "0" ]; then

   echo "JAX will not be built, according to the specified value of BUILD_JAX"
   echo "BUILD_JAX: $BUILD_JAX"
   exit

else
   cd /tmp

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f "${CACHE_FILES}/jax.tgz" ] && [ -f "${CACHE_FILES}/jaxlib.tgz" ]; then
      echo ""
      echo "==================================="
      echo " Installing Cached JAXLIB and JAX"
      echo "==================================="
      echo ""

      #install the cached version
      ${SUDO} mkdir -p ${JAX_PATH}
      cd /opt/rocmplus-${ROCM_VERSION}

      ${SUDO} tar -xzpf ${CACHE_FILES}/jax.tgz

      ${SUDO} mkdir -p ${JAXLIB_PATH}
      ${SUDO} tar -xzpf ${CACHE_FILES}/jaxlib.tgz

      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm  ${CACHE_FILES}/jax.tgz ${CACHE_FILES}/jaxlib.tgz
      fi
   else
      echo ""
      echo "======================================="
      echo " Installing JAXLIB and JAX from source"
      echo "======================================="
      echo ""

      # don't use sudo if user has write access to both install paths
      if [ -d "$JAX_PATH" ]; then
         if [ -d "$JAXLIB_PATH" ]; then
            # don't use sudo if user has write access to both install paths
            if [ -w ${JAX_PATH} ]; then
               if [ -w ${JAXLIB_PATH} ]; then
               SUDO=""
               else
                  echo "WARNING: using install paths that require sudo"
               fi
            fi
         fi
      else
         # if install paths do not both exist yet
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ROCM_VERSION_BAZEL=`echo "$ROCM_VERSION" | awk -F. '{print $1}'`
      ROCM_VERSION_BAZEL="${ROCM_VERSION_BAZEL}0"

      if [[ `which python | wc -l` -eq 0 ]]; then
         if [[ ${SUDO} != "" ]]; then
            echo "============================"
   	    echo "WARNING: python needs to be linked to python3 for the build to work"
	    echo ".....Installing python-is-python3 with sudo......"
            echo "============================"
    	    ${SUDO} apt-get update
            ${SUDO} ${DEB_FRONTEND} apt-get install -y python-is-python3
         else
            ln -s $(which python3) ~/bin/python
            export PATH="$HOME/bin:$PATH"
            source $HOME/.bashrc
         fi
      fi

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm/${ROCM_VERSION}

      export JAX_PLATFORMS="rocm,cpu"

      AMDGPU_GFXMODEL=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/,/g'`

      git clone --depth 1 --branch rocm-jaxlib-v0.${JAX_VERSION} https://github.com/ROCm/xla.git
      cd xla
      export XLA_PATH=$PWD
      cd ..
      git clone --depth 1 --branch rocm-jaxlib-v0.${JAX_VERSION} https://github.com/ROCm/jax.git
      cd jax
      sed -i "s|gfx906,gfx908,gfx90a,gfx942,gfx1030,gfx1100,gfx1101,gfx1200,gfx1201|$AMDGPU_GFXMODEL|" .bazelrc

      # install necessary packages in installation directory
      ${SUDO} mkdir -p ${JAXLIB_PATH}
      ${SUDO} mkdir -p ${JAX_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${JAX_PATH}
         ${SUDO} chmod a+w ${JAXLIB_PATH}
      fi

      # this here is to take into account that the ROCm/jax repo has been deprecated
      # after the release of ROCm 7.1.0 and now it is all located at ROCm/rocm-jax
      if [[ $JAX_VERSION == "7.1" ]]; then
         result=`echo ${ROCM_VERSION} | awk '$1>7.0'` && echo $result
         # check if ROCm version is greater than or equal to 7.0
         if [[ "${result}" ]]; then

            PYTHON_VERSION=$(python3 -V 2>&1 | awk '{print $2}')
            if [[ "$PYTHON_VERSION" == 3.10.* ]]; then
               echo "Python 3.10 is not supported by JAX 7.1: https://docs.jax.dev/en/latest/deprecation.html"
               compat_info
            fi

            # we are building jaxlib with the ROCm/jax repo
            PATCHELF_PATH=${JAX_PATH}/patchelf
            ${SUDO} mkdir -p ${PATCHELF_PATH}
            git clone -b ${PATCHELF_VERSION} https://github.com/NixOS/patchelf.git
            cd patchelf
            ./bootstrap.sh
            ./configure --prefix=$PATCHELF_PATH
            make -j
            ${SUDO} make install
            export PATH=$PATH:$PATCHELF_PATH/bin
            cd ../
            rm -rf patchelf
            module load amdclang
            export CLANG_COMPILER=`which clang`
            sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|" .bazelrc
            python3 build/build.py build --rocm_path=$ROCM_PATH \
                                         --bazel_options=--override_repository=xla=$XLA_PATH \
                                         --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                         --clang_path=$ROCM_PATH/llvm/bin/clang \
                                         --rocm_version=$ROCM_VERSION_BAZEL \
                                         --use_clang=true \
                                         --wheels=jaxlib \
                                         --bazel_options=--jobs=128 \
                                         --bazel_startup_options=--host_jvm_args=-Xmx4g

	    # install the wheel for jaxlib
            pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall
            # next we need to install the jax python module
            pip3 install --target=${JAX_PATH} .

            cd ..
	    # then we are using the ROCm/rocm-jax repo to build the other wheels
   	    git clone  --depth 1 --branch rocm-jax-v0.${JAX_VERSION} https://github.com/ROCm/rocm-jax.git
	    cd rocm-jax/jax_rocm_plugin
            sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|" .bazelrc
            sed -i "s|gfx906,gfx908,gfx90a,gfx942,gfx1030,gfx1100,gfx1101,gfx1200,gfx1201|$AMDGPU_GFXMODEL|" .bazelrc
	    python3 build/build.py build --rocm_path=$ROCM_PATH \
                                         --bazel_options=--override_repository=xla=$XLA_PATH \
                                         --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                         --clang_path=$ROCM_PATH/llvm/bin/clang \
                                         --rocm_version=$ROCM_VERSION_BAZEL \
                                         --use_clang=true \
                                         --wheels=jax-rocm-plugin,jax-rocm-pjrt \
                                         --bazel_options=--jobs=128 \
                                         --bazel_startup_options=--host_jvm_args=-Xmx4g
            # next we need to install the wheels that we built
            pip3 install -v --target=${JAX_PATH} dist/jax*.whl --force-reinstall

         else
	    echo "For JAX version 7.1 you need at least ROCm 7.1.0"
            compat_info	    
         fi		 
      else 	      
         result=`echo ${ROCM_VERSION} | awk '$1>6.3.9'` && echo $result
         # check if ROCm version is greater than or equal to 6.4.0
         if [[ "${result}" ]]; then
            if [[ $JAX_VERSION == "4.35" ]]; then
               sed -i '$a build:rocm --copt=-Wno-error=c23-extensions' .bazelrc
               module load amdclang
               export CLANG_COMPILER=`which clang`
               sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|" .bazelrc
               # build the wheel for jaxlib using clang (which is the default)
               python3 build/build.py --enable_rocm --rocm_path=$ROCM_PATH \
                                      --bazel_options=--override_repository=xla=$XLA_PATH \
                                      --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                      --build_gpu_plugin --gpu_plugin_rocm_version=$ROCM_VERSION_BAZEL --build_gpu_kernel_plugin=rocm \
                                      --bazel_options=--jobs=128 \
                                      --bazel_startup_options=--host_jvm_args=-Xmx512m

               # install the wheel for jaxlib
               pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall

               # next we need to install the jax python module
               pip3 install --target=${JAX_PATH} .

            elif [[ $JAX_VERSION == "5.0" || $JAX_VERSION == "6.0" ]]; then
               PATCHELF_PATH=${JAX_PATH}/patchelf
               ${SUDO} mkdir -p ${PATCHELF_PATH}
               git clone -b ${PATCHELF_VERSION} https://github.com/NixOS/patchelf.git
               cd patchelf
               ./bootstrap.sh
               ./configure --prefix=$PATCHELF_PATH
               make -j
               ${SUDO} make install
               export PATH=$PATH:$PATCHELF_PATH/bin
               cd ../
               rm -rf patchelf
               module load amdclang
               export CLANG_COMPILER=`which clang`
               sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|" .bazelrc
               python3 build/build.py build --rocm_path=$ROCM_PATH \
                                            --bazel_options=--override_repository=xla=$XLA_PATH \
                                            --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                            --clang_path=$ROCM_PATH/llvm/bin/clang \
                                            --rocm_version=$ROCM_VERSION_BAZEL \
                                            --use_clang=true \
                                            --wheels=jaxlib,jax-rocm-plugin,jax-rocm-pjrt \
                                            --bazel_options=--jobs=128 \
                                            --bazel_startup_options=--host_jvm_args=-Xmx4g
 
               # install the wheel for jaxlib
               pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall

               # next we need to install the jax python module
               pip3 install --target=${JAX_PATH} .

            else
               echo " JAX version $JAX_VERSION not compatible with ROCm 6.4.0 "
               compat_info
            fi
         else
            if [[ $JAX_VERSION == "5.0" || $JAX_VERSION == "6.0" ]]; then
               PATCHELF_PATH=${JAX_PATH}/patchelf
               ${SUDO} mkdir -p ${PATCHELF_PATH}
               git clone -b ${PATCHELF_VERSION} https://github.com/NixOS/patchelf.git
               cd patchelf
               ./bootstrap.sh
               ./configure --prefix=$PATCHELF_PATH
               make -j
               ${SUDO} make install
               export PATH=$PATH:$PATCHELF_PATH/bin
               cd ../
               rm -rf patchelf
               module load amdclang
               export CLANG_COMPILER=`which clang`
               sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|" .bazelrc
               python3 build/build.py build --rocm_path=$ROCM_PATH \
                                            --bazel_options=--override_repository=xla=$XLA_PATH \
                                            --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                            --clang_path=$ROCM_PATH/llvm/bin/clang \
                                            --rocm_version=$ROCM_VERSION_BAZEL \
                                            --use_clang=true \
                                            --wheels=jaxlib,jax-rocm-plugin,jax-rocm-pjrt \
                                            --bazel_options=--jobs=128 \
                                            --bazel_startup_options=--host_jvm_args=-Xmx512m

               # install the wheel for jaxlib
               pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall

               # next we need to install the jax python module
               pip3 install --target=${JAX_PATH} .

            else
               # build the wheel for jaxlib using gcc
               python3 build/build.py --enable_rocm --rocm_path=$ROCM_PATH \
                                      --bazel_options=--override_repository=xla=$XLA_PATH \
                                      --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                      --bazel_options=--action_env=CC=/usr/bin/gcc --nouse_clang \
                                      --build_gpu_plugin --gpu_plugin_rocm_version=$ROCM_VERSION_BAZEL --build_gpu_kernel_plugin=rocm \
                                      --bazel_options=--jobs=128 \
                                      --bazel_startup_options=--host_jvm_args=-Xmx512m

               # install the wheel for jaxlib
               pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall

               # next we need to install the jax python module
               pip3 install --target=${JAX_PATH} .

            fi
         fi
      fi	 

      # cleanup
      cd ..
      rm -rf /tmp/jax
      rm -rf /tmp/rocm-jax
      rm -rf /tmp/xla

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${JAXLIB_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${JAXLIB_PATH} -type d -execdir chown root:root "{}" +
         ${SUDO} find ${JAX_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${JAX_PATH} -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w ${JAXLIB_PATH}
         ${SUDO} chmod go-w ${JAX_PATH}
      fi

      module unload rocm/${ROCM_VERSION}
   fi

   # Create a module file for jax
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

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/0.${JAX_VERSION}.lua
	whatis("JAX version ${JAX_VERSION} with ROCm support")

	load("rocm/${ROCM_VERSION}")
	setenv("XLA_FLAGS","--xla_gpu_enable_triton_gemm=False --xla_gpu_autotune_level=3")
	prepend_path("PYTHONPATH","${JAX_PATH}")
	prepend_path("PYTHONPATH","${JAXLIB_PATH}")
EOF

fi
