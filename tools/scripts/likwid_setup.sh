
#!/bin/bash

module load rocm
#module load amdclang

cd /tmp

rm -rf likwid*
wget -q https://github.com/RRZE-HPC/likwid/archive/refs/tags/v5.5.1.tar.gz
tar -xzf v5.5.1.tar.gz
cd likwid-5.5.1
sed -i -e '/^ROCM_INTERFACE/s/false/true/' \
       -e '/^PREFIX/s!/usr/local!/shared/apps/ubuntu/rocmplus-7.2.0/likwid!' \
       config.mk

#      -e '/^FORTRAN_INTERFACE/s/false/true/' \

export ROCM_HOME=${ROCM_PATH}
make
sudo make install


# module setup
exit
whatis("LIKWID")
prereq("rocm/7.2.0")

local base = "/shared/apps/ubuntu/rocmplus-7.2.0/likwid"

prepend_path("PATH", pathJoin(base, "bin"))
prepend_path("LD_LIBRARY_PATH",pathJoin(base,"lib"))
