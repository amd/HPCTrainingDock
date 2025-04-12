#!/bin/bash

#########################################################################
# USER SETTINGS:  go ahead and change these if you need
#

# change the version if needed, the rest will be auto populated
export OMNISTAT_VERSION=1.4.0

# allowed ips:  by default it is set to 127.0.0.1, which won't
# talk to external nodes.  Note: 0.0.0.0 (listen on all ports)
# is DANGEROUS as it allows users from whereever to connect to
# the ports for omnistat.  Best to insert a (set of) specific VPC or
# private network.
export OMNISTAT_VPC="127.0.0.1, 10.0.0.0/16"
# currently allowing localhost (127.0.0.1) and the 10.0.0.0/16 networks
# change the latter to reflect your IPs (either as a list of IPs
# or as a subnet)
#
#########################################################################

#########################################################################
# Don't change things below this banner, as you might break installation
# or configuration

# check if running as root, if not emit error message
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as sudo/root"
  exit 1
fi

# install Ubuntu 24.04 prometheus database,aria2c downloader, 
# pwgen password gen, python3 virtual environment generator
apt -y install prometheus aria2 pwgen python3-venv
systemctl stop prometheus

# modify the prometheus config (change monitor: 'example' to
# monitor: 'AMD_MI_GPU')
sed -i 's|example|AMD_MI_GPU|g' /etc/prometheus/prometheus.yml

# start prometheus
systemctl start prometheus

# add user omnidc, and generate 1x 12 character password
useradd -m omnidc
export PW=$(pwgen -N 1 12)

# get the home directory for this omnidc user, write PW in as pass with 0600
# perms
export HD=$(getent passwd omnidc | cut -d":" -f6- | cut -d":" -f1)
echo $PW >${HD}/pass
chmod 0600 ${HD}/pass

# get into the omnidc home directory
cd ${HD}

# set auto populated values
export OMNISTAT_DIR=${HD}/omnistat-${OMNISTAT_VERSION}
export OMNISTAT_REPO=https://github.com/AMDResearch/omnistat
export OMNISTAT_TARBALL=${OMNISTAT_VERSION}.tar.gz
export OMNISTAT_URL=${OMNISTAT_REPO}/archive/refs/tags/v${OMNISTAT_TARBALL}

# download tarball
aria2c -x 8 ${OMNISTAT_URL} -o omnistat-${OMNISTAT_TARBALL}

# unpack tarball
tar -zxf omnistat-${OMNISTAT_TARBALL}
chown -R omnidc:omnidc ${HD}

# install requirements (as user omnidc)

sudo -u omnidc /bin/bash -c "cd ${HD} ; python3 -m venv omnistat ; source omnistat/bin/activate ; pip3 install  -r ${OMNISTAT_DIR}/requirements.txt"

# write out the systemd unit
cat <<EOF >${HD}/omnistat.service
[Unit]
Description=Prometheus exporter for HPC/GPU oriented metrics
Documentation=https://amdresearch.github.io/omnistat/
Requires=network-online.target
After=network-online.target

[Service]
User=omnidc
Environment="OMNISTAT_CONFIG=${OMNISTAT_DIR}/omnistat/config/omnistat.default"
CPUAffinity=0
ExecStart=/bin/bash -c "cd ${HD} ; source omnistat/bin/activate ; ${OMNISTAT_DIR}/omnistat-monitor"
SyslogIdentifier=omnistat
ExecReload=/bin/kill -HUP $MAINPID
TimeoutStopSec=20s
SendSIGKILL=no
Nice=19
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

chown omnidc:omnidc ${HD}/omnistat.service
chmod 0600 ${HD}/omnistat.service

# alter the ${OMNISTAT_DIR} allowed_ips
sed -i "s|allowed_ips.*|allowed_ips = ${OMNISTAT_VPC}|g" ${OMNISTAT_DIR}/omnistat/config/omnistat.default

# add a link into /etc/systemd/system for this, reload the daemon
ln -s ${HD}/omnistat.service /etc/systemd/system/omnistat.service
systemctl daemon-reload

# launch the daemon
systemctl enable omnistat.service
systemctl start omnistat.service


##############################################################################
# Notes
#
# if you see this while debugging by running ${OMNISTAT_DIR}/omnistat-monitor
#
#
#  [INFO] Booting worker with pid: 1952370
#  Runtime library loaded from /opt/rocm/lib/librocm_smi64.so
# [2025-04-07 19:29:55 +0000] [1952370] [ERROR] Exception in worker process
# Traceback (most recent call last):
#   File "/home/omnidc/.local/lib/python3.10/site-packages/gunicorn/arbiter.py", line 607, in spawn_worker
#     self.cfg.post_fork(self, worker)
#   File "/home/omnidc/omnistat-1.4.0/omnistat/node_monitoring.py", line 95, in post_fork
#     monitor.initMetrics()
#   File "/home/omnidc/omnistat-1.4.0/omnistat/monitor.py", line 131, in initMetrics
#     self.__collectors.append(ROCMSMI(runtimeConfig=self.runtimeConfig))
#   File "/home/omnidc/omnistat-1.4.0/omnistat/collector_smi.py", line 194, in __init__
#     assert ret_init == 0
# AssertionError
# [2025-04-07 19:29:55 +0000] [1952370] [INFO] Worker exiting (pid: 1952370)
#
# then you are likely missing your amdgpu being installed into the kernel. Try
# 
# 	sudo modprobe -v amdgpu
#
# and see if this corrects that issue.  If so, please retry the 
# ${OMNISTAT_DIR}/omnistat-monitor
