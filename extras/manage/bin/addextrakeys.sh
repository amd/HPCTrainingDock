#!/bin/bash

Help()
{
   # Display Help
   echo "Add description of the script functions here."
   echo
   echo "Syntax: scriptTemplate [-g|h|v|V]"
   echo "options:"
   echo "g     Print the GPL license notification."
   echo "h     Print this Help."
   echo "v     Verbose mode."
   echo "V     Print software version and exit."
   echo
}

source extrakeylist.sh

SHARED="/datasets/teams/hackathon-testing"

for u  in "${users[@]}"
do
    IFS=",", read -r -a arr <<< "${u}"

    first="${arr[0]}"
    last="${arr[1]}"
    username="${arr[2]}"
    pw="${arr[3]}"


    sudo cat ${SHARED}/${username}/.ssh/authorized_keys
    echo ${pw} | sudo tee -a ${SHARED}/${username}/.ssh/authorized_keys
    echo ""
done
