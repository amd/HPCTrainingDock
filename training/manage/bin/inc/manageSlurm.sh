#!/bin/bash

echo
echo Manage the Hack-a-thon SLURM environment...
echo
sleep 1


opt1="Start SLURM"
opt2="Config SLURM"
opt3="Display SLURM"
opt4="Restart SLURM"
opt5="Fix GPU ownership"


PS3='Please enter your choice: '
options=("${opt1}" \
         "${opt2}" \
         "${opt3}" \
         "${opt4}" \
         "${opt5}" \
         "Quit")


function fixGPUPermissions ()
{
   echo "Before fixing:"
   ls -lsa /dev/dri
   ls -lsa /dev/kfd
   sudo chgrp -R video /dev/dri
   sudo chgrp -R video /dev/kfd
   echo " " 
   echo "After fixing:"
   ls -lsa /dev/dri
   ls -lsa /dev/kfd
   echo "Visually verify that devices are in the video group"
}

function startSlurm()
{

   # need munge, slurmctld and slurmd  for slurm
   sudo service munge start
   sleep 1
   sudo service slurmctld start
   sleep 1
   sudo service slurmd start
   sleep 2
   sinfo
}

function restartSlurm()
{
 
   sudo pkill  slurm
   sleep 1
   # need munge, slurmctld and slurmd  for slurm
   # sudo service munge start
   sudo service slurmctld start
   sleep 3
   sudo service slurmd start
   sleep 3
   sudo scontrol update node=LocalQ state=resume
   sinfo

}


