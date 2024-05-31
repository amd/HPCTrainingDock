#!/bin/bash

set -v

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `


docker build --no-cache --build-arg DISTRO=${DISTRO} --build-arg DISTRO_VERSION=${DISTRO_VERSION} -t bare .

docker run -it --device=/dev/kfd --device=/dev/dri --group-add video --group-add render --group-add renderalt -p 2222:22 --name Bare  --rm -v /home/bobrobey/Class/training/hostdir:/hostdir --security-opt seccomp=unconfined bare
