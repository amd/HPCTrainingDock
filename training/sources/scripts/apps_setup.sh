
echo "########## Install additional libs and apps #############"

sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y valgrind \
                        kcachegrind kcachegrind-converters \
                        libboost-all-dev \
                        libgmp-dev \
                        libgsl-dev \
                        libtool \
                        libxml2 \
                        libmpfrc++-dev libmpfr6 \
                        openssl \
			swig


#                       libeigen3-dev \
#                       libfftw3-dev \
#		libhdf5-openmpi-103-1 libhdf5-dev \
#                       libmagma-dev \
#                       python3-matplotlib \
#                       libparmetis4.0 \
#                       python3-mpi4py \
#                       python3-numpy \
#                       python3-scipy  python3-h5sparse \
#		libtbb-dev
