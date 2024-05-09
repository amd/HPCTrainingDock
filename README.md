### Docker Training Container Setup Instructions
This version of the Training Container is for workstations and data center GPUs. Specifically, it
is tested on Radeon 6800XT graphics card and MI200 series and MI300A data center GPUs.

##Training Docker Container Build Steps

These instructions will setup a container on `localhost` and assume that Docker is installed, your userid is part of the Docker group and you can issue Docker commands without `sudo`. If you need to use sudo, you will need to modify the command below to look for Docker images that start with ***root*** instead of a userid (such as amdtrain).


# 1.  Building the Four Images of the Container 
This container is set up to use Ubuntu 22.04 as OS, and will build four different images called `rocm`, `omnitrace`,  `omniperf` and `training`. 
The version of ROCm is 6.1.0, and several compilers and other dependencies will be built as part of the images setup. First, clone this repo and go into the folder where the Docker build script lives: 

```bash
git clone --recursive git@github.com:AMD/HPCTrainingDock.git
cd HPCTrainingDock
```

To build the four images run the following command (note that `<admin>` is set to `admin` by default but the password **must** be specified):
```
   ./build-docker.sh --rocm-versions 6.1.0 --distro-versions 22.04 --admin-username <admin> --admin-password <password>
```

You can build for many other recent rocm-versions if you prefer. To show more docker build output, add this option to the build command above:

```bash
--output-verbosity 
```
***NOTE***: The docker build script will try and detect the GPU on the system you are building on, but you can also have it build for a different GPU model than your local GPU, by specifying the target architecture with the `--amdgpu-gfxmodel` option. For instance, to build for the MI200 series data center GPU we would provide this:

```bash
--amdgpu-gfxmodel=gfx90a
```
For MI300 series, the value to specify is `gfx942`. Note that you can also build the images on a machine that does not have any GPU hardware (such as your laptop) provided you specify a target hardwarw with the flag above.

Omnitrace will by default download a pre-built version. You can also build from source,
which is useful if the right version of omnitrace is not available as pre-build. To build omnitrace from source, append the following to the build command above:

```
--omnitrace-build-from-source
```

Building extra compilers takes a long time. A cached option can be used  to shorten subsequent build times, just append these options to the build command above:

```bash
--build-gcc-option 
--build-aomp-option 
```

The first one builds the latest version of `gcc` for offloading, the second builds the latest version of `LLVM` for offloading. Once a version of these compilers is built, they can be tarred up and placed in the following directory structure:

```bash
CacheFiles/:
  ubuntu-22.04-rocm-5.6.0
     aomp_18.0-1.tgz
      gcc-13.2.0.tgz
```

Then, the cached versions can be installed specifying:

```bash
---use-cached-apps 
```
The above flag will allow you to use pre-built `gcc` and `aomp` located in `CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}`.

# 2. Previewing the Images
 
Assuming that the build of the images has been successful, you can see details on the images that have been built by doing

```bash
 docker images 
```

which will have an output similar to this one:

```bash
 REPOSITORY           TAG                                    IMAGE ID       CREATED          SIZE
 training             latest                                 fe63d37c10f4   40 minutes ago   27GB
 <admin>/omniperf    release-base-ubuntu-22.04-rocm-6.1.0   4ecc6b7a80f2   44 minutes ago   18.7GB
 <admin>/omnitrace   release-base-ubuntu-22.04-rocm-6.1.0   37a84bef709a   47 minutes ago   16.1GB
 <admin>/rocm        release-base-ubuntu-22.04-rocm-6.1.0   bd8ca598d8a0   48 minutes ago   16.1GB
```

# 3. Starting the Container

To start the container, run:
```bash
docker run -it --device=/dev/kfd --device=/dev/dri --group-add video -p 2222:22 --detach --name Training --rm -v /home/amdtrain/Class/training/hostdir:/hostdir --security-opt seccomp=unconfined docker.io/library/training
```
***NOTE***: if you are testing the container on a machine that does not have a GPU (such as your laptop), you need to remove the `--device=/dev/kfd` option from the above command. You can check what containers are running by running `docker ps`.

# 4. Accessing the Container

It is necessary to wait a few seconds for the container to start up, before you will be allowed to login.
After the container started, you can log in by doing:

```bash
ssh <admin>@localhost -p 2222
```
and then enter the password `<password>` specified when building the images. If you get the message below, wait a little longer, the container is still starting up:

```bash
kex_exchange_identification: read: Connection reset by peer
Connection reset by 127.0.0.1 port 2222
```
Once you are in, you can startup slurm with the manage script `manage.sh` located in the `bin` directory. To transfer files from your local system to the container, run: 

```bash
rsync -avz -e "ssh -p 2222" <file> <admin>@localhost:<path/to/destination>
```

You can check that the training exercies run in the container by running the `runTests.sh` script: this will execute the following commands:

```bash
rm -rf HPCTrainingExamples && \
git clone https://github.com/amd/HPCTrainingExamples && \
cd HPCTrainingExamples/tests && \
mkdir build && cd build && \
cmake .. && make test
```
                                                                      
# 5. Kill the Container and Cleanup

To exit the container, just do:
```bash
exit
```
Note that the container will still be running in the background. To kill it, do:

```bash
docker kill Training
```
To clean up your system, run:
```bash
docker rmi -f $(docker images -q)
docker system prune -a
```
