#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

echo ""
echo "############# Compiler Setup script ################"
echo ""

${SUDO} apt-get update
${SUDO} ${DEB_FRONTEND} apt-get install -y software-properties-common
${SUDO} add-apt-repository -y ppa:ubuntu-toolchain-r/test

# autodetecting default version for distro and getting available gcc version list
GCC_BASE_VERSION=`ls /usr/bin/gcc-* | cut -f2 -d'-' | grep '^[[:digit:]]' | head -1`
#GCC_VERSION_LIST=`apt list |grep '^gcc-[[:digit:]]*\/' |cut -f2 -d'-' | cut -f1 -d'/' | sort -n | tr '\n' ' '`
GCC_VERSION_LIST=""
echo "GCC_BASE_VERSION is ${GCC_BASE_VERSION}, GCC_VERSION_LIST is ${GCC_VERSION_LIST}"

${SUDO} ${DEB_FRONTEND} apt-get -qy install gcc-$GCC_BASE_VERSION-offload-amdgcn

MODULE_PATH=/etc/lmod/modules/Linux/gcc
${SUDO} mkdir -p ${MODULE_PATH}


val=80
for GCC_VERSION in ${GCC_VERSION_LIST}
do
   result=`echo $GCC_VERSION | awk '$1<$GCC_BASE_VERSION'` && echo $result
   if [[ "$GCC_VERSION" -lt "$GCC_BASE_VERSION" ]]; then
      continue
   fi
   echo "Adding GCC_VERSION $GCC_VERSION"
   ${SUDO} ${DEB_FRONTEND} apt-get -qqy install gcc-$GCC_VERSION g++-$GCC_VERSION gfortran-$GCC_VERSION libstdc++-$GCC_VERSION-dev
   ${SUDO} update-alternatives \
         --install /usr/bin/gcc      gcc      /usr/bin/gcc-$GCC_VERSION      $val \
         --slave   /usr/bin/g++      g++      /usr/bin/g++-$GCC_VERSION           \
         --slave   /usr/bin/gfortran gfortran /usr/bin/gfortran-$GCC_VERSION      \
         --slave   /usr/bin/gcov     gcov     /usr/bin/gcov-$GCC_VERSION
   ${SUDO} ${DEB_FRONTEND} apt-get -qy install gcc-$GCC_VERSION-offload-amdgcn
   val=$((val - 5))
# The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${GCC_VERSION}.lua
	whatis("GCC Version ${GCC_VERSION} compiler")
	setenv("CC", "/usr/bin/gcc-${GCC_VERSION}")
	setenv("CXX", "/usr/bin/g++-${GCC_VERSION}")
	setenv("F77", "/usr/bin/gfortran-${GCC_VERSION}")
	setenv("F90", "/usr/bin/gfortran-${GCC_VERSION}")
	setenv("FC", "/usr/bin/gfortran-${GCC_VERSION}")
	setenv("OMPI_CC", "/usr/bin/gcc-${GCC_VERSION}")
	setenv("OMPI_CXX", "/usr/bin/g++-${GCC_VERSION}")
	setenv("OMPI_FC", "/usr/bin/gfortran-${GCC_VERSION}")
	append_path("INCLUDE_PATH", "/usr/include")
	prepend_path("LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/${GCC_VERSION}")
	prepend_path("LD_LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/${GCC_VERSION}")
	family("compiler")
EOF
done

cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/base.lua
	whatis("GCC Version base version (${GCC_BASE_VERSION}) compiler")
	setenv("CC", "/usr/bin/gcc")
	setenv("CXX", "/usr/bin/g++")
	setenv("F77", "/usr/bin/gfortran")
	setenv("F90", "/usr/bin/gfortran")
	setenv("FC", "/usr/bin/gfortran")
	setenv("OMPI_CC", "/usr/bin/gcc")
	setenv("OMPI_CXX", "/usr/bin/g++")
	setenv("OMPI_FC", "/usr/bin/gfortran")
	append_path("INCLUDE_PATH", "/usr/include")
	prepend_path("LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/${GCC_BASE_VERSION}")
	prepend_path("LD_LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/${GCC_BASE_VERSION}")
	family("compiler")
EOF

cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/.version
	#%Module
	set ModulesVersion "${GCC_BASE_VERSION}"
EOF

