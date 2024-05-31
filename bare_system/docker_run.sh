#!/bin/bash

docker run -it  --shm-size=256m --device=/dev/kfd --device=/dev/dri --group-add video  -p 2222:22 --name Bare  --rm -v /home/bobrobey/Class/training/hostdir:/hostdir --security-opt seccomp=unconfined bare
