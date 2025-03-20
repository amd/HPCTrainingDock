#!/bin/bash -l
set -v

set -e

module purge
module load cuda/12.1
module load gcc/12

ROCM_BRANCH=rocm-6.3.0
PREFIX=$PWD/$ROCM_BRANCH
CMAKE_PREFIX_PATH=$PWD/rocm

export CUDA_PATH=$CUDA_HOME

wget -q https://github.com/ROCm/llvm-project/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-llvm-project.tgz
wget -q https://github.com/ROCm/clr/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-clr.tgz
wget -q https://github.com/ROCm/HIP/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-hip.tgz
wget -q https://github.com/ROCm/hipother/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-hipother.tgz
wget -q https://github.com/ROCm/hipBLAS-common/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-hipblas-common.tgz
wget -q https://github.com/ROCm/hipBLAS/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-hipblas.tgz
wget -q https://github.com/ROCm/hipFFT/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-hipfft.tgz
wget -q https://github.com/ROCm/hipSOLVER/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-hipsolver.tgz
wget -q https://github.com/ROCm/hipSPARSE/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-hipsparse.tgz
wget -q https://github.com/ROCm/HIPIFY/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-hipify.tgz
wget -q https://github.com/ROCm/ROCR-Runtime/archive/refs/tags/${ROCM_BRANCH}.tar.gz -O ${ROCM_BRANCH}-rocr-runtime.tgz

tar -xzf ${ROCM_BRANCH}-llvm-project.tgz
tar -xzf ${ROCM_BRANCH}-clr.tgz
tar -xzf ${ROCM_BRANCH}-hip.tgz
tar -xzf ${ROCM_BRANCH}-hipother.tgz
tar -xzf ${ROCM_BRANCH}-hipblas-common.tgz
tar -xzf ${ROCM_BRANCH}-hipblas.tgz
tar -xzf ${ROCM_BRANCH}-hipfft.tgz
tar -xzf ${ROCM_BRANCH}-hipsolver.tgz
tar -xzf ${ROCM_BRANCH}-hipsparse.tgz
tar -xzf ${ROCM_BRANCH}-hipify.tgz
tar -xzf ${ROCM_BRANCH}-rocr-runtime.tgz

export LLVM_PROJECT_DIR="$(readlink -f llvm-project-$ROCM_BRANCH)"
export HIPCC_DIR="$(readlink -f llvm-project-$ROCM_BRANCH/amd/hipcc)"
export DEVICE_LIBS=${LLVM_PROJECT_DIR}/amd/device-libs
export COMGR=${LLVM_PROJECT_DIR}/amd/comgr
export CLR_DIR="$(readlink -f clr-$ROCM_BRANCH)"
export HIP_DIR="$(readlink -f HIP-$ROCM_BRANCH)"
export HIP_OTHER="$(readlink -f hipother-$ROCM_BRANCH)"
export HIPBLAS_COMMON_DIR="$(readlink -f  hipBLAS-common-$ROCM_BRANCH)"
export HIPBLAS_DIR="$(readlink -f  hipBLAS-$ROCM_BRANCH)"
export HIPFFT_DIR="$(readlink -f hipFFT-$ROCM_BRANCH)"
export HIPSOLVER_DIR="$(readlink -f hipSOLVER-$ROCM_BRANCH)"
export HIPSPARSE_DIR="$(readlink -f hipSPARSE-$ROCM_BRANCH)"
export HIPIFY_DIR="$(readlink -f HIPIFY-$ROCM_BRANCH)"
export ROCR_RUNTIME_DIR="$(readlink -f ROCR-Runtime-$ROCM_BRANCH)"
export LLVM_PROJECT=${LLVM_PROJECT_DIR}
export CXX=g++
export CC=gcc

echo "****************** HIP **************************"

cd "$HIPCC_DIR"
mkdir -p build; cd build
cmake -DCMAKE_INSTALL_PREFIX=$PREFIX ..
make -j 8
make install

cd "$CLR_DIR"
mkdir -p build; cd build
cmake -DHIP_COMMON_DIR=$HIP_DIR \
      -DHIP_PLATFORM=nvidia \
      -DCMAKE_INSTALL_PREFIX=$PREFIX \
      -DHIPCC_BIN_DIR=$HIPCC_DIR/build \
      -DHIP_CATCH_TEST=0 \
      -DCLR_BUILD_HIP=ON \
      -DCLR_BUILD_OCL=OFF \
      -DHIPNV_DIR=$HIP_OTHER/hipnv \
      ..
make -j 8
make install

echo "****************** HIP BLAS **************************"

cd "$HIPBLAS_COMMON_DIR"
mkdir -p build; cd build
cmake -DCMAKE_INSTALL_PREFIX=$PREFIX \
      ..
make package install

cd "$HIPBLAS_DIR"
mkdir -p build; cd build
cmake -DHIP_PLATFORM=nvidia \
      -DHIPBLAS_COMMON_DIR=$HIPBLAS_COMMON_DIR \
      -DCMAKE_INSTALL_PREFIX=$PREFIX \
      ..
make -j 8
make install

echo "****************** HIP LLVM-Project-rocm  **************************"

cd $LLVM_PROJECT
mkdir build && cd build
cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DLLVM_ENABLE_PROJECTS="llvm;clang;lld" \
    -DLLVM_TARGETS_TO_BUILD="AMDGPU;X86" \
    ../llvm
make -j 20
make install

cd $DEVICE_LIBS
mkdir build && cd build
cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    ..
make -j 20
make install

cd $COMGR
mkdir build && cd build
cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    ..
make -j 20
make install

echo "****************** HIP SOLVER **************************"

cd "$HIPSOLVER_DIR"
mkdir build && cd build
export CXXFLAGS=-D__HIP_PLATFORM_NVIDIA__
cmake -DUSE_CUDA=1 \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_MODULE_PATH=$PREFIX/lib64/cmake/hip \
      -DCMAKE_INSTALL_PREFIX=$PREFIX \
      ..
make -j 8
make install

echo "****************** ROCR_RUNTIME (HSA_RUNTIME) **************************"

cd $ROCR_RUNTIME_DIR
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=$PREFIX ..
make -j 8
make install

echo "****************** HIP FFT **************************"

cd "$HIPFFT_DIR"
mkdir -p build; cd build
export CXXFLAGS=-I$PREFIX/include
cmake -DCMAKE_BUILD_TYPE=Release \
      -DHIP_PLATFORM=nvidia \
      -DBUILD_WITH_LIB=CUDA \
      -DCMAKE_INSTALL_PREFIX=$PREFIX \
      ..
make -j 8
make install

echo "****************** HIP SPARSE **************************"

cd "$HIPSPARSE_DIR"
mkdir -p build; cd build
cmake -DCMAKE_BUILD_TYPE=Release \
      -DUSE_CUDA=ON \
      -DCMAKE_MODULE_PATH=$PREFIX/lib64/cmake/hip \
      -DCMAKE_INSTALL_PREFIX=$PREFIX \
      -DBUILD_CLIENTS_BENCHMARKS=OFF \
      -DBUILD_CLIENTS_SAMPLES=OFF \
      ..
make -j 8
make install

echo "****************** HIPIFY **************************"

cd "$HIPIFY_DIR"
mkdir -p $PREFIX/hipify
cp -r bin $PREFIX/hipify/
