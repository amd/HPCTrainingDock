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

source userlist.sh

SHARED="/datasets/teams/hackathon-testing"
#SHARED="/home"

# note these uid/gids are only for Containers for Bob Robey.
# you MUST use other number for other Containers !

HACKATHONBASEUSER=12050
HACKATHONGROUP=12000

i=0

#uncomment
sudo groupadd -f -g ${HACKATHONGROUP} hackathon
sudo usermod -a -G  ${HACKATHONGROUP} teacher


if [ ! -f /users/default/aac1.termsOfUse.txt ]; then
   sudo cp ${HOME}/aac1.termsOfUse.txt /users/default
   sudo chmod 666 /users/default/aac1.termsOfUse.txt
fi
if [ ! -f /users/default/bash_profile ]; then
   sudo cp ${HOME}/bash_profile /users/default
   sudo chmod 666 /users/default/bash_profile
fi

for u  in "${users[@]}"
do
    IFS=",", read -r -a arr <<< "${u}"

    ((i=i+1))
    first="${arr[0]}"
    last="${arr[1]}"
    uid="${arr[2]}"
    key="${arr[3]}"
    pw="${arr[4]}"
    echo
    echo
    echo
    echo "first : ${first}"
    echo "last : ${last}"
    echo "userid : ${uid}"
    echo "key : ${key}"
    echo "pw : ${pw}"
    echo

    # Check for blank entries
    if [ -z ${uid} ]; then
       echo "Skipping -- username ${uid} is blank"
       continue;
    fi

    # see if user already exists
    if id "${uid}" &>/dev/null; then
       echo "user ${uid} already exists."
       # uncomment next line to remove existing student userids if so desired
       # sudo deluser ${uid}
       # sudo deluser --remove-home ${uid}
    else
       id=$((HACKATHONBASEUSER+i))
       # echo "user ${uid} was not found. adding the user now..."
       echo "add user ${uid}  now..."
       echo useradd --create-home --skel /users/default --shell /bin/bash --home ${SHARED}/${uid}  --uid $id --gid ${HACKATHONGROUP} ${uid}
       sudo useradd --create-home --skel /users/default --shell /bin/bash --home ${SHARED}/${uid}  --uid $id --gid ${HACKATHONGROUP} ${uid}
       echo "${uid}:${pw}"
       # add the user account and set password
       if [ ! -z "${pw}" ]; then
          echo ${uid}:${pw} | sudo chpasswd
       fi
     fi

     #  # add groups for access to the GPU (see /dev/dri /dev/kfd)
     #sudo usermod -a -G audio,video,render,renderalt ${uid}
     sudo usermod -a -G audio,video,render ${uid}
     # add the ssh key to the users authorized_keys file
     sudo chmod a+rwx  ${SHARED}/${uid}
     if [ ! -z "${key}" ]; then
        sudo mkdir -p  ${SHARED}/${uid}/.ssh
        sudo chgrp teacher  ${SHARED}/${uid}/.ssh
        sudo chmod g+rwx  ${SHARED}/${uid}/.ssh
        sudo touch  ${SHARED}/${uid}/.ssh/authorized_keys
        sudo chmod a+rwx     ${SHARED}/${uid}/.ssh/authorized_keys
        sudo echo "${key}" > key.txt 
        sudo scp -p key.txt  ${SHARED}/${uid}/.ssh/authorized_keys
        sudo chmod 600       ${SHARED}/${uid}/.ssh/authorized_keys
        sudo chown ${uid}    ${SHARED}/${uid}/.ssh
        sudo chown ${uid}    ${SHARED}/${uid}/.ssh/authorized_keys
        sudo rm key.txt 
	# straighten out permissions otherwise ssh will not work for logons
        sudo chmod a-rwx  ${SHARED}/${uid}/.ssh/authorized_keys
        sudo chmod u+rw   ${SHARED}/${uid}/.ssh/authorized_keys
        sudo chmod a-rwx  ${SHARED}/${uid}/.ssh
        sudo chmod u+rwx  ${SHARED}/${uid}/.ssh
     fi
     sudo chmod a-rwx  ${SHARED}/${uid}
     sudo chmod u+rwx  ${SHARED}/${uid}
     if [ ! -f ${SHARED}/${uid}/.bash_profile ]; then
         sudo cp /users/default/bash_profile ${SHARED}/${uid}/.bash_profile
         sudo chown ${uid} ${SHARED}/${uid}/.bash_profile
         sudo chmod 600 ${SHARED}/${uid}/.bash_profile
     fi 
done
