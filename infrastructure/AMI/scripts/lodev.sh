#!/bin/bash

# get the first available loopback device
if [[ -e lodev.data ]]; then
	# the current in use 
	cat lodev.data
	# or ...
else
	# the next free device
	losetup -f > lodev.data
	cat lodev.data
fi
