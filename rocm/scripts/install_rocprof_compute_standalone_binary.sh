#!/bin/bash
export ROCM_VERSION=`cat ${ROCM_PATH}/.info/version | cut -f1 -d'-' `
if [[ "$ROCM_VERSION" == "" ]]; then
   echo "ROCM module not loaded or ROCM_VERSION not found"
   exit
else
   echo "ROCM_VERSION is $ROCM_VERSION"
fi
export LD_LIBRARY_PATH="standalonebinary/lib/python3.10/site-packages/kaleido/executable/lib:$LD_LIBRARY_PATH"
rm -rf standalonebinary
python3 -m venv standalonebinary
source standalonebinary/bin/activate
cd standalonebinary
module load rocm/${ROCM_VERSION}

git clone --no-checkout --filter=blob:none https://github.com/ROCm/rocm-systems.git
cd rocm-systems
git sparse-checkout init --cone
git sparse-checkout set projects/rocprofiler-compute
git branch --list
git checkout rocm-${ROCM_VERSION}
#git checkout develop
cd projects/rocprofiler-compute
python3 -m pip install -r requirements.txt
python3 -m pip install nuitka patchelf
cmake -B build -DCMAKE_INSTALL_PREFIX=install -S .
cmake --build build --target install --parallel 8
make -C build standalonebinary
cmake --build build --target standalonebinary

echo ""
find . -name rocprof-compute.bin -print

sudo mv $ROCM_PATH/bin/rocprof-compute $ROCM_PATH/bin/rocprof-compute.back
sudo cp src/rocprof-compute.dist/rocprof-compute.bin $ROCM_PATH/bin/rocprof-compute.bin
pushd $ROCM_PATH/bin && sudo ln -s rocprof-compute.bin rocprof-compute && popd

deactivate
cd ../../../..
pwd
rm -rf standalonebinary

