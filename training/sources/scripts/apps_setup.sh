
echo "########## Install additional libs and apps #############"

sudo apt-get update
sudo apt-get install -y valgrind \
                        kcachegrind kcachegrind-converters \
                        libboost-all-dev \
                        libeigen3-dev \
                        libfftw3-dev \
                        libgmp-dev \
                        libgsl-dev \
			libhdf5-openmpi-103-1 libhdf5-dev \
                        libtool \
                        libxml2 \
                        libmagma-dev \
                        python3-matplotlib \
                        libparmetis4.0 \
                        libmpfrc++-dev libmpfr6 \
                        python3-mpi4py \
                        python3-numpy \
                        openssl \
			swig \
                        python3-scipy  python3-h5sparse \
			libtbb-dev
