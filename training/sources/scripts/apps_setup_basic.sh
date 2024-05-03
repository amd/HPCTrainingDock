
echo "########## Install additional libs and apps #############"

apt update
apt-get install -y liblapack3 liblapack-dev liblapacke-dev \
                   libopenblas-base libopenblas-dev libopenblas64-dev
