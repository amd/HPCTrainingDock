make rocm
sudo apt-get install -y libssl-dev unzip libopenmpi-dev libopenblas-dev libint2-dev libxc-dev
export CP2K_BRANCH="v2024.3"
export AMDGPU_TARGETS=gfx942
module load rocm
export LD_LIBRARY_PATH==$ROCM_PATH/lib/rocblas:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH==$ROCM_PATH/lib/rocfft:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH==$ROCM_PATH/lib/hipfft:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH==$ROCM_PATH/lib/hipblas:$LD_LIBRARY_PATH
export LIBRARY_PATH=$ROCM_PATH/lib/rocblas:$LIBRARY_PATH
export LIBRARY_PATH=$ROCM_PATH/lib/hipblas:$LIBRARY_PATH
export LIBRARY_PATH=$ROCM_PATH/lib/rocfft:$LIBRARY_PATH
export C_INCLUDE_PATH=$ROCM_PATH/include/rocblas:$C_INCLUDE_PATH
export C_INCLUDE_PATH=$ROCM_PATH/include/hipfft:$C_INCLUDE_PATH
export C_INCLUDE_PATH=$ROCM_PATH/include/hipblas:$C_INCLUDE_PATH
export C_INCLUDE_PATH=$ROCM_PATH/include/rocfft:$C_INCLUDE_PATH
export CPLUS_INCLUDE_PATH=$ROCM_PATH/include/rocblas:$CPLUS_INCLUDE_PATH
export CPLUS_INCLUDE_PATH=$ROCM_PATH/include/hipfft:$CPLUS_INCLUDE_PATH
export CPLUS_INCLUDE_PATH=$ROCM_PATH/include/hipblas:$CPLUS_INCLUDE_PATH
export CPLUS_INCLUDE_PATH=$ROCM_PATH/include/rocfft:$CPLUS_INCLUDE_PATH
export CP2K_DIR=$HOME/cp2k

cd $HOME

git clone --recursive -b ${CP2K_BRANCH} https://github.com/cp2k/cp2k.git

cd cp2k/tools/toolchain

./install_cp2k_toolchain.sh \
            -j 8 \
            --install-all \
            --mpi-mode=openmpi \
            --math-mode=openblas \
            --gpu-ver=Mi250 \
            --enable-hip \
            --with-gcc=system \
            --with-openmpi=system \
            --with-mkl=no \
            --with-acml=no \
            --with-ptscotch=no \
            --with-superlu=no \
            --with-pexsi=no \
            --with-quip=no \
            --with-plumed=no \
            --with-sirius=no \
            --with-gsl=no \
            --with-libvdwxc=no \
            --with-spglib=no \
            --with-hdf5=no \
            --with-spfft=no \
            --with-libvori=no \
            --with-libtorch=no \
            --with-elpa=no \
            --with-deepmd=no \
            --with-cosma=no \
            --with-openblas=/usr \
            --with-libint=/usr \
            --with-ninja=/usr \
            --with-cmake=/usr/local \
            --with-libxc=/usr \
            --with-dftd4=no

cd ${CP2K_DIR}
sed -i 's/hip\/bin/bin/' ${CP2K_DIR}/tools/toolchain/install/arch/local_hip.psmp
sed -i "s/$AMDGPU_TARGETS/gfx90a/" ${CP2K_DIR}/tools/toolchain/install/arch/local_hip.psmp
sed -i "s/$AMDGPU_TARGETS/gfx90a/" ${CP2K_DIR}/exts/build_dbcsr/Makefile
sed -i "/^DFLAGS/s/$/ -D__NO_OFFLOAD_GRID -DNO_OFFLOAD_DBM -DNO_OFFLOAD_PW/" ${CP2K_DIR}/tools/toolchain/install/arch/local_hip.psmp
sed -i 's/-D__DBCSR_ACC//' ${CP2K_DIR}/tools/toolchain/install/arch/local_hip.psmp
cp ${CP2K_DIR}/tools/toolchain/install/arch/* ${CP2K_DIR}/arch/.
cat ${CP2K_DIR}/arch/local_hip.psmp
source ${CP2K_DIR}/tools/toolchain/install/setup
cd ${CP2K_DIR}
make realclean ARCH=local_hip VERSION=psmp
make -j 8 ARCH=local_hip VERSION=psmp
