#!/bin/bash
echo "########## Install additional libs and apps #############"

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# PKG_SUDO is independent of the install-path-derived SUDO: apt operates
# on root-owned /var/lib/{apt,dpkg} regardless of where the package files
# end up. See openmpi_setup.sh / audit_2026_05_01.md Issue 2.
PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")

${PKG_SUDO} apt-get update
${PKG_SUDO} apt-get install -y \
                         libgmp-dev \
                         libgsl-dev \
                         kcachegrind kcachegrind-converters \
                         libmpfrc++-dev libmpfr6 \
 			 swig \
 			 libparmetis-dev \
                         libfftw3-dev \
            		 libhdf5-openmpi-103-1 libhdf5-dev \
 			 scotch \
                         libeigen3-dev \
                         libmagma-dev \
			 libparmetis-dev \
 			 libadios-dev libadios-openmpi-dev libadios-bin \
			 libhypre-dev libhypre64-dev \
 			 petsc-dev petsc64-dev

# note that installing emacs will break hipcc unless libstdc++-14 is added 
# modifying rocm module so that it forces use of the base libstdc++ version

#${PKG_SUDO} apt-get install --no-install-recommends -y \
#                       emacs \
#                       libstdc++-14-dev
	
# adios2 is available in ubuntu 24.04
