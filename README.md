# 1. Synopsis
Welcome to AMD's model installation repo!

Here, you will have the option to build and run a Docker container on which you will find a rich variety of AMD GPU software for you to test and experiment with.
Alternative to the Docker container, we also provide the option to install the aforementioned AMD GPU software on a bare system, through a series of installation scripts. Currently, we are only supporting an Ubuntu operating system (OS), but work is underway to add support for other operating systems as well. Note that we provide the option to test the bare system install before you deploy it, using a Docker container. Details are provided next.

This version of the model installation is for workstations and data center GPUs. Specifically, it has been tested on Radeon 6800XT graphics card and MI200 series and MI300A data center GPUs.

# 2. Model Installation Setup Instructions
We currently provide two options for the setup of the software: a Docker container, and a bare system install. The latter can be tested with a Docker container before deployment.  

## 2.1 Training Docker Container Build Steps

These instructions will setup a container on `localhost` and assume that:
1. Docker is installed.
2. Your userid is part of the Docker group.
3. You can issue Docker commands without `sudo`.
 
<!-- If you need to use `sudo`, you will need to modify the command below to look for Docker images that start with ***root*** instead of a userid (such as amdtrain).-->

### 2.1.1  Building the Four Images of the Container 
The Docker container is set up to use Ubuntu 22.04 as OS, and will build four different images called `rocm`, `omnitrace`,  `omniperf` and `training`. 
The version of ROCm is 6.1.0, and several compilers and other dependencies will be built as part of the images setup (more on this later). First, clone this repo and go into the folder where the Docker build script lives: 

```bash
git clone --recursive git@github.com:amd/HPCTrainingDock.git
cd HPCTrainingDock
```

To build the four images, run the following command (note that `<admin>` is set to `admin` by default but the password **must** be specified, otherwise you will get an error from the build script):

```
   ./build-docker.sh --rocm-versions 6.1.0 --distro-versions 22.04 --admin-username <admin> --admin-password <password>
```

You can build for many other recent ROCm versions if you prefer. To show more docker build output, add this option to the build command above:

```bash
--output-verbosity 
```

**NOTE**: The docker build script will try and detect the GPU on the system you are building on, but you can also have it build for a different GPU model than your local GPU, by specifying the target architecture with the `--amdgpu-gfxmodel` option. For instance, to build for the MI200 series data center GPU we would provide this:

```bash
--amdgpu-gfxmodel=gfx90a
```

For the MI200 series, the value to specify is `gfx90a`, for the MI300 series, the value is `gfx942`. Note that you can also build the images on a machine that does not have any GPU hardware (such as your laptop) provided you specify a target hardware with the flag above.

Omnitrace will by default download a pre-built version. You can also build from source,
which is useful if the right version of omnitrace is not available as pre-build. To build omnitrace from source, append the following to the build command above:

```
--omnitrace-build-from-source
```

Building extra compilers takes a long time, but a cached option can be used  to shorten subsequent build times, just append these options to the build command above:

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

### 2.1.2 Previewing the Images
 
Assuming that the build of the images has been successful, you can see details on the images that have been built by doing:

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
You can also display the operating system running on the container by doing:

```bash
cat ../../etc/os-release
```

### 2.1.3 Starting the Container

To start the container, run:

```bash
docker run -it --device=/dev/kfd --device=/dev/dri --group-add video -p 2222:22 --detach --name Training --rm -v /home/amdtrain/Class/training/hostdir:/hostdir --security-opt seccomp=unconfined docker.io/library/training
```

**NOTE**: if you are testing the container on a machine that does not have a GPU (such as your laptop), you need to remove the `--device=/dev/kfd` option from the above command. 

You can check what containers are running by running `docker ps`.

### 2.1.4 Accessing the Container

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

### 2.15 Killing the Container and Cleaning Up your System

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

## 2.2 Training Enviroment Install on Bare System

In this section, we provide instrucitons on how to install AMD GPU software on a bare system. This is achieved with the same set of scripts used for the setup of the Docker container, except that instead of being called from within a Dockerfile, they are called from a top level script that does not require the use of Docker. There is however a script called `test_install.sh` that will run a Docker container to test the bare system install. 

To test the bare system install, do:

```bash
git clone --recursive git@github.com:amd/HPCTrainingDock.git && \
cd HPCTrainingDock && \
./bare_sysem/test_install.sh --rocm-version <rocm-version>
```

