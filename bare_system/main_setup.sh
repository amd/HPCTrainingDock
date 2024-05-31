#!/bin/bash

# docker build --build-arg DISTRO=ubuntu --build-arg DISTRO_VERSION=22.04 -t bare .
# docker run -it  --shm-size=256m --device=/dev/kfd --device=/dev/dri --group-add video  -p 2222:22 --name Bare  --rm -v /home/bobrobey/Class/training/hostdir:/hostdir --security-opt seccomp=unconfined bare

ROCM_VERSION=6.1.0

#sudo apt-get update
#sudo apt-get install git

#git clone https://github.com/AMD/HPCTrainingDock

HPCTrainingDock/rocm/sources/scripts/baseospackages_setup.sh

HPCTrainingDock/rocm/sources/scripts/rocm_setup.sh --rocm-version ${ROCM_VERSION}
