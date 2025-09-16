# Example of How to Use the Scrips in the HPCTrainingDock

Begin by cloning the repo and getting to the `rocm` directory:

```
git clone https://github.com/amd/HPCTrainingDock.git
cd HPCTrainingDock/rocm/scripts
```

We will consider the script to install the latest rocm-afar drop with the latest [amdflang compiler](https://rocm.blogs.amd.com/ecosystems-and-partners/fortran-journey/README.html).
The first thing to do is to run the script with the `--help` option to see what are the input flags for the script and what are the defaults:

```
./flang-new_setup.sh --help
```

The output will be similar to this:

```
./flang-new_setup.sh: line 4: rocminfo: command not found
Usage:
  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions
  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected
  --module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCm/amdflang-new
  --install-path [ UNTAR_DIR_INPUT ] default /opt/rocmplus-6.0
  --rocm-version [ ROCM_VERSION ] default 6.2.0
  --build-flang-new [ BUILD_FLANGNEW ] default 0
  --afar-number [ AFAR_NUMBER ] default 8248
  --flang-release-number [ FLANG_RELEASE_NUMBER ] default 7.0.5
  --help: print this usage information
```

Note from the above output that there is a message saying that `rocminfo` has not been found: it is used to autodetect the gpu architecture as it can be seen from the description of the `--amdgpu-gfxmodel`, but since the module for ROCm is not loaded, then `rocminfo` is not found. This brings up an important point, which is that users running this script should make sure to supply the desired AMD GPU gfx model otherwise if will either be blank or autodetected using ROCm and will pick up what GPU is currently on the system. Supplying the gfx architecture is fundamental if cross-compiling. For this specific script, the gfx architecture is not used since we will be untarring something that has been pre-compiled, but in the vast majority of the scripts in the HPCTrainingDock repo the compilation is actually carried out, and therefore in those cases the gfx architecture is required as input.

From the above list of commands, the `--module-path` will specify the destination of a lua module file that will be created when running the script. The `--install-path` is the path to the installation directory. If the module file directory and the install directory will be left as default, the user needs sudo privileges, since they are respectively in `/etc` and `/opt`. It is possible to run this script and install it in a location where the user has write privileges to avoid the use of `sudo`. The only thing to do is make sure the directories for the module file and the installation exist and the user has write access to those. Then these need to be supplied as input when running the script. The script will then check whether these directories exist and if the user has write access to those. If so, then `sudo` will not be used:

```
      if [ -d "$UNTAR_DIR" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${UNTAR_DIR} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi
```
Note above that in case the directory exists and the user has write access, `SUDO=""` so no `sudo` will be used.
To check what is the latest drop, visit [this](https://repo.radeon.com/rocm/misc/flang/) website: as of September 16, 2025 the latest drop is `7.1.1` with afar-number `8473` which is not the default (check the output of `./flang-new_setup.sh --help` again).

We will install the script in our home directory and use the latest drop, with ROCm version 6.4.3. To do so, we first need to create the directories

```
mkdir -p $HOME/flang-new_install
mkdir -p $HOME/flang-new_module
```

Then execute the script (let's assume we are considering an MI300A so gfx942):
```
./flang-new_setup.sh --amdgpu-gfxmodel gfx942 --install-path $HOME/flang-new_install \
                     --module-path $HOME/flang-new_module --rocm-version 6.4.3 \
                     --build-flang-new 1 --afar-number 8473 --flang-release-number 7.1.1
```

The output you can expect after executing the above command is:

```
=========================================
Starting flang-new Install with
ROCM_VERSION: 6.4.3
BUILD_FLANGNEW: 1
Archive will be untarred in: /home/sysadmin/flang-new_install
ARCHIVE_NAME is rocm-afar-8473-drop-7.1.1
FULL_ARCHIVE_NAME is rocm-afar-8473-drop-7.1.1-ubuntu
ARCHIVE_DIR is rocm-afar-7.1.1
INSTALL_DIR or UNTAR_DIR is /home/sysadmin/flang-new_install
Looking for the file: https://repo.radeon.com/rocm/misc/flang/rocm-afar-8473-drop-7.1.1-ubuntu.tar.bz2
=========================================


================================================
         Installing flang-new
================================================
```

If you now do `module avail` you should see
```
---------------------------------------------------------------------- /etc/lmod/modules/ROCm ----------------------------------------------------------------------
   amdclang/19.0.0-6.4.3           hipfort/6.4.3    rocm/6.4.3                       rocprofiler-sdk/6.4.3
   amdflang-new/rocm-afar-7.1.1    opencl/6.4.3     rocprofiler-compute/6.4.3 (D)    rocprofiler-systems/6.4.3 (D)
```
