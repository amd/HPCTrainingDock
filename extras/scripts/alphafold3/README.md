# Setup and Run Alphafold3 with ROCm 7.1.1 and JAX 7.1 on MI300A
These instructions go over how to build and run Alphafold3 ( commit hash 3a09f04 from Dec 2nd 2025) on MI300A with ROCm 7.1.1 and JAX 7.1.
**Note**: we are NOT using the official model weights, but rather dummy random weights, generated with [these](https://github.com/google-deepmind/alphafold3/blob/main/docs/model_parameters.md) instructions.

Begin by accessing your system: in this case we consider the aac7 AMD system, adjust as needed:

```
ssh $USER@aac7.amd.com
salloc -N 1 --gpus=4
```

You may have to do this to have `podman` working:

```
mkdir -p /tmp/podman_storage
```

Then modify the `.config/containers/storage.conf` as below (you might have to create the file if it does not exist)

```
cat .config/containers/storage.conf
```

this is what you should have in the `.config/containers/storage.conf` file:
```
[storage]
driver = "overlay"
graphroot = "/tmp/podman_storage"
```

Pull the ROCm 7.1.1 image (note there are no libs in it, we'll install them later):

```
podman pull rocm/dev-ubuntu-24.04:7.1.1
```

Get the image ID from running:

```
podman images
```

example output is
```
[$USER@x9000c1s1b0n0 ~]$ podman images
REPOSITORY                       TAG         IMAGE ID      CREATED      SIZE
docker.io/rocm/dev-ubuntu-24.04  7.1.1       59e5b8637925  7 weeks ago  3.78 GB
```

Then do:
```
mkdir 104-P55854 
mkdir -p 104-P55854/af_weights
mkdir -p 104-P55854/inputs
mkdir -p 104-P55854/outputs
```

In `104-P55854/inputs` copy the file in this directory called `input.json` which as this content:
```
{
  "name": "104-P55854",
  "modelSeeds": [1, 2],
  "sequences": [
    { "protein": {
      "id": "A",
      "sequence": "MSEEKPKEGVKTENDHINLKVAGQDGSVVQFKIKRHTPLSKLMKAYCERQGLSMRQIRFRFDGQPINETDTPAQLEMEDEDTIDVFQQQTGGVPESSLAGHSF"
       }
    }
  ],
  "dialect": "alphafold3",
  "version": 2
}
```

Run the image, make sure to put your image ID before `/bin/bash` (note: you also need to have downloaded the database with [this](https://github.com/google-deepmind/alphafold3/blob/main/fetch_databases.sh) script:
```
podman run -it   --name alphafold   --shm-size=256m   --device=/dev/kfd   --device=/dev/dri   --group-add video   --group-add render   --security-opt seccomp=unconfined   -v $HOME/104-P55854/inputs:/root/af_input   -v $HOME/104-P55854/outputs:/root/af_output  -v /shareddata/alphafold3_database:/root/public_databases:ro   59e5b8637925 /bin/bash
``` 

After the above command, you'll be in the container, set these for starters (we consider MI300A so the gfx arch is gfx942):
```
export AMDGPU_GFXMODEL=gfx942
export ROCM_VERSION=7.1.1
export ROCM_PATH=/opt/rocm-$ROCM_VERSION
export ROCM_VERSION_BAZEL=`echo "$ROCM_VERSION" | awk -F. '{print $1}'`
export CLANG_COMPILER=`which amdclang`
export JAX_VERSION=7.1
export PATCHELF_VERSION=0.18.0
export JAX_PLATFORMS="rocm,cpu"
export PATH=$PATH:/hmmer/bin
```

Sanity check: 
```
rocminfo | grep MI
``` 
and confirm that you see MI300A.

Install basic OS software:
```
apt-get update
apt-get install -q -y vim git sudo build-essential cmake libnuma1 wget gnupg2 m4 bash-completion git-core autoconf libtool autotools-dev \
      lsb-release libpapi-dev libpfm4-dev libudev1 rpm librpm-dev curl apt-utils vim tmux rsync \
      bison flex texinfo libnuma-dev pkg-config libibverbs-dev rdmacm-utils ssh locales gpg ca-certificates \
      gcc g++ gfortran ninja-build libtbb-dev nano python3-pip python3-dev python3-venv
```
 
Now create the python venv, activate it and install cmake:

```
cd
python3 -m venv alphafold3_env
source alphafold3_env/bin/activate
python3 -m pip install 'cmake==3.28.3'
```

Install the necessary missing ROCm libraries:
```
apt-get install -q -y miopen-hip hipfft hipsparse hipsolver hiprand rccl hipblas hipcub
```

Now we clone xla, and clone and install Patchelf which is a jax dependency:

```
cd
git clone --depth 1 --branch rocm-jaxlib-v0.${JAX_VERSION} https://github.com/ROCm/xla.git
cd xla
export XLA_PATH=$PWD
cd ..
```

```
cd
git clone -b ${PATCHELF_VERSION} https://github.com/NixOS/patchelf.git
cd patchelf
./bootstrap.sh
./configure
make -j
make install
cd ..
rm -rf patchelf
```

Sanity check: 

```
which patchelf
echo $XLA_PATH
echo $ROCM_PATH
amdclang --version
echo $CLANG_COMPILER
echo $ROCM_VERSION_BAZEL
echo $JAX_PLATFORMS
```

If it all looks good, you can proceed to install jax and jaxlib:

```
cd
git clone --depth 1 --branch rocm-jaxlib-v0.${JAX_VERSION} https://github.com/ROCm/jax.git
cd jax
sed -i "s|gfx900,gfx906,gfx908,gfx90a,gfx940,gfx941,gfx942,gfx1030,gfx1100,gfx1200,gfx1201|$AMDGPU_GFXMODEL|g" .bazelrc
sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|g" .bazelrc

python3 build/build.py build --rocm_path=$ROCM_PATH \
                                         --bazel_options=--override_repository=xla=$XLA_PATH \
                                         --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                         --clang_path=$ROCM_PATH/lib/llvm/bin/clang \
                                         --rocm_version=$ROCM_VERSION_BAZEL \
                                         --use_clang=true \
                                         --wheels=jaxlib \
                                         --bazel_options=--jobs=128 \
                                         --bazel_startup_options=--host_jvm_args=-Xmx4g

pip3 install opt_einsum setuptools --no-deps
pip3 install dist/jax*.whl --force-reinstall
pip3 install . --no-deps --no-build-isolation --force-reinstall
```

Next we proceed and install jax-rocm-plugin and jax-rocm-pjrt:

```
cd
git clone  --depth 1 --branch rocm-jax-v0.${JAX_VERSION} https://github.com/ROCm/rocm-jax.git
cd rocm-jax/jax_rocm_plugin
sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|g" .bazelrc 

python3 build/build.py build --rocm_path=$ROCM_PATH \
                                         --bazel_options=--override_repository=xla=$XLA_PATH \
                                         --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                         --clang_path=$ROCM_PATH/lib/llvm/bin/clang \
                                         --rocm_version=$ROCM_VERSION_BAZEL \
                                         --use_clang=true \
                                         --wheels=jax-rocm-plugin,jax-rocm-pjrt \
                                         --bazel_options=--jobs=128 \
                                         --bazel_startup_options=--host_jvm_args=-Xmx4g

pip3 install dist/jax*.whl --force-reinstall
```

Sanity check:
```
python3 -c 'import jax; print(jax.devices())'
```

you should see something like:
```
[RocmDevice(id=0), RocmDevice(id=1), RocmDevice(id=2), RocmDevice(id=3)]
```

The next step is to install the Alphafold3 dependencies and Alphafold3 itself:
```
cd
git clone https://github.com/google-deepmind/alphafold3.git
cd alphafold3
# pin to a specific version for reproducibility
git checkout 3a09f04
sed -i '/^[[:space:]]*--hash=s/d' requirements.txt
```


Remove all the jax and nvidia requirements from requirements.txt (except jaxtyping and jax-triton) then:
```
pip3 install --no-cache-dir --no-build-isolation --no-deps -r requirements.txt --force-reinstall
pip3 install scikit_build_core --no-cache-dir --force-reinstall
pip3 install -vvv --no-cache-dir --no-deps --force-reinstall --upgrade .
pip3 install dm-haiku==0.0.16 --upgrade --no-deps --force-reinstall
pip3 install immutabledict --no-deps

build_data
```

Sanity check:
```
python3 -c 'import alphafold3;print(alphafold3.__file__)'
```

you should see no errors and a path that is in `alphafold3_env` (your current env):
```
/root/alphafold3_env/lib/python3.12/site-packages/alphafold3/__init__.py
```

Then we need to install HMMR (instructions from the alphafold3 [Dockerfile](https://github.com/google-deepmind/alphafold3/blob/main/docker/Dockerfile)):
```
mkdir /hmmer_build /hmmer ; \
    wget http://eddylab.org/software/hmmer/hmmer-3.4.tar.gz --directory-prefix /hmmer_build ; \
    (cd /hmmer_build && echo "ca70d94fd0cf271bd7063423aabb116d42de533117343a9b27a65c17ff06fbf3 hmmer-3.4.tar.gz" | sha256sum --check) && \
    (cd /hmmer_build && tar zxf hmmer-3.4.tar.gz && rm hmmer-3.4.tar.gz)

cp docker/jackhmmer_seq_limit.patch /hmmer_build/
(cd /hmmer_build && patch -p0 < jackhmmer_seq_limit.patch)

(cd /hmmer_build/hmmer-3.4 && ./configure --prefix /hmmer) ; \
    (cd /hmmer_build/hmmer-3.4 && make -j) ; \
    (cd /hmmer_build/hmmer-3.4 && make install) ; \
    (cd /hmmer_build/hmmer-3.4/easel && make install) ; \
    rm -R /hmmer_build
    cd
```

Sanity check:
```
which jackhmmer
```

you should see:
```
/hmmer/bin/jackhmmer
```

Now we need to make the dummy parameters:
```
python3 generate_dummy_params.py
```

if it is working you will see this message:
```
Parsing 405 parameters
```
and it will output a file called `random_weights.bin.zst`

Then do:
```
cd
mkdir af_models
mv random_weights.bin.zst af_models/random_weights.bin.zst
```

Before we run, we have to apply several patches:

1. comment line 854, 855 and 856 of `run_alphafold.py` and replace with (as also noted [here](https://www.linkedin.com/pulse/getting-alphafold-3-run-amd-gpus-owain-kenway-egite/) ):
```
compute_capability=642
```

2. patch this file: `/root/alphafold3_env/lib/python3.12/site-packages/tokamax/_src/triton.py`
with this (and comment the very last line):
```
cc = device.compute_capability
if isinstance(cc, str):  # ROCm case like "gfx942"
    return False
return float(cc) >= 8.0
```

3. patch this file `/root/alphafold3_env/lib/python3.12/site-packages/tokamax/_src/precision.py` like this at line 131:
```
#    elif float(compute_capability) < 8.0:
#      backend = "gpu_old"
    else:
       try:
          cc = float(compute_capability)
          if cc < 8.0:
             backend = "gpu_old"
       except (TypeError, ValueError):
         pass
```

4. comment line 565 and 566 here `/root/alphafold3_env/lib/python3.12/site-packages/tokamax/_src/ops/attention/pallas_triton_flash_attention.py`:
```
    #if not triton_lib.has_triton_support():
    #  raise NotImplementedError("Triton not supported on this platform.")
```

OK, now we can finally run Alphafold3:

```
export XLA_FLAGS="--xla_gpu_enable_triton_gemm=false"
export XLA_PYTHON_CLIENT_PREALLOCATE=true
export XLA_CLIENT_MEM_FRACTION=0.95
cd /root/alphafold3

python3 ./run_alphafold.py    --model_dir=/root/af_models    --db_dir=/root/public_databases    --output_dir=/root/af_output --json_path=/root/af_input/input.json --run_data_pipeline=False --run_inference=True --num_recycles=3 --num_diffusion_samples=1
```

If you get errors during the inference but the data pipeline step was successful, you can run bypassing the data pipeline and just do inference with:
```
python3 ./run_alphafold.py    --model_dir=/root/af_models    --db_dir=/root/public_databases    --output_dir=/root/af_output --json_path=/root/af_output/104-P55854/104-P55854_data.json --run_data_pipeline=False --run_inference=True --num_recycles=3 --num_diffusion_samples=1
```
note that above we changed the `--json_path`.

If the run is successful you should see something like this (assuming the data pipeline step has been completed and you are running only inference):
```
(alphafold3_env) root@9f5b1d1dc572:~/alphafold3# python3 ./run_alphafold.py    --model_dir=/root/af_models    --db_dir=/root/public_databases    --out
put_dir=/root/af_output --json_path=/root/af_output/104-P55854/104-P55854_data.json --run_data_pipeline=False --run_inference=True --num_recycles=3 --
num_diffusion_samples=1
2026-01-22 21:41:23.467578: E external/local_xla/xla/stream_executor/cuda/cuda_platform.cc:51] failed call to cuInit: INTERNAL: CUDA error: Failed call to cuInit: UNKNOWN ERROR (303)
I0122 21:41:23.476852 140260140290176 __init__.py:96] No ROCm wheel installation found

Running AlphaFold 3. Please note that standard AlphaFold 3 model parameters are
only available under terms of use provided at
https://github.com/google-deepmind/alphafold3/blob/main/WEIGHTS_TERMS_OF_USE.md.
If you do not agree to these terms and are using AlphaFold 3 derived model
parameters, cancel execution of AlphaFold 3 inference with CTRL-C, and do not
use the model parameters.

Found local devices: [RocmDevice(id=0), RocmDevice(id=1), RocmDevice(id=2), RocmDevice(id=3)], using device 0: rocm:0
Building model from scratch...
Checking that model parameters can be loaded...

Running fold job 104-P55854...
Output will be written in /root/af_output/104-P55854_20260122_214159 since /root/af_output/104-P55854 is non-empty.
Skipping data pipeline...
Writing model input JSON to /root/af_output/104-P55854_20260122_214159/104-P55854_data.json
Predicting 3D structure for 104-P55854 with 2 seed(s)...
Featurising data with 2 seed(s)...
Featurising data with seed 1.
I0122 21:42:13.525099 140260140290176 pipeline.py:173] processing 104-P55854, random_seed=1
I0122 21:42:13.536814 140260140290176 pipeline.py:266] Calculating bucket size for input with 103 tokens.
I0122 21:42:13.537149 140260140290176 pipeline.py:272] Got bucket size 256 for input with 103 tokens, resulting in 153 padded tokens.
Featurising data with seed 1 took 1.77 seconds.
Featurising data with seed 2.
I0122 21:42:15.298668 140260140290176 pipeline.py:173] processing 104-P55854, random_seed=2
I0122 21:42:15.307167 140260140290176 pipeline.py:266] Calculating bucket size for input with 103 tokens.
I0122 21:42:15.307270 140260140290176 pipeline.py:272] Got bucket size 256 for input with 103 tokens, resulting in 153 padded tokens.
Featurising data with seed 2 took 1.09 seconds.
Featurising data with 2 seed(s) took 16.68 seconds.
Running model inference and extracting output structure samples with 2 seed(s)...
Running model inference with seed 1...
Running model inference with seed 1 took 56.64 seconds.
Extracting inference results with seed 1...
Extracting 1 inference samples with seed 1 took 0.02 seconds.
Running model inference with seed 2...
Running model inference with seed 2 took 4.00 seconds.
Extracting inference results with seed 2...
Extracting 1 inference samples with seed 2 took 0.02 seconds.
Running model inference and extracting output structures with 2 seed(s) took 60.68 seconds.
Writing outputs with 2 seed(s)...
Fold job 104-P55854 done, output written to /root/af_output/104-P55854_20260122_214159

Done running 1 fold jobs.
```
