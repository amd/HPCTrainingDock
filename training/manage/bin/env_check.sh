#!/bin/bash

function print_usage {
	echo "    Usage: env_check.sh set/reset/check"
	echo "                      set: configure the settings in this script"
	echo "                      reset: reset to default settings"
	echo "                      check: check the current settings"
}

function set_env {
	export HIP_FORCE_DEV_KERNARG=1
	rocm-smi --setperfdeterminism 1900
	sudo sh -c echo 0 > /proc/sys/kernel/numa_balancing
    sudo cpupower frequency-set -r -g performance
    sudo cpupower idle-set -d 1
}

function reset_env {
	unset HIP_FORCE_DEV_KERNARG
	rocm-smi -r
	sudo sh -c echo 1 > /proc/sys/kernel/numa_balancing
}

function check_env {
	echo ""
	echo "---------------------------------------------------------------"
	echo ""

	# check the flag to force kernel to be on device memory
	echo "1. Check forcing kernel args on device memory"
	dev_kernarg=$(env | grep HIP_FORCE_DEV_KERNARG)
	if [ -z $dev_kernarg ]
	then
		echo "  no setting for forcing kernel args on device memory"
		echo "  run the command \"export HIP_FORCE_DEV_KERNARG=1\" to force it"
	else
		echo "  env var \"HIP_FORCE_DEV_KERNARG\" for forcing kernel args on device"
		echo "  memory is set, we have HIP_FORCE_DEV_KERNARG=" $HIP_FORCE_DEV_KERNARG
		if [ "$HIP_FORCE_DEV_KERNARG" -eq 0 ]
		then
			echo "  env var HIP_FORCE_DEV_KERNARG is 0, set it to 1 by:"
			echo "  command \"export HIP_FORCE_DEV_KERNARG=1\""
		fi
	fi

	echo ""
	echo ""
	echo "2. Set perfdeterminism, highest frequency"
	echo "  run the command \"rocm-smi -a | grep sclk\" to check highest frequency."
	echo "  you can run the command \"rocm-smi --setperfdeterminism # (e.g. 1900)\" to"
	echo "  set clock frequency limit to get minimal performance, which is more reproducible"
	echo "  you can restore the setting by running \"rocm-smi --resetperfdeterminism\""
	
	echo ""
	echo ""
	echo "3. Check numa autobalance"
	autobal=$(cat /proc/sys/kernel/numa_balancing)
	if [ $autobal -ne 0 ]
	then
		echo "  run the command \"sudo sh -c \'echo 0 > /proc/sys/kernel/numa_balancing\'\""
		echo "  to set numa autobalance". 
		echo "  you can disable it with \"sudo sh -c \'echo 1 > /proc/sys/kernel/numa_balancing\'\""
	else
		echo "  numa autobalance is checked with:"
		echo "  (cat /proc/sys/kernel/numa_balancing)=0"
	fi

	echo ""
	echo "---------------------------------------------------------------"
	echo ""
}


if [ $# -eq 0 ]
then
	echo "   \"env_set.sh -h\" for help info"
	print_usage
	exit 1
fi

input=$1
if [ $1 == "set" ]
then
	set_env
elif [ $1 == "reset" ]
then
	reset_env
elif [ $1 == "check" ]
then
	check_env
else
	print_usage
fi

