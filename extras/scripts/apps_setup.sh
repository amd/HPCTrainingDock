#!/bin/bash
echo "########## Install additional libs and apps #############"

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

${SUDO} apt-get update
${SUDO} apt-get install -y \
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

#${SUDO} apt-get install --no-install-recommends -y \
#                       emacs \
#                       libstdc++-14-dev
	
# adios2 is available in ubuntu 24.04
