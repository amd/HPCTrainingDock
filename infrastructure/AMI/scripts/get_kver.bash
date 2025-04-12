#!/bin/bash
T=$1
dpkg -l --root=$T | grep linux-image- | grep -v meta | head -1 | perl -lane 'print $F[1] =~ /linux-image-(.*)/'
