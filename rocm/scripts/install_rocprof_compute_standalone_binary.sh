#!/bin/bash
export ROCM_VERSION=`cat ${ROCM_PATH}/.info/version | cut -f1 -d'-' `
if [[ "$ROCM_VERSION" == "" ]]; then
   echo "ROCM module not loaded or ROCM_VERSION not found"
   exit
else
   echo "ROCM_VERSION is $ROCM_VERSION"
fi
REQUIREMENTS_TXT="astunparse==1.6.2 colorlover dash-bootstrap-components dash-svg dash>=3.0.0"
REQUIREMENTS_TXT="${REQUIREMENTS_TXT} kaleido==0.2.1 matplotlib numpy>=1.17.5 pandas>=1.4.3"
REQUIREMENTS_TXT="${REQUIREMENTS_TXT} plotext plotille pymongo pyyaml setuptools sqlalchemy>=2.0.42"
REQUIREMENTS_TXT="${REQUIREMENTS_TXT} tabulate textual textual_plotext textual-fspicker>=0.4.3 tqdm"

rm -rf standalonebinary
python3 -m venv standalonebinary
source standalonebinary/bin/activate
cd standalonebinary
git clone --no-checkout --filter=blob:none https://github.com/ROCm/rocm-systems.git
cd rocm-systems
git sparse-checkout init --cone
git sparse-checkout set projects/rocprofiler-compute
git branch --list
git checkout rocm-${ROCM_VERSION}
#git checkout develop
cd projects/rocprofiler-compute
python3 -m pip install $REQUIREMENTS_TXT
python3 -m pip install nuitka==2.6 patchelf

# Using CMakeLists.txt
#cmake -B build -DCMAKE_INSTALL_PREFIX=$ROCM_PATH/bin -S .
#cmake --build build --target standalonebinary

# Local version from CMakeLists.txt example
# Change working directory to src
cd src
# Create VERSION.sha file
git -C .. rev-parse HEAD > VERSION.sha
# Build standalone binary
# NOTE: --no-deployment-flag=self-execution is used to avoid self-execution
# and fork bombs as explained in
# https://nuitka.net/user-documentation/common-issue-solutions.html#fork-bombs-self-execution
export PROJECT_SOURCE_DIR=`pwd`/..
   python3 -m nuitka --mode=onefile --no-deployment-flag=self-execution \
     --include-data-files=${PROJECT_SOURCE_DIR}/VERSION*=./ --enable-plugin=no-qt --enable-plugin=no-qt \
     --include-package=dash_svg --include-package-data=dash_svg \
     --include-package=dash_bootstrap_components \
     --include-package-data=dash_bootstrap_components --include-package=plotly \
     --include-package-data=plotly --include-package=kaleido \
     --include-package-data=kaleido --include-package=rocprof_compute_analyze \
     --include-package-data=rocprof_compute_analyze \
     --include-package=rocprof_compute_profile \
     --include-package-data=rocprof_compute_profile \
     --include-package=rocprof_compute_tui --include-package-data=rocprof_compute_tui \
     --include-package=rocprof_compute_soc --include-package-data=rocprof_compute_soc \
     --include-package=utils --include-package-data=utils rocprof-compute
# Remove library rpath from executable
patchelf --remove-rpath rocprof-compute.bin
# Move to build directory
sudo cp rocprof-compute.bin $ROCM_PATH/bin/rocprof-compute.bin
cd ..

src/rocprof-compute.bin --help
echo "return code is $?"

echo ""
find . -name rocprof-compute.bin -print

if [[ ! -L $ROCM_PATH/bin/rocprof-compute.py ]]; then
   sudo mv $ROCM_PATH/bin/rocprof-compute $ROCM_PATH/bin/rocprof-compute.py
fi
if [[ ! -L $ROCM_PATH/bin/rocprof-compute ]]; then
   pushd $ROCM_PATH/bin && sudo ln -s rocprof-compute.bin rocprof-compute && popd
fi