The above command sequence will clone this repo and then execute the `test_install.sh` script. This script calls a the `main_install.sh` which is what you would execute to perform the actual installation on your system. The `test_install.sh` sets up a Docker container where you can test the installation of the software before proceeding to deploy it on your actual system by running `main_install.sh`. The `test_install.sh` script automatically runs the Docker container after it is built, and you can inspect it as `student`.


If you are satisfied with the test installation, you can proceed with the actual installation on your systemr by doing:

```bash
git clone --recursive git@github.com:amd/HPCTrainingDock.git && \
cd HPCTrainingDock && \
./bare_system/main_install.sh --rocm-version <rocm-version>
```

The above command will execute the `main_install.sh` script on your system that will proceed with the installation for you. Note that you need to be able to run `sudo` on your system for things to work. The `main_install.sh` script calls a series of other scripts to install the software (these are given several runtime flags that are not reported here for simplicity):

```bash
 // install linux software such as cmake and system compilers
rocm/sources/scripts/baseospackages_setup.sh

// install lmod and create the modulepath
rocm/sources/scripts/lmod_setup.sh 

// install ROCm and create ROCm module
rocm/sources/scripts/rocm_setup.sh 

// install OpenMPI and create OpenMPI module
rocm/sources/scripts/openmpi_setup.sh 

// install MVAPICH2 and create MVAPICH2 module
rocm/sources/scripts/mvapich2_setup.sh 

// install Miniconda3 and create Miniconda3 module
omnitrace/sources/scripts/miniconda3_setup.sh 

// install Omnitrace and create Omnitrace module
omnitrace/sources/scripts/omnitrace_setup.sh 

// install Grafana (needed for Omniperf)
omniperf/sources/scripts/grafana_setup.sh

// install Omniperf and create Omniperf module
omniperf/sources/scripts/omniperf_setup.sh 

// install clang/14  clang/15  gcc/11  gcc/12  gcc/13 and create modules
training/sources/scripts/compiler_setup.sh

// install liblapack and libopenblas
training/sources/scripts/apps_setup_basic.sh

// install CuPy and create CuPy module
training/sources/scripts/cupy_setup.sh 

// install PyTorch and create PyTorch module
training/sources/scripts/pytorch_setup.sh 

// install additional libs and apps such as valgrind, boost, parmetis, openssl, etc.
training/sources/scripts/apps_setup.sh

```

**NOTE**: as mentioned before, those scripts are the same used by the Docker containers (either the actual Training Docker Container or the Test Docker Container run by `test_install.sh`). The reason why the script work for both installations (bare system and Docker) is because the commands are executed at the `sudo` level. Since Docker is already at the `sudo` level, the instructions in the scripts work in both contexts.



# 3. Inspecting the Model Installation Environment

The training environemtn comes with a variety of modules installed, which their necessary dependencies. To inspect the modules available, run `module avail`, which will show you this output:

```bash
---------------------------------------------------------------------------------------- /etc/lmod/modules/Linux -----------------------------------------------------------------------------------------
   clang/base    clang/14    clang/15 (D)    gcc/base    gcc/11 (D)    gcc/12    gcc/13    miniconda3/23.11.0

----------------------------------------------------------------------------------------- /etc/lmod/modules/ROCm -----------------------------------------------------------------------------------------
   amdclang/17.0-6.1.0    hipfort/6.1.0    opencl/6.1.0    rocm/6.1.0

------------------------------------------------------------------------------------- /etc/lmod/modules/ROCmPlus-MPI -------------------------------------------------------------------------------------
   mvapich2/2.3.7    openmpi/5.0.3

------------------------------------------------------------------------------ /etc/lmod/modules/ROCmPlus-AMDResearchTools -------------------------------------------------------------------------------
   omniperf/2.0.0    omnitrace/1.11.2

------------------------------------------------------------------------------------- /etc/lmod/modules/ROCmPlus-AI --------------------------------------------------------------------------------------
   cupy/13.0.0b1    pytorch/2.2

------------------------------------------------------------------------------------ /usr/share/lmod/lmod/modulefiles ------------------------------------------------------------------------------------
   Core/lmod/6.6    Core/settarg/6.6
```

In the above display, (D) stands for "default". The modules are searched in the `MODULEPATH` environment variable, which is set during the images creation. Below, we report details on most of the modules displayed above. Note that the same information reported here can be displayed by using the command:
```bash
module show <module>
``` 
where `<module>` is the module you want to inspect.

