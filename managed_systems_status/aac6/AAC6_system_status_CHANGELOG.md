# AAC6 System Status — Change Log

Newest entries first. Each entry summarises user-visible changes since the previous snapshot. The dated full snapshots live under `archive/`.

## 2026-05-06

- ROCm default: 7.2.0 → 7.2.2
- ROCm versions:
    + 7.2.2
    - afar-22.1.0
    - afar-22.2.0
    - afar-7.0.5
    - therock-23.1.0
    - therock-23.2.0

[Full snapshot](archive/AAC6_system_status_2026-05-06.md)
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
