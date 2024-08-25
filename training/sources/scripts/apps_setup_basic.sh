
echo "########## Install additional libs and apps #############"

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

${SUDO} DEBIAN_FRONTEND=noninteractive apt-get update
${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y liblapack3 liblapack-dev liblapacke-dev \
                   libopenblas-base libopenblas-dev libopenblas64-dev
