#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

echo ""
echo "############# Compiler Setup script ################"
echo ""

sudo DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:ubuntu-toolchain-r/test

#sudo apt-get -qq update && sudo apt-get -qqy install gcc-9 g++-9 gfortran-9
#sudo apt-get -qq update && sudo apt-get -qqy install gcc-10 g++-10 gfortran-10
# Need to install libstdc++ for aomp install and some occasional software
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update && sudo apt-get -qqy install libstdc++-11-dev
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update && sudo apt-get -qqy install gcc-12 g++-12 gfortran-12 libstdc++-12-dev
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update && sudo apt-get -qqy install gcc-13 g++-13 gfortran-13 libstdc++-13-dev
#sudo update-alternatives \
#      --install /usr/bin/gcc      gcc      /usr/bin/gcc-9      70 \
#      --slave   /usr/bin/g++      g++      /usr/bin/g++-9         \
#      --slave   /usr/bin/gfortran gfortran /usr/bin/gfortran-9    \
#      --slave   /usr/bin/gcov     gcov     /usr/bin/gcov-9
#sudo update-alternatives \
#      --install /usr/bin/gcc      gcc      /usr/bin/gcc-10      75 \
#      --slave   /usr/bin/g++      g++      /usr/bin/g++-10         \
#      --slave   /usr/bin/gfortran gfortran /usr/bin/gfortran-10    \
#      --slave   /usr/bin/gcov     gcov     /usr/bin/gcov-10
sudo update-alternatives \
      --install /usr/bin/gcc      gcc      /usr/bin/gcc-11      80 \
      --slave   /usr/bin/g++      g++      /usr/bin/g++-11         \
      --slave   /usr/bin/gfortran gfortran /usr/bin/gfortran-11    \
      --slave   /usr/bin/gcov     gcov     /usr/bin/gcov-11        \
      --slave   /usr/lib/libstdc++.so libstdc++.so /usr/lib/gcc/x86_64-linux-gnu/11/libstdc++.so
sudo update-alternatives \
      --install /usr/bin/gcc      gcc      /usr/bin/gcc-12      75 \
      --slave   /usr/bin/g++      g++      /usr/bin/g++-12         \
      --slave   /usr/bin/gfortran gfortran /usr/bin/gfortran-12    \
      --slave   /usr/bin/gcov     gcov     /usr/bin/gcov-12        \
      --slave   /usr/lib/libstdc++.so libstdc++.so /usr/lib/gcc/x86_64-linux-gnu/12/libstdc++.so
sudo update-alternatives \
      --install /usr/bin/gcc      gcc      /usr/bin/gcc-13      70 \
      --slave   /usr/bin/g++      g++      /usr/bin/g++-13         \
      --slave   /usr/bin/gfortran gfortran /usr/bin/gfortran-13    \
      --slave   /usr/bin/gcov     gcov     /usr/bin/gcov-13        \
      --slave   /usr/lib/libstdc++.so libstdc++.so /usr/lib/gcc/x86_64-linux-gnu/13/libstdc++.so

sudo DEBIAN_FRONTEND=noninteractive apt-get -qy install gcc-11-offload-amdgcn
sudo DEBIAN_FRONTEND=noninteractive apt-get -qy install gcc-12-offload-amdgcn
sudo DEBIAN_FRONTEND=noninteractive apt-get -qy install gcc-13-offload-amdgcn

sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install clang libomp-14-dev
#sudo apt-get -qq update && sudo apt-get -q install -y clang-14 libomp-14-dev
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update && sudo apt-get -q install -y clang-15 libomp-15-dev

sudo update-alternatives \
      --install /usr/bin/clang     clang     /usr/bin/clang-14      70 \
      --slave   /usr/bin/clang++   clang++   /usr/bin/clang++-14       \
      --slave   /usr/bin/clang-cpp clang-cpp /usr/bin/clang-cpp-14
sudo update-alternatives \
      --install /usr/bin/clang     clang     /usr/bin/clang-15      75 \
      --slave   /usr/bin/clang++   clang++   /usr/bin/clang++-15       \
      --slave   /usr/bin/clang-cpp clang-cpp /usr/bin/clang-cpp-15
#sudo update-alternatives \
#      --install /usr/bin/clang     clang     /opt/rocm-ROCM_VERSION/llvm/bin/clang    80 \
#      --slave   /usr/bin/clang++   clang++   /opt/rocm-ROCM_VERSION/llvm/bin/clang++     \
#      --slave   /usr/bin/clang-cpp clang-cpp /opt/rocm-ROCM_VERSION/llvm/bin/clang-cpp

sudo chmod u+s /usr/bin/update-alternatives

# To change GCC version
# dad 3/23/23 add next line back in
sudo update-alternatives --config gcc
sudo update-alternatives --config clang

sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove
sudo DEBIAN_FRONTEND=noninteractive apt-get -q clean && sudo rm -rf /var/lib/apt/lists/*

# sudo apt purge --autoremove -y gcc-11

sudo rm -rf /etc/apt/trusted.gpg.d/ubuntu-toolchain-r_ubuntu_test.gpg
sudo rm -rf /etc/apt/sources.list.d/ubuntu-toolchain-r-ubuntu-test-focal.list

MODULE_PATH=/etc/lmod/modules/Linux/gcc
sudo mkdir ${MODULE_PATH}


if [ "${DISTRO_VERSION}" = "22.04" ]; then
   GCC_VERSION_LIST="11 12 13"
   GCC_BASE_VERSION=11
   CLANG_VERSION_LIST="14 15"
   CLANG_BASE_VERSION=14
elif [ "${DISTRO_VERSION}" = "20.04" ]; then
	# more were needed for 20.04
   GCC_VERSION_LIST="11 12 13"
   GCC_BASE_VERSION=11
   CLANG_VERSION_LIST="14 15"
   CLANG_BASE_VERSION=14
else
   GCC_VERSION_LIST="11 12 13"
   GCC_BASE_VERSION=11
   CLANG_VERSION_LIST="14 15"
   CLANG_BASE_VERSION=14
fi

# The - option suppresses tabs
for GCC_VERSION in ${GCC_VERSION_LIST}
do
   cat <<-EOF | sudo tee ${MODULE_PATH}/${GCC_VERSION}.lua
	whatis("GCC Version ${GCC_VERSION} compiler")
	setenv("CC", "/usr/bin/gcc-${GCC_VERSION}")
	setenv("CXX", "/usr/bin/g++-${GCC_VERSION}")
	setenv("F77", "/usr/bin/gfortran-${GCC_VERSION}")
	setenv("F90", "/usr/bin/gfortran-${GCC_VERSION}")
	setenv("FC", "/usr/bin/gfortran-${GCC_VERSION}")
	append_path("INCLUDE_PATH", "/usr/include")
	prepend_path("LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/${GCC_VERSION}")
	prepend_path("LD_LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/${GCC_VERSION}")
	family("compiler")
EOF
done

cat <<-EOF | sudo tee ${MODULE_PATH}/base.lua
	whatis("GCC Version base version (${GCC_BASE_VERSION}) compiler")
	setenv("CC", "/usr/bin/gcc")
	setenv("CXX", "/usr/bin/g++")
	setenv("F77", "/usr/bin/gfortran")
	setenv("F90", "/usr/bin/gfortran")
	setenv("FC", "/usr/bin/gfortran")
	append_path("INCLUDE_PATH", "/usr/include")
	prepend_path("LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/${GCC_BASE_VERSION}")
	prepend_path("LD_LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/${GCC_BASE_VERSION}")
	family("compiler")
EOF

cat <<-EOF | sudo tee ${MODULE_PATH}/.version
	#%Module
	set ModulesVersion "${GCC_BASE_VERSION}"
EOF

MODULE_PATH=/etc/lmod/modules/Linux/clang
sudo mkdir ${MODULE_PATH}

for CLANG_VERSION in ${CLANG_VERSION_LIST}
do
   cat <<-EOF | sudo tee ${MODULE_PATH}/${CLANG_VERSION}.lua
	whatis("Clang (LLVM) Version ${CLANG_VERSION} compiler")
	setenv("CC", "/usr/bin/clang-${CLANG_VERSION}")
	setenv("CXX", "/usr/bin/clang++-${CLANG_VERSION}")
	setenv("F77", "/usr/bin/flang-${CLANG_VERSION}")
	setenv("F90", "/usr/bin/flang-${CLANG_VERSION}")
	setenv("FC", "/usr/bin/flang-${CLANG_VERSION}")
	append_path("INCLUDE_PATH", "/usr/include")
	prepend_path("LIBRARY_PATH", "/usr/lib/llvm-${CLANG_VERSION}/lib")
	prepend_path("LD_LIBRARY_PATH", "/usr/lib/llvm-${CLANG_VERSION}/lib")
	family("compiler")
EOF
done

cat <<-EOF | sudo tee ${MODULE_PATH}/base.lua
	whatis("Clang (LLVM) Base version ${CLANG_BASE_VERSION} compiler")
	setenv("CC", "/usr/bin/clang")
	setenv("CXX", "/usr/bin/clang++")
	setenv("F77", "/usr/bin/flang")
	setenv("F90", "/usr/bin/flang")
	setenv("FC", "/usr/bin/flang")
	append_path("INCLUDE_PATH", "/usr/include")
	prepend_path("LIBRARY_PATH", "/usr/lib/llvm-${CLANG_BASE_VERSION}/lib")
	prepend_path("LD_LIBRARY_PATH", "/usr/lib/llvm-${CLANG_BASE_VERSION}/lib")
	family("compiler")
EOF

cat <<-EOF | sudo tee ${MODULE_PATH}/.version
	#%Module
	set ModulesVersion "${CLANG_BASE_VERSION}"
EOF