function configureSlurm()
{

       echo
       echo
       echo "# Copy these recommended parms to /etc/slurm/slurm.conf"
       echo "# TIMERS "
       echo "InactiveLimit=60"
       echo "KillWait=30"
       echo "MinJobAge=300"
       echo "SlurmctldTimeout=120"
       echo "SlurmdTimeout=300"
       echo "Waittime=60"

       # we need the combined output from rocminfo, lsmem and lscpu !
       #rocminfo > cpuinfo.out
       #lscpu    >>cpuinfo.out
       #lsmem    >>cpuinfo.out
       #awk -f ./cpuInfo.awk  < cpuinfo.out
       #rm -f cpuinfo.out

       cp /etc/slurm/slurm.conf slurm.conf.orig
       cp /etc/slurm/gres.conf gres.conf.orig

       echo "PartitionName=LocalQ Nodes=ALL Default=YES MaxTime=02:00:00 State=UP OverSubscribe=YES"
       echo
       echo
#       echo "# use this info for  /etc/slurm/gres.conf"
#      ls -lsa /dev/dri
#      rocminfo | grep MI
#      echo "Modifying slurm.conf"
       nodeconfig=`slurmd -C | head -1`
       partitionconfig="PartitionName=LocalQ Nodes=ALL Default=YES MaxTime=02:00:00 State=UP OverSubscribe=YES"
       MI210_COUNT=`rocminfo | grep MI210 | wc -l`
       MI250_COUNT=`rocminfo | grep MI250 | wc -l`
       MI300_COUNT=`rocminfo | grep -v '^  Name:' | grep MI300 | wc -l`
       MI300_COUNT=$((MI300_COUNT/2))
       echo "MI210_COUNT is ${MI210_COUNT}"
       echo "MI250_COUNT is ${MI250_COUNT}"
       echo "MI300_COUNT is ${MI300_COUNT}"
       if [ "${MI210_COUNT}" -ge 1 ]; then
          gpustring=Gres=gpu:MI210:${MI210_COUNT}
          first_number=`cd /dev/dri && ls renderD* | sed -e 's/^renderD//g' |head -1`
          last_number=`cd /dev/dri && ls renderD* | sed -e 's/^renderD//g' |tail -1`
          file_string=/dev/dri/renderD[${first_number}-${last_number}]
          sed -i -e 's/Type=.* /Type=MI210 /' \
                 -e 's/NodeName=.* /NodeName=localhost /' \
                 -e 's/File=.* /File=${file_string}/' gres.conf.orig > gres.conf
       fi
       if [ "${MI250_COUNT}" -ge 1 ]; then
          gpustring=Gres=gpu:MI250:${MI250_COUNT}
          first_number=`cd /dev/dri && ls renderD* | sed -e 's/^renderD//g' |head -1`
          last_number=`cd /dev/dri && ls renderD* | sed -e 's/^renderD//g' |tail -1`
          file_string=/dev/dri/renderD[${first_number}-${last_number}]
          sed -i -e 's/Type=.* /Type=MI250 /' \
                 -e 's/NodeName=.* /NodeName=localhost /' \
                 -e 's/File=.* /File=${file_string}/' gres.conf.orig > gres.conf
       fi
       if [ "${MI300_COUNT}" -ge 1 ]; then
          gpustring=Gres=gpu:MI300:${MI300_COUNT}
          file_string=/dev/dri/renderD[128,136,144,152]
          sed -e 's/Type=.* /Type=MI300A /' \
              -e 's/NodeName=.* /NodeName=localhost /' \
              -e 's/File=.* /File=${file_string}/' gres.conf.orig > gres.conf
       fi
       echo "Diff of changes made"
       diff gres.conf gres.conf.orig
       echo ""
       echo ""
       echo "Diff with current installed version"
       diff gres.conf /etc/slurm/gres.conf
       echo ""

       echo "Starting slurm.conf changes"

       #sudo cp /etc/slurm/slurm.conf /etc/slurm/slurm.conf.back
       sed -e "s/^NodeName=.*/${nodeconfig} ${gpustring} /" \
           -e 's/^NodeName=[[:alpha:]]\+/NodeName=localhost /' \
           -e "s/^PartitionName=.*/${partitionconfig}/" \
           -e '/^InactiveLimit/s/=.*/=60/' \
           -e '/^KillWait/s/=.*/=30/' \
           -e '/^MinJobAge/s/=.*/=300/' \
           -e '/^SlurmctldTimeout/s/=.*/=120/' \
           -e '/^SlurmdTimeout/s/=.*/=300/' \
           -e '/^Waittime/s/=.*/=300/' \
           -e '/^TaskPlugin/s/affinity/none/' \
           ./slurm.conf.orig > slurm.conf
       diff slurm.conf slurm.conf.orig

       echo ""
       echo ""
       echo ""
       echo ""
       echo "Checking diff to current version"
       grep -v '^#' slurm.conf > tmp1
       grep -v '^#' /etc/slurm/slurm.conf > tmp2
       diff tmp1 tmp2
       echo ""
       echo ""
       echo ""

       #sudo cp slurm.conf /etc/slurm/slurm.conf
       #sudo cp gres.conf /etc/slurm/gres.conf

       #   sudo pkill  slurm
       #   sleep 1
       #   # need munge, slurmctld and slurmd  for slurm
       #   # sudo service munge start
       #   sudo service slurmctld start
       #   sleep 3
       #   sudo service slurmd start
       #   sleep 3
       #   sudo scontrol update node=LocalQ state=resume
       #   sinfo

}

function displaySlurm()
{
   sinfo -o   "%N %.6D %P %.11T %.4c %.8z %.6m %.8f %l %G %20E"
}

select opt in "${options[@]}"
do
    case $opt in
        "${opt1}")
            echo "you chose ${opt1}"
	    startSlurm
            ;;
        "${opt2}")
            echo "you chose ${opt2}"
	    configureSlurm
            ;;
        "${opt3}")
            echo "you chose ${opt3}"
	    displaySlurm
            ;;            
        "${opt4}")
            echo "you chose ${opt4} "
            restartSlurm 
            ;;
        "${opt5}")
            echo "you chose ${opt5} "
            fixGPUPermissions
            ;;
        "Quit")
            break
            ;;
        *) echo "invalid option $REPLY";;
    esac
    echo "1) Start SLURM"
    echo "2) Config SLURM"
    echo "3) Display SLURM"
    echo "4) Restart SLURM"
    echo "5) Fix GPU ownership"
    echo "6) Quit"
done


