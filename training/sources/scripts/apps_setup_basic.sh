
echo "########## Install additional libs and apps #############"

SUDO="sudo"
DEBIAN_FRONTEND_MODE="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEBIAN_FRONTEND_MODE=""
fi

${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get update
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get install -y liblapack3 liblapack-dev liblapacke-dev \
                   libopenblas-base libopenblas-dev libopenblas64-dev
