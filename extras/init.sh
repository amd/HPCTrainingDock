echo "in Training Hackathon init.sh"


echo "IP address is: "
ifconfig | grep inet

# need munge, slurmctld and slurmd  for slurm

cp /etc/slurm/slurm.conf slurm.conf.orig
cp /etc/slurm/gres.conf gres.conf.orig

nodeconfig=`slurmd -C | head -1`
partitionconfig="PartitionName=LocalQ Nodes=ALL Default=YES MaxTime=02:00:00 State=UP OverSubscribe=YES"
MI210_COUNT=`rocminfo | grep MI210 | wc -l`
MI250_COUNT=`rocminfo | grep MI250 | wc -l`
MI300_COUNT=`rocminfo | grep -v '^  Name:' | grep MI300 | wc -l`
MI300_COUNT=$((MI300_COUNT/2))
if [ "${MI210_COUNT}" -ge 1 ]; then
   gpustring=Gres=gpu:MI210:${MI210_COUNT}
   first_number=`cd /dev/dri && ls renderD* | sed -e 's/^renderD//g' |head -1`
   last_number=`cd /dev/dri && ls renderD* | sed -e 's/^renderD//g' |tail -1`
   file_string=/dev/dri/renderD[${first_number}-${last_number}]
   sed -e 's/Type=[[:alnum:]]* /Type=MI210 /' \
       -e 's/NodeName=[[:alnum:]]* /NodeName=localhost /' \
       -e "s!File=.*!File=${file_string}!" gres.conf.orig > gres.conf
fi
if [ "${MI250_COUNT}" -ge 1 ]; then
   gpustring=Gres=gpu:MI250:${MI250_COUNT}
   first_number=`cd /dev/dri && ls renderD* | sed -e 's/^renderD//g' |head -1`
   last_number=`cd /dev/dri && ls renderD* | sed -e 's/^renderD//g' |tail -1`
   file_string=/dev/dri/renderD[${first_number}-${last_number}]
   sed -e 's/Type=[[:alnum:]]* /Type=MI250 /' \
       -e 's/NodeName=[[:alnum:]]* /NodeName=localhost /' \
       -e "s!File=.*!File=${file_string}!" gres.conf.orig > gres.conf
fi
if [ "${MI300_COUNT}" -ge 1 ]; then
   gpustring=Gres=gpu:MI300:${MI300_COUNT}
   file_string=/dev/dri/renderD[128,136,144,152]
   sed -e 's/Type=[[:alnum:]]* /Type=MI300A /' \
       -e 's/NodeName=[[:alnum:]]* /NodeName=localhost /' \
       -e "s!File=.*!File=${file_string}!" gres.conf.orig > gres.conf
fi

sed -e "s/^NodeName=.*/${nodeconfig} ${gpustring} /" \
    -e 's/NodeName=.* /NodeName=localhost /' \
    -e "s/^PartitionName=.*/${partitionconfig}/" \
    -e '/^InactiveLimit/s/=.*/=60/' \
    -e '/^KillWait/s/=.*/=30/' \
    -e '/^MinJobAge/s/=.*/=300/' \
    -e '/^SlurmctldTimeout/s/=.*/=120/' \
    -e '/^SlurmdTimeout/s/=.*/=300/' \
    -e '/^Waittime/s/=.*/=300/' \
    -e '/^TaskPlugin/s/affinity/none/' \
    -e '/^TaskPlugin/s!task/none!task/cgroup!' \
    ./slurm.conf.orig > slurm.conf

sudo cp slurm.conf /etc/slurm/slurm.conf
sudo cp gres.conf /etc/slurm/gres.conf

sudo service munge start
sleep 1
sudo service slurmctld start
sleep 1
sudo service slurmd start

echo "starting ssh server and waiting for ssh logins...."

/usr/sbin/sshd -D

#HAVE_X11VNC=`which x11vnc |wc -l`
#if [ "${HAVE_X11VNC}" == "1" ] then
#   x11vnc -display :0 -rfbport 5900 -xkb -repeat -skip_dups -forever -shared -rfbauth "AAA"invoke-rc.d: could not determine current runlevel
#fi
