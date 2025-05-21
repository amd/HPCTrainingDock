
echo "########## Install additional libs and apps #############"

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

${SUDO} apt-get update
${SUDO} apt-get install -y valgrind \
	                emacs \
                        kcachegrind kcachegrind-converters \
                        libboost-all-dev \
                        libgmp-dev \
                        libgsl-dev \
                        libtool \
                        libxml2 \
                        libmpfrc++-dev libmpfr6 \
                        openssl \
			swig \
			libparmetis-dev \
                        libfftw3-dev \
           		libhdf5-openmpi-103-1 libhdf5-dev \
			petsc-dev petsc64-dev \
			libadios-dev libadios-openmpi-dev libadios-bin \
			libparmetis-dev libscotchparmetis-dev \
			scotch \
                        libeigen3-dev \
                        libmagma-dev

# adios2 is available in ubuntu 24.04
#                       python3-matplotlib \
#                       python3-mpi4py \
#                       python3-numpy \
#                       python3-scipy  python3-h5sparse \
#		libtbb-dev
