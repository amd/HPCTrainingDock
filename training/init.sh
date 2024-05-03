echo "in Training Hackathon init.sh"


echo "IP address is: "
ifconfig | grep inet

# need munge, slurmctld and slurmd  for slurm

service munge start
sleep 1
service slurmctld start
sleep 1
service slurmd start

echo "starting ssh server and waiting for ssh logins...."

/usr/sbin/sshd -D

