#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo
echo Manage the Hack-a-thon environment...
echo
sleep 1

#source inc/managerUser.sh

opt1="Manage Users"
opt2="Manage SLURM"


PS3='Please enter your choice: '
options=("${opt1}" \
         "${opt2}" \
         "Quit")


select opt in "${options[@]}"
do
    case $opt in
        "${opt1}")
            echo "you chose ${opt1}"
	    ${SCRIPT_DIR}/inc/manageUsers.sh 
            ;;
        "${opt2}")
            echo "you chose ${opt2}"
	    ${SCRIPT_DIR}/inc/manageSlurm.sh
            ;;
        "Quit")
            break
            ;;
        *) echo "invalid option $REPLY";;
    esac
    echo "1) Manage Users"
    echo "2) Manage SLURM"
    echo "3) Quit"
done
