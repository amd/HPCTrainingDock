#!/bin/sh

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

sudo apt-get autoremove
sudo apt-get -q clean && sudo rm -rf /var/lib/apt/lists/*

# sudo apt purge --autoremove -y gcc-11

sudo rm -rf /etc/apt/trusted.gpg.d/ubuntu-toolchain-r_ubuntu_test.gpg
sudo rm -rf /etc/apt/sources.list.d/ubuntu-toolchain-r-ubuntu-test-focal.list
