# AAC6 System Status — Change Log

Newest entries first. Each entry summarises user-visible changes since the previous snapshot. The dated full snapshots live under `archive/`.

## 2026-05-12

- ROCm default: 7.2.1 → 7.2.0
- ROCm versions:
    + 7.2.2
    + 7.2.3
    + therock-23.2.1

[Full snapshot](archive/AAC6_system_status_2026-05-12.md)
## 2026-05-09

- ROCm default: 7.2.0 → 7.2.1

[Full snapshot](archive/AAC6_system_status_2026-05-09.md)
## 2026-05-07

- ROCm versions:
    - afar-7.0.5

- Fixing CPX mode for prolog and for fixed configuration
- Adding patching for ROCm with fixes for rocprof-sys failures
- Adding --install-provenance with --with-dates

[Full snapshot](archive/AAC6_system_status_2026-05-07.md)
## 2026-05-06

More software packages for all the ROCm versions are being filled in
and fixed. Notable fixes.
  * The therock-23.1.0 MPI has a bug with `rccl_init`. Set an environment
    variable in the openmpi module file to disable rccl in MPI for this
    version of ROCm.
  * afar and rocm-6.3.x sweeps are being installed
  * rocprof-sys fixed for pytorch by including a `LD_LIBRARY_PATH` to
    the `libcaffe2_nvtrx.so` to fix rocprof-sys profiling of pytorch
  * rocprof-compute is fixed for pytorch profiling to bring in
    the libomp.so library

## 2026-05-05

A certificate has been added for some services on the cluster. 
Now https services should be available.

Changes to some of the package installation scripts have been
made to enable `therock` versions to work for software installs

therock-23.2.0: A bug in the RCCL layer in UCC is causing MPI 
jobs to fail. The workaround is to set the environment variable
`export UCC_TLS=^rccl`. This is being added to the OpenMPI 
module so users will not need to do anything. Patches to
setup files for openmpi, netcdf, petsc, and pytorch (in progres)
are needed.

Software installation sweeps have been done for ROCm versions
7.2.1, 7.2.0, 7.1.1, 7.1.0, 7.0.2, 7.0.1, 7.0.0 and therock-23.2.0

Cupy version was upgraded to version 14, but it is being returned
to version 13 because of a reported bug

Software packages now have version numbers attached to them so that
multiple versions of a package can be installed.

Initial snapshot.

[Full snapshot](archive/AAC6_system_status_2026-05-05.md)
