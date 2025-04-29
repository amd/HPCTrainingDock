
echo "########## Install additional libs and apps #############"

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

${SUDO} apt-get update
${SUDO} apt-get install -y valgrind \
                        kcachegrind kcachegrind-converters \
                        libboost-all-dev \
                        libgmp-dev \
                        libgsl-dev \
                        libtool \
                        libxml2 \
                        libmpfrc++-dev libmpfr6 \
                        openssl \
			swig \
			libparmetis-dev


#                       libeigen3-dev \
#                       libfftw3-dev \
#		libhdf5-openmpi-103-1 libhdf5-dev \
#                       libmagma-dev \
#                       python3-matplotlib \
#                       python3-mpi4py \
#                       python3-numpy \
#                       python3-scipy  python3-h5sparse \
#		libtbb-dev