Module name: `clang/base`

Modulefile location: `/etc/lmod/modules/Linux/clang`

Modulefile content:
```bash
 whatis("Clang (LLVM) Base version 14 compiler")
 setenv("CC", "/usr/bin/clang")
 setenv("CXX", "/usr/bin/clang++")
 setenv("F77", "/usr/bin/flang")
 setenv("F90", "/usr/bin/flang")
 setenv("FC", "/usr/bin/flang")
 append_path("INCLUDE_PATH", "/usr/include")
 prepend_path("LIBRARY_PATH", "/usr/lib/llvm-14/lib")
 prepend_path("LD_LIBRARY_PATH", "/usr/lib/llvm-14/lib")
 family("compiler")
```

Module name: `clang/15`

Modulefile location: `/etc/lmod/modules/Linux/clang`

Modulefile content:
```bash
 whatis("Clang (LLVM) Version 15 compiler")
 setenv("CC", "/usr/bin/clang-15")
 setenv("CXX", "/usr/bin/clang++-15")
 setenv("F77", "/usr/bin/flang-15")
 setenv("F90", "/usr/bin/flang-15")
 setenv("FC", "/usr/bin/flang-15")
 append_path("INCLUDE_PATH", "/usr/include")
 prepend_path("LIBRARY_PATH", "/usr/lib/llvm-15/lib")
 prepend_path("LD_LIBRARY_PATH", "/usr/lib/llvm-15/lib")
 family("compiler")
```

Module name: `gcc/base`

Modulefile location: `/etc/lmod/modules/Linux/gcc`

Modulefile content: 
```bash
 whatis("GCC Version base version (11) compiler")
 setenv("CC", "/usr/bin/gcc")
 setenv("CXX", "/usr/bin/g++")
 setenv("F77", "/usr/bin/gfortran")
 setenv("F90", "/usr/bin/gfortran")
 setenv("FC", "/usr/bin/gfortran")
 append_path("INCLUDE_PATH", "/usr/include")
 prepend_path("LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/11")
 prepend_path("LD_LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/11")
 family("compiler")
```

Module name: `gccc/11`

Modulefile location: `/etc/lmod/modules/Linux/gcc`

Modulefile content:
```bash
 whatis("GCC Version 11 compiler")
 setenv("CC", "/usr/bin/gcc-11")
 setenv("CXX", "/usr/bin/g++-11")
 setenv("F77", "/usr/bin/gfortran-11")
 setenv("F90", "/usr/bin/gfortran-11")
 setenv("FC", "/usr/bin/gfortran-11")
 append_path("INCLUDE_PATH", "/usr/include")
 prepend_path("LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/11")
 prepend_path("LD_LIBRARY_PATH", "/usr/lib/gcc/x86_64-linux-gnu/11")
 family("compiler")
```

Module name: `miniconda/23.11.0`

Modulefile location: `/etc/lmod/modules/Linux/miniconda3`

Modulefile content:
```bash
 local root = "/opt/miniconda3"
setenv("ANACONDA3ROOT", root)
setenv("PYTHONROOT", root)
local python_version = capture(root .. "/bin/python -V | awk '{print $2}'")
local conda_version = capture(root .. "/bin/conda --version | awk '{print $2}'")
function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end
conda_version = trim(conda_version)
help([[ Loads the Miniconda environment supporting Community-Collections. ]])
whatis("Sets the environment to use the Community-Collections Miniconda.")
local myShell = myShellName()
if (myShell == "bash") then
  cmd = "source " .. root .. "/etc/profile.d/conda.sh"
else
  cmd = "source " .. root .. "/etc/profile.d/conda.csh"
end
execute{cmd=cmd, modeA = {"load"}}
prepend_path("PATH", "/opt/miniconda3/bin")

load("rocm/6.1.0")
```

Module name: `amdclang/17.0-6.1.0`

Modulefile location: `/etc/lmod/modules/ROCm/amdclang`

