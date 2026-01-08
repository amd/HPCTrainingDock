#!/bin/bash
export ROCM_VERSION=`cat ${ROCM_PATH}/.info/version | cut -f1 -d'-' `
if [[ "$ROCM_VERSION" == "" ]]; then
   echo "ROCM module not loaded or ROCM_VERSION not found"
   exit
else
   echo "ROCM_VERSION is $ROCM_VERSION"
fi

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
mv requirements.txt requirements.txt.back

cat << EOF > requirements.txt
astunparse==1.6.2
blinker==1.9.0
certifi==2026.1.4
charset-normalizer==3.4.4
click==8.3.1
colorlover==0.3.0
contourpy==1.3.2
cycler==0.12.1
dash==3.3.0
dash-bootstrap-components==2.0.4
dash-svg==0.0.12
dnspython==2.8.0
Flask==3.1.2
fonttools==4.61.1
greenlet==3.3.0
idna==3.11
importlib_metadata==8.7.1
itsdangerous==2.2.0
Jinja2==3.1.6
kaleido==0.2.1
kiwisolver==1.4.9
linkify-it-py==2.0.3
markdown-it-py==4.0.0
MarkupSafe==3.0.3
matplotlib==3.10.8
mdit-py-plugins==0.5.0
mdurl==0.1.2
narwhals==2.15.0
nest-asyncio==1.6.0
Nuitka==2.6
numpy==2.2.6
ordered-set==4.1.0
packaging==25.0
pandas==2.3.3
patchelf==0.17.2.4
pillow==12.1.0
platformdirs==4.5.1
plotext==5.3.2
plotille==5.0.0
plotly==6.5.1
Pygments==2.19.2
pymongo==10.10.10.10
pyparsing==3.3.1
python-dateutil==3.9.0
pytz==2025.2
PyYAML==6.0.3
requests==2.32.5
retrying==1.4.2
rich==14.2.0
six==1.17.0
SQLAlchemy==2.0.45
tabulate==0.9.0
textual==7.0.1
textual-fspicker==0.6.0
textual-plotext==1.0.1
tqdm==4.67.1
typing_extensions==4.15.0
tzdata==2025.3
uc-micro-py==1.0.3
urllib3==2.6.3
Werkzeug==3.1.5
zipp==3.23.0
zstandard==0.25.0
EOF

python3 -m pip install -r requirements.txt
#python3 -m pip install nuitka==2.6 patchelf

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
     --include-package-data=plotly --noinclude-data-files=plotly/datasets/* --include-package=kaleido \
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

du -skh `which rocprof-compute`.bin

deactivate
cd ../../../..
rm -rf standalonebinary
