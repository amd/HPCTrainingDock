#!/usr/bin/env -S python3

import os
import re
import subprocess as sp


def get_driver_version():
    amdgpu = sp.run(["/usr/sbin/modinfo","amdgpu"], capture_output=True, text=True)
    lines=amdgpu.stdout.split("\n")
    # 
    # version will be in lines[1], so pull out the version number
    rver = r"(\d+\.\d+\.\d+)$"
    driver_version=re.search(rver,lines[1])[0]
    return driver_version


def get_kernel_version():
    kernel=sp.run(["/usr/bin/uname","-r"], capture_output=True, text=True)
    return kernel.stdout.rstrip()

def get_distro_version():
    rver = r"\t(.*?)$"
    dver=sp.run(["/usr/bin/lsb_release","-d"], capture_output=True, text=True)
    distro_ver=re.search(rver,dver.stdout.rstrip())[0].lstrip()
    return distro_ver

def get_gpu_version():
    # don't run with the obvious pipe, as python PIPE interface is beyond clunky
    gpver=sp.run(["/usr/bin/rocm_agent_enumerator"], capture_output=True, text=True)
    # instead use a workaround to determine unique agents
    lines = [ st.rstrip() for st in gpver.stdout.split("\n")]
    _t_=lines.pop() # discard _t_
    gpu_version=list(set(lines))[0]
    return gpu_version


    