# Register the Lmod system spider cache on NFS (Ubuntu 24.04 stack).
# Replaces the old LMOD_IGNORE_CACHE=1 workaround. See
# /nfsapps/ubuntu-24.04/moduleData/ and HPCTrainingDock infrastructure/lmod/README.md.
export LMOD_RC=/nfsapps/ubuntu-24.04/moduleData/lmodrc.lua
export LMOD_CACHED_LOADS=yes