Modulefile content:
```bash
whatis("Name: AMDCLANG")
whatis("Version: 6.1.0")
whatis("Category: AMD")
whatis("AMDCLANG")

local base = "/opt/rocm-6.1.0/llvm"
local mbase = "/etc/lmod/modules/ROCm/amdclang"

setenv("CC", pathJoin(base, "bin/amdclang"))
setenv("CXX", pathJoin(base, "bin/amdclang++"))
setenv("FC", pathJoin(base, "bin/amdflang"))
setenv("F77", pathJoin(base, "bin/amdflang"))
setenv("F90", pathJoin(base, "bin/amdflang"))
prepend_path("PATH", pathJoin(base, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
prepend_path("LD_RUN_PATH", pathJoin(base, "lib"))
prepend_path("CPATH", pathJoin(base, "include"))
load("rocm/6.1.0")
family("compiler")
```

Module name: `hipfort/6.1.0`

Modulefile location: `/etc/lmod/modules/ROCm/hipfort`

Modulefile content:
```bash
whatis("Name: ROCm HIPFort")
whatis("Version: 6.1.0")

setenv("HIPFORT_HOME", "/opt/rocm-6.1.0")
append_path("LD_LIBRARY_PATH", "/opt/rocm-6.1.0/lib")
setenv("LIBS", "-L/opt/rocm-6.1.0/lib -lhipfort-amdgcn.a")
load("rocm/6.1.0")
```

Module name: `opencl/6.1.0`

Modulefile location: `/etc/lmod/modules/ROCm/opencl`

Modulefile content:
```bash
whatis("Name: ROCm OpenCL")
whatis("Version: 6.1.0")
whatis("Category: AMD")
whatis("ROCm OpenCL")

local base = "/opt/rocm-6.1.0/opencl"
local mbase = " /etc/lmod/modules/ROCm/opencl"

prepend_path("PATH", pathJoin(base, "bin"))
family("OpenCL")
```

Module name: `rocm/6.1.0`

Modulefile location: `/etc/lmod/modules/ROCm/rocm`

Modulefile content: 
```bash
whatis("Name: ROCm")
whatis("Version: 6.1.0")
whatis("Category: AMD")
whatis("ROCm")

local base = "/opt/rocm-6.1.0/"
local mbase = " /etc/lmod/modules/ROCm/rocm"

prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib64"))
prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
prepend_path("CPATH", pathJoin(base, "include"))
prepend_path("PATH", pathJoin(base, "bin"))
prepend_path("INCLUDE", pathJoin(base, "include"))
setenv("ROCM_PATH", base)
family("GPUSDK")
```

Module name: `mvapich2/2.3.7 `

Modulefile location: `/etc/lmod/modules/ROCmPlus-MPI/mvapich2`

Modulefile content: 
```bash
whatis("Name: GPU-aware mvapich")
whatis("Version: 2.3.7")
whatis("Description: An open source Message Passing Interface implementation")
whatis(" This is a GPU-aware version of Mvapich")

local base = "/opt/rocmplus-6.1.0/mvapich2/gdr/2.3.7/no-mcast/no-openacc/rocm5.1/mofed5.0/mpirun/gnu10.3.1"
local mbase = "/etc/lmod/modules/ROCmPlus-MPI"

prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
prepend_path("C_INCLUDE_PATH",pathJoin(base, "include"))
prepend_path("CPLUS_INCLUDE_PATH",pathJoin(base, "include"))
prepend_path("PATH",pathJoin(base, "bin"))
load("rocm/6.1.0")
family("MPI")
```

Module name: `openmpi/5.0.3`

Modulefile location: `/etc/lmod/modules/ROCmPlus-MPI/openmpi`

Modulefile content:
```bash
whatis("Name: GPU-aware openmpi")
whatis("Version: 5.0.3")
whatis("Description: An open source Message Passing Interface implementation")
whatis(" This is a GPU-Aware version of OpenMPI")
whatis("URL: https://github.com/open-mpi/ompi.git")

local base = "/opt/rocmplus-6.1.0/openmpi"

prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
prepend_path("PATH", pathJoin(base, "bin"))
load("rocm/6.1.0")
family("MPI")
```

Module name: `omniperf/2.0.0`

Modulefile location: `/etc/lmod/modules/ROCmPlus-AMDResearchTools/omniperf`