# Install the default clang version before getting the base version for the distro
${SUDO} ${DEB_FRONTEND} apt-get -q install -y clang
CLANG_BASE_VERSION=`ls /usr/bin/clang-* | cut -f2 -d'-' | grep '^[[:digit:]]'`
#CLANG_VERSION_LIST=`apt list |grep '^clang-[[:digit:]]*\/' |cut -f2 -d'-' | cut -f1 -d'/' | sort -n | tr '\n' ' '`
CLANG_VERSION_LIST=""
echo "CLANG_BASE_VERSION is ${CLANG_BASE_VERSION}, CLANG_VERSION_LIST is ${CLANG_VERSION_LIST}"

MODULE_PATH=/etc/lmod/modules/Linux/clang
${SUDO} mkdir -p ${MODULE_PATH}

val=80
for CLANG_VERSION in ${CLANG_VERSION_LIST}
do
   if [ "$CLANG_VERSION" -lt "$CLANG_BASE_VERSION" ]; then
      continue
   fi
   ${SUDO} apt-get -qq update && ${SUDO} ${DEB_FRONTEND} apt-get -q install -y clang-$CLANG_VERSION libomp-$CLANG_VERSION-dev
   ${SUDO} update-alternatives \
	 --install /usr/bin/clang     clang     /usr/bin/clang-$CLANG_VERSION      $val \
	 --slave   /usr/bin/clang++   clang++   /usr/bin/clang++-$CLANG_VERSION         \
	 --slave   /usr/bin/clang-cpp clang-cpp /usr/bin/clang-cpp-$CLANG_VERSION
   val=$((val - 5))
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${CLANG_VERSION}.lua
	whatis("Clang (LLVM) Version ${CLANG_VERSION} compiler")
	setenv("CC", "/usr/bin/clang-${CLANG_VERSION}")
	setenv("CXX", "/usr/bin/clang++-${CLANG_VERSION}")
	setenv("F77", "/usr/bin/flang-${CLANG_VERSION}")
	setenv("F90", "/usr/bin/flang-${CLANG_VERSION}")
	setenv("FC", "/usr/bin/flang-${CLANG_VERSION}")
	setenv("OMPI_CC", "/usr/bin/clang-${CLANG_VERSION}")
	setenv("OMPI_CXX", "/usr/bin/clang++-${CLANG_VERSION}")
	setenv("OMPI_FC", "/usr/bin/flang-${CLANG_VERSION}")
	append_path("INCLUDE_PATH", "/usr/include")
	prepend_path("LIBRARY_PATH", "/usr/lib/llvm-${CLANG_VERSION}/lib")
	prepend_path("LD_LIBRARY_PATH", "/usr/lib/llvm-${CLANG_VERSION}/lib")
	family("compiler")
EOF
done

cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/base.lua
	whatis("Clang (LLVM) Base version ${CLANG_BASE_VERSION} compiler")
	setenv("CC", "/usr/bin/clang")
	setenv("CXX", "/usr/bin/clang++")
	setenv("F77", "/usr/bin/flang")
	setenv("F90", "/usr/bin/flang")
	setenv("FC", "/usr/bin/flang")
	setenv("OMPI_CC", "/usr/bin/clang")
	setenv("OMPI_CXX", "/usr/bin/clang++")
	setenv("OMPI_FC", "/usr/bin/flang")
	append_path("INCLUDE_PATH", "/usr/include")
	prepend_path("LIBRARY_PATH", "/usr/lib/llvm-${CLANG_BASE_VERSION}/lib")
	prepend_path("LD_LIBRARY_PATH", "/usr/lib/llvm-${CLANG_BASE_VERSION}/lib")
	family("compiler")
EOF

cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/.version
	#%Module
	set ModulesVersion "${CLANG_BASE_VERSION}"
EOF

${SUDO} chmod u+s /usr/bin/update-alternatives

# To change GCC version
# dad 3/23/23 add next line back in
#${SUDO} update-alternatives --config gcc
#${SUDO} update-alternatives --config clang

${SUDO} apt-get autoremove
${SUDO} apt-get -qy clean && ${SUDO} rm -rf /var/lib/apt/lists/*

# ${SUDO} apt purge --autoremove -y gcc-11

${SUDO} rm -rf /etc/apt/trusted.gpg.d/ubuntu-toolchain-r_ubuntu_test.gpg
${SUDO} rm -rf /etc/apt/sources.list.d/ubuntu-toolchain-r-ubuntu-test-focal.list
