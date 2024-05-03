This version of the Training Container is for workstations and data center GPUs. Specifically, it
is tested on Radeon 6800XT graphics card and MI200 series and MI300A data center GPUs.i

Training Docker Container build steps

on user amdtrain on localhost.

This assumes your userid is part of the Docker group and you can issue Docker commands without sudo.

If you need to use sudo, you will need to modify the command below to look for Docker images that start with "root" instead of a userid (such as amdtrain).


1) Build the four levels of the Container with Ubuntu 22.04, Rocm 6.1.0, Omnitrace, Omniperf and extra compilers and packages

```
git clone --recursive git@github.com:AMD/HPCTrainingDock.git
cd TrainingDock
```

For standard builds with the admin username settings of your choice for the build
```
   ./build-docker.sh --rocm-versions 6.1.0 --distro-versions 22.04 --admin_username admin --admin_password [PASSWORD]
```

You can build for many other recent rocm-versions if you prefer.


Options that might be useful for the build are below. The first is an option
to show more docker build output

```
--output-verbosity -- flag for more verbose output during the build
```
Build for a specific GPU model. The docker build script will try and detect the GPU on the system you are
building on, but you can also have it build for a different GPU model than your local GPU. This option
specifies building for the MI200 series data center GPU.

```
--gfx-model gfx90a
```

Omnitrace will by default download a pre-built version. You can also build from source,
which is useful if the right version of omnitrace is not available as pre-build.

```
--omnitrace-build-from-source -- flag to build omnitrace from source instead of using pre-built versions
```
Building extra compilers. These take a long time to build. A cached option can be used
to shorten subsequent build times.

```
--build-gcc-option -- flag to build the latest version of gcc with offloading
--build-aomp-option -- flag to build the latest version of LLVM for offloading
```

Once a version of these compilers is built, they can be tarred up and placed in the following directory structure.

```
CacheFiles/:
  ubuntu-22.04-rocm-5.6.0
     aomp_18.0-1.tgz
      gcc-13.2.0.tgz
```

Then the cached versions can be installed with:

```
---use-cached-apps -- flag to use pre-built gcc and aomp located in CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} directory
```

 2) Output
 
 
 sudo docker images | head
 REPOSITORY           TAG                                    IMAGE ID       CREATED          SIZE
 training             latest                                 fe63d37c10f4   40 minutes ago   27GB
 amdtrain/omniperf    release-base-ubuntu-22.04-rocm-5.6.0   4ecc6b7a80f2   44 minutes ago   18.7GB
 amdtrain/omnitrace   release-base-ubuntu-22.04-rocm-5.6.0   37a84bef709a   47 minutes ago   16.1GB
 amdtrain/rocm        release-base-ubuntu-22.04-rocm-5.6.0   bd8ca598d8a0   48 minutes ago   16.1GB

[omnitrace][116] /proc/sys/kernel/perf_event_paranoid has a value of 3. Disabling PAPI (requires a value <= 2)...
[omnitrace][116] In order to enable PAPI support, run 'echo N | sudo tee /proc/sys/kernel/perf_event_paranoid' where                   N is <= 2

echo N | sudo tee /proc/sys/kernel/perf_event_paranoid' where N is <= 2

3) start container

```
docker run -it --device=/dev/kfd --device=/dev/dri --group-add video -p 2222:22 --detach --name Training --rm -v /home/amdtrain/Class/training/hostdir:/hostdir --security-opt seccomp=unconfined docker.io/library/training
```

4) Test Container

login -- need to wait for container to start before logging in

```
ssh <admin_username>@localhost -p 2222
```

If you get the message below, wait a little longer. It is still starting up.

   kex_exchange_identification: read: Connection reset by peer
   Connection reset by 127.0.0.1 port 2222


First startup slurm with the manage script

```
./manage.sh
```

To transfer all the files from the "TransferFiles" directory over to the <admin_username> account

```
rsync -avz -e "ssh -p 2222" ../TransferFiles/ <admin_username>@localhost:.
```

To check all the test cases, run the ./runTests.sh script in the <admin_username> account or at ../examples/TestExamples/runTests.sh.

```
rm -rf HPCTrainingExamples && \
git clone https://github.com/amd/HPCTrainingExamples && \
cd HPCTrainingExamples/tests && \
mkdir build && cd build && \
cmake .. && make test
```
                                                                      
5) Cleanup

```
exit
```

```
docker kill Training

docker rmi -f $(docker images -q)
docker system prune -a
```
