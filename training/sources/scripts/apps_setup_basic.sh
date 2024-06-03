
echo "########## Install additional libs and apps #############"

sudo DEBIAN_FRONTEND=noninteractive apt update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y liblapack3 liblapack-dev liblapacke-dev \
                   libopenblas-base libopenblas-dev libopenblas64-dev