Modulefile content:
```bash 
local help_message = [[

Omniperf is an open-source performance analysis tool for profiling
machine learning/HPC workloads running on AMD MI GPUs.

Version 2.0.0
]]

help(help_message,"\n")

whatis("Name: omniperf")
whatis("Version: 2.0.0")
whatis("Keywords: Profiling, Performance, GPU")
whatis("Description: tool for GPU performance profiling")
whatis("URL: https://github.com/AMDResearch/omniperf")

-- Export environmental variables
local topDir="/opt/rocmplus-6.1.0/omniperf-2.0.0"
local binDir="/opt/rocmplus-6.1.0/omniperf-2.0.0/bin"
local shareDir="/opt/rocmplus-6.1.0/omniperf-2.0.0/share"
local pythonDeps="/opt/rocmplus-6.1.0/omniperf-2.0.0/python-libs"
local roofline="/opt/rocmplus-6.1.0/omniperf-2.0.0/bin/utils/rooflines/roofline-ubuntu20_04-mi200-rocm5"

setenv("OMNIPERF_DIR",topDir)
setenv("OMNIPERF_BIN",binDir)
setenv("OMNIPERF_SHARE",shareDir)
setenv("ROOFLINE_BIN",roofline)

-- Update relevant PATH variables
prepend_path("PATH",binDir)
if ( pythonDeps  ~= "" ) then
   prepend_path("PYTHONPATH",pythonDeps)
end

-- Site-specific additions
-- depends_on "python"
-- depends_on "rocm"
prereq(atleast("rocm","6.1.0"))
--  prereq("mongodb-tools")
local home = os.getenv("HOME")
setenv("MPLCONFIGDIR",pathJoin(home,".matplotlib"))
```

Module name: `omnitrace/1.11.2`

Modulefile location: `/etc/lmod/modules/ROCmPlus-AMDResearchTools/omnitrace`

Modulefile content:
```bash
whatis("Name: omnitrace")
whatis("Version: 1.11.2")
whatis("Category: AMD")
whatis("omnitrace")

local base = "/opt/rocmplus-6.1.0/omnitrace/"

prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
prepend_path("CPATH", pathJoin(base, "include"))
prepend_path("PATH", pathJoin(base, "bin"))
prepend_path("INCLUDE", pathJoin(base, "include"))
setenv("OMNITRACE_PATH", base)
load("rocm/6.1.0")
setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
```

Module name: `cupy/13.0.0b1`

Modulefile location: `/etc/lmod/modules/ROCmPlus-AI/cupy`

Modulefile content:
```bash
whatis("HIP version of cuPY or hipPY")
load("rocm/6.1.0")
prepend_path("PYTHONPATH","/opt/rocmplus-6.1.0/cupy")
```

Module name: `pytorch/2.2`

Modulefile location: `/etc/lmod/modules/ROCmPlus-AI/pytorch`

Modulefile content:
```bash
whatis("HIP version of pytorch")
load("rocm/6.1.0")
prepend_path("PYTHONPATH","/opt/rocmplus-6.1.0/pytorch/lib/python3.10/site-packages")
```

Module name: `Core/lmod/6.6`

Modulefile location: `/usr/share/lmod/lmod/modulefiles/Core/lmod`

Modulefile content:
```bash
-- -*- lua -*-
whatis("Description: Lmod: An Environment Module System")
prepend_path('PATH','/usr/share/lmod/lmod/libexec')
```

Module name: `Core/settarg/6.6`

Modulefile location: `/usr/share/lmod/lmod/modulefiles/Core/settarg`

