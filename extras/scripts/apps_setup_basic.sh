
echo "########## Install additional libs and apps #############"

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

${SUDO} apt-get update
${SUDO} apt-get install -y liblapack3 liblapack-dev liblapacke-dev \
                   libopenblas-base libopenblas-dev libopenblas64-dev
