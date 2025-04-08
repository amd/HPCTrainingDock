#!/bin/bash

MNT=$1

if [[ "x$MNT" == "x" ]]; then
export MNT=/data
fi

for m in sys proc dev; do
	mount --bind /${m} ${MNT}/${m}
done