Modulefile content:
```bash
local base        = "/usr/share/lmod/lmod/settarg"
local settarg_cmd = pathJoin(base, "settarg_cmd")

prepend_path("PATH",base)
pushenv("LMOD_SETTARG_CMD", settarg_cmd)
set_shell_function("settarg", 'eval $($LMOD_SETTARG_CMD -s sh "$@")',
                              'eval `$LMOD_SETTARG_CMD  -s csh $*`' )

set_shell_function("gettargdir",  'builtin echo $TARG', 'echo $TARG')

local respect = "true"
setenv("SETTARG_TAG1", "OBJ", respect )
setenv("SETTARG_TAG2", "_"  , respect )

if ((os.getenv("LMOD_FULL_SETTARG_SUPPORT") or "no"):lower() ~= "no") then
   set_alias("cdt", "cd $TARG")
   set_shell_function("targ",  'builtin echo $TARG', 'echo $TARG')
   set_shell_function("dbg",   'settarg "$@" dbg',   'settarg $* dbg')
   set_shell_function("empty", 'settarg "$@" empty', 'settarg $* empty')
   set_shell_function("opt",   'settarg "$@" opt',   'settarg $* opt')
   set_shell_function("mdbg",  'settarg "$@" mdbg',  'settarg $* mdbg')
end

local myShell = myShellName()
local cmd     = "eval `" .. settarg_cmd .. " -s " .. myShell .. " --destroy`"
execute{cmd=cmd, modeA = {"unload"}}


local helpMsg = [[
The settarg module dynamically and automatically updates "$TARG" and a
host of other environment variables. These new environment variables
encapsulate the state of the modules loaded.

For example, if you have the settarg module and gcc/4.7.2 module loaded
then the following variables are defined in your environment:

   TARG=OBJ/_x86_64_06_1a_gcc-4.7.3
   TARG_COMPILER=gcc-4.7.3
   TARG_COMPILER_FAMILY=gcc
   TARG_MACH=x86_64_06_1a
   TARG_SUMMARY=x86_64_06_1a_gcc-4.7.3

If you change your compiler to intel/13.1.0, these variables change to:

   TARG=OBJ/_x86_64_06_1a_intel-13.1.0
   TARG_COMPILER=intel-13.1.0
   TARG_COMPILER_FAMILY=intel
   TARG_MACH=x86_64_06_1a
   TARG_SUMMARY=x86_64_06_1a_intel-13.1.0

If you then load mpich/3.0.4 module the following variables automatically
change to:

   TARG=OBJ/_x86_64_06_1a_intel-13.1.0_mpich-3.0.4
   TARG_COMPILER=intel-13.1.0
   TARG_COMPILER_FAMILY=intel
   TARG_MACH=x86_64_06_1a
   TARG_MPI=mpich-3.0.4
   TARG_MPI_FAMILY=mpich
   TARG_SUMMARY=x86_64_06_1a_dbg_intel-13.1.0_mpich-3.0.4

You also get some TARG_* variables that always available, independent
of what modules you have loaded:

   TARG_MACH=x86_64_06_1a
   TARG_MACH_DESCRIPT=...
   TARG_HOST=...
   TARG_OS=Linux-3.8.0-27-generic
   TARG_OS_FAMILY=Linux

One way that these variables can be used is part of a build system where
the executables and object files are placed in $TARG.  You can also use
$TARG_COMPILER_FAMILY to know which compiler you are using so that you
can set the appropriate compiler flags.

Settarg can do more.  Please see the Lmod website for more details.
]]

help(helpMsg)
```

# 4. Adding Your Own Modules

The information above about the modules and modulefiles in the container can be used to include your own modules. As a simple example, below we show how to install `Julia` as a module within the container.
First, install the Julia installation manager Juliaup:

```bash
sudo -s

curl -fsSL https://install.julialang.org | sh

exit
```

Then, update your `.bashrc`:

```bash
source ~/.bashrc
```

To see what versions of `Julia` can be installed do:

```bash
juliaup list
```

Once you selected the version you want (let's assume it's 1.10), you can install it by doing:

```bash
juliaup add 1.10
```

The package will be installed in `$HOME/.julia/juliaup/julia-1.10.3+0.x64.linux.gnu`. 

Next, `cd` into `/etc/lmod/modules` and create a folder for `Julia`:

```bash
sudo mkdir Julia
```

Go in the folder just created and create a modulefile (here called `julia.1.10.lua`) with this content (replace `<admin>` with your admin username:

```bash
whatis("Julia Version 1.10")
append_path("PATH", "/users/<admin>/.julia/juliaup/julia-1.10.3+0.x64.linux.gnu/bin")
```

Finally, add the new modulefile location to `MODULEPATH` (needs to be repeated every time you exit the container):

```bash
module use --append /etc/lmod/modules/Julia
```

Now, `module avail` will show this additional module:

```bash
-------------------------------------------------------------------------------- /etc/lmod/modules/Julia --------------------------------------------------------------------------------
   julia.1.10
```

# 5. Testing the Installation

You can check that our training exercies run with your installation, by doing:

```bash
git clone https://github.com/amd/HPCTrainingExamples && \
cd HPCTrainingExamples/tests && \
./runTests.sh
```                                                                      

# 6. Feedback

We very much welcome user experience and feedback, please feel free to reach out to us by creating pull requests of opening issues if you consider it necessary.
We will get back to you as soon as possible. For information on licenses, please see the `LICENSE.md` file.
