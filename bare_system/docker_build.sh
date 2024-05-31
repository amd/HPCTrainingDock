#!/bin/bash

docker build --build-arg DISTRO=ubuntu --build-arg DISTRO_VERSION=22.04 -t bare .
