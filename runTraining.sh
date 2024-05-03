
# GPU devices
DEVICE=" --device /dev/dri --device /dev/kfd "
DISK=" -v /home/amdtrain/Class/training/hostdir:/hostdir "
NAME=" --name Training "
OPT=" --rm "
PORT=" -p 2222:22 "
DETACH=" --detach "
NAME="--name Train1 "
NETWORK=" "

# sudo docker run -it $DEVICE root/omnitrace:release-base-ubuntu-22.04-rocm-5.4.3

# sudo docker run -it $DEVICE amdtrain/omniperf:release-base-ubuntu-22.04-rocm-5.4.3 

# omnitrace + omniperf =

echo " " 
echo "Port mapping is " $PORT
echo "IP <ip>  is " `ip a s | grep inet `  
echo "login via ssh " 
echo "ex.:    ssh teacher@<ip> -p 2222 "
echo "ex.:    ssh student1@<ip> -p 2222 "
sudo docker run -it $DETACH $DEVICE $DISK $NAME $OPT $PORT $NAME $NETWORK --security-opt seccomp=unconfined  training 

