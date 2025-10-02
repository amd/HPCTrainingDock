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

HOMEDIR_BASE=/shared/prerelease/home
#HOMEDIR_BASE=/users

# note these uid/gids are only for Containers for Bob Robey.
# you MUST use other number for other Containers !

HACKATHONBASEUSER=12050
HACKATHONBASEGROUP=12000

CLUSTER_NAME="prerelease01"

PARTITION1="1CN192C4G1H_MI300A_Ubuntu22"
PARTITION2="1CN48C1G1H_MI300A_Ubuntu22"

DRYRUN=0
VERBOSE=1

source userlist.sh

i=0

HACKATHONLASTUSER=$((HACKATHONBASEUSER-1))
HACKATHONLASTGROUP=$((HACKATHONBASEGROUP-1))

if [ ! -d "$HOMEDIR_BASE" ]; then
   sudo mkdir -p $HOMEDIR_BASE
fi

# First see what user ids and group ids are used by files in 
# the Home directory tree and set the max to 
echo "Starting scan for last used uid and gid in our range (12050, 12000) respectively"
while read -r -d '' file
do
   uid=`sudo stat -c %u $file`
   if [[ ! -z "$uid" ]]; then
      if (( $uid > ${HACKATHONLASTUSER} )); then
         HACKATHONLASTUSER=$uid
      fi
   fi
   gid=`sudo stat -c %g $file`
   if [[ ! -z "$gid" ]]; then
      if (( $gid > ${HACKATHONLASTGROUP} )); then
         HACKATHONLASTGROUP=$gid
      fi
   fi
   #echo "User id is $uid Group id is $gid for file $file"
done < <(sudo find ${HOMEDIR_BASE} -maxdepth 2 -print0)
echo ""
echo "After home directory scan last User id is $HACKATHONLASTUSER Group id is $HACKATHONLASTGROUP"
echo ""

echo "Starting scan of /etc/group and /etc/passwd for used gids and uids"
while IFS='' read -r line; do
   gid=`echo $line | cut -d':' -f 3`
   #echo "Group id is $ggid"
   if [[ ! -z "$gid" ]]; then
      if (( $gid > 15000 )); then
         continue
      fi
      if (( $gid > ${HACKATHONLASTGROUP} )); then
         HACKATHONLASTGROUP=$gid
      fi
   fi
done < /etc/group
while IFS='' read -r line; do
   uid=`echo $line | cut -d':' -f 3`
   gid=`echo $line | cut -d':' -f 4`
   #echo "User id is $uuid Group id is $gid"
   if [[ ! -z "$gid" ]]; then
      if (( $gid > ${HACKATHONLASTGROUP} )); then
         if (( $gid < 15000 )); then
            HACKATHONLASTGROUP=$gid
         fi
      fi
   fi
   if [[ ! -z "$uid" ]]; then
      if (( $uid > ${HACKATHONLASTUSER} )); then
         if (( $uid < 15000 )); then
            HACKATHONLASTUSER=$uid
         fi
      fi
   fi
done < /etc/passwd

HACKATHONBASEUSER=$((HACKATHONLASTUSER+1))
HACKATHONBASEGROUP=$((HACKATHONLASTGROUP+1))

echo ""
echo "Base User id is $HACKATHONBASEUSER Group id is $HACKATHONBASEGROUP"
echo ""

#uncomment
#sudo groupadd -f -g ${HACKATHONGROUP} hackathon
#sudo usermod -a -G  ${HACKATHONGROUP} teacher

#if [ ! -f /home/amd/aac6.termsOfUse.txt ]; then
#   if (( "${VERBOSE}" > 1 )); then
#      echo "sudo cp ${HOME}/aac6.termsOfUse.txt /home/amd"
#      echo "sudo chmod 666 /home/amd/aac6.termsOfUse.txt"
#   fi
#   if [ "${DRYRUN}" != 1 ]; then
#      sudo cp ${HOME}/aac6.termsOfUse.txt /home/amd
#      sudo chmod 666 /home/amd/aac6.termsOfUse.txt
#   fi
#fi
#if [ ! -f /home/amd/init_scripts/bashrc ]; then
#   if (( "${VERBOSE}" > 1 )); then
#      echo "sudo cp ${HOME}/init_scripts/bashrc /home/amd"
#      echo "sudo chmod 666 /home/amd/init_scripts/bashrc"
#   fi
#   if [ "${DRYRUN}" != 1 ]; then
#      sudo cp ${HOME}/init_scripts/bashrc /home/amd
#      sudo chmod 666 /home/amd/init_scripts/bashrc
#   fi
#fi

for u  in "${users[@]}"
do
   IFS=",", read -r -a arr <<< "${u}"

   ((i=i+1))
   first="${arr[0]}"
   last="${arr[1]}"
   user_name="${arr[2]}"
   group_name="${arr[3]}"
   sshkey="${arr[4]}"
   pw="${arr[5]}"

   echo
   echo "======================================"
   echo "first : ${first}"
   echo "last : ${last}"
   echo "username : ${user_name}"
   echo "groupname : ${group_name}"
   echo "sshkey : ${sshkey}"
   echo "pw : ${pw}"
   echo

   # Check for blank entries
   if [ -z ${user_name} ]; then
      echo "Skipping -- username ${user_name} is blank"
      continue;
   fi

   if id "${user_name}" &>/dev/null; then
      #==================================
      # User already exists in the system
      #==================================
      uid=`getent passwd $user_name | cut -d: -f3`
      gid=`getent passwd $user_name | cut -d: -f4`
      USERHOMEDIR=`getent passwd $user_name | cut -d: -f6`
      echo "User $user_name already exists as UID $uid, GID $gid and home directory $USERHOMEDIR in the /etc/passwd file"

      #echo "Group id is $gid group name is $group_name"
      GROUP_NAME_EXIST=`getent group $group_name | cut -d: -f3 | wc -l`
      #echo "Group exist is ${GROUP_EXIST}"
      if [[ "${GROUP_NAME_EXIST}" != "1" ]]; then
         GROUP_ID_EXIST=`getent group $gid | cut -d: -f3 | wc -l`
         if [[ "${GROUP_ID_EXIST}" != "1" ]]; then
            # create the group using the gid listed in the /etc/passwd file
            echo "group $group_name is missing from /etc/group -- creating it"
            if (( "${VERBOSE}" > 0 )); then
               echo "  sudo groupadd -f -g ${gid} $group_name"
	       echo "  sudo sacctmgr -i add account name=$group_name cluster=$CLUSTER_NAME"
            fi
            if [ "${DRYRUN}" != 1 ]; then
               sudo groupadd -f -g ${gid} $group_name
	       sudo sacctmgr -i add account name="$group_name" cluster="$CLUSTER_NAME"
            else
               echo "  sudo groupadd -f -g ${gid} $group_name"
	       echo "  sudo sacctmgr -i add account name=$group_name cluster=$CLUSTER_NAME"
            fi
         else
            echo "Adding user to group $group_name and making it the primary group for the user"
            if (( "${VERBOSE}" > 0 )); then
               echo "  sudo usermod -a -G ${group_name}"
               echo "  sudo usermod -g ${group_name}"
	       echo " sudo sacctmgr -i add account name="$group_name" cluster="$CLUSTER_NAME""
            fi
            if [ "${DRYRUN}" != 1 ]; then
               sudo usermod -a -G ${group_name} ${user_name}
               sudo usermod -g ${group_name} ${user_name}
	       sudo sacctmgr -i add account name="$group_name" cluster="$CLUSTER_NAME"
            fi
         fi
      fi
      # Need to add a group for the home directory if it doesn't match the user's group id
      gid_homedir=`sudo stat -c %g $USERHOMEDIR`
      if id -g "$user_name" | grep -qw "$gid_homedir"; then
         GROUP_ID_EXIST=`getent group $gid_homedir | cut -d: -f3 | wc -l`
         #echo "GROUP_ID_EXIST is $GROUP_ID_EXIST"
         if [[ "${GROUP_ID_EXIST}" != "1" ]]; then
            GROUP_NAME_HOMEDIR=${group_homedir}
            echo "Adding missing group for home directory ${GROUP_NAME_HOMEDIR}"
            if (( "${VERBOSE}" > 0 )); then
               echo "  sudo groupadd -f -g $group_homedir ${GROUP_NAME_HOMEDIR}"
            fi
            if [ "${DRYRUN}" != 1 ]; then
               sudo groupadd -f -g $group_homedir ${GROUP_NAME_HOMEDIR}
            fi
         else
            GROUP_NAME_HOMEDIR=`getent group $gid_homedir | cut -d: -f1`
         fi
         echo "Adding group of home directory ${GROUP_NAME_HOMEDIR} to user"
         if (( "${VERBOSE}" > 0 )); then
            echo "  sudo usermod -a -G ${GROUP_NAME_HOMEDIR}"
         fi
         if [ "${DRYRUN}" != 1 ]; then
            sudo usermod -a -G ${GROUP_NAME_HOMEDIR} ${user_name}
         fi
      fi
   else 
      #======================================================================
      # Check if home directory exists and we need to just add the user entry
      #======================================================================
      USERHOMEDIR=`sudo find $HOMEDIR_BASE -maxdepth 2 -name $user_name -print`
      if [[ "$USERHOMEDIR" != "" ]]; then
         uid=`sudo stat -c %u $USERHOMEDIR`
         gid=`sudo stat -c %g $USERHOMEDIR`
         GROUP_EXIST=`getent group $group_name | cut -d: -f4 | wc -l`
         #echo "Group exist is ${GROUP_EXIST}"
         if [[ "${GROUP_EXIST}" != "1" ]]; then
            # should add a check that the subdirectory matches the group name?
            echo "home directory exists, but group for it does not. Adding group"
            if (( "${VERBOSE}" > 0 )); then
               echo "  sudo groupadd -f -g ${gid} $group_name"
            fi
            if [ "${DRYRUN}" != 1 ]; then
               sudo groupadd -f -g ${gid} $group_name
            fi
         fi
         echo "home directory exists, but user does not. Adding user"
         if (( "${VERBOSE}" > 0 )); then
            echo "  sudo useradd --shell /bin/bash --home ${USERHOMEDIR} --uid $uid --gid ${gid} ${user_name}"
         fi
         if [ "${DRYRUN}" != 1 ]; then
            sudo useradd --shell /bin/bash --home ${USERHOMEDIR} --uid $uid --gid ${gid} ${user_name}
         fi

         # Need to add a group for the home directory if it doesn't match the user's group id
         gid_homedir=`sudo stat -c %g $USERHOMEDIR`
         if [ $gid != "$gid_homedir" ]; then
            GROUP_ID_EXIST=`getent group $gid_homedir | cut -d: -f3 | wc -l`
            #echo "GROUP_ID_EXIST is $GROUP_ID_EXIST"
            if [[ "${GROUP_ID_EXIST}" != "1" ]]; then
               GROUP_NAME_HOMEDIR=`getent group $gid_homedir | cut -d: -f1`
               echo "Adding missing group for home directory ${GROUP_NAME_HOMEDIR}"
               if (( "${VERBOSE}" > 0 )); then
                  echo "  sudo groupadd -f -g $group_homedir ${GROUP_NAME_HOMEDIR}"
               fi
               if [ "${DRYRUN}" != 1 ]; then
                  sudo groupadd -f -g $group_homedir ${GROUP_NAME_HOMEDIR}
               fi
            else
               GROUP_NAME_HOMEDIR=`getent group $gid_homedir | cut -d: -f1`
            fi
            echo "Adding group of home directory ${GROUP_NAME_HOMEDIR} to user"
            if (( "${VERBOSE}" > 0 )); then
               echo "  sudo usermod -a -G ${GROUP_NAME_HOMEDIR}"
            fi
            if [ "${DRYRUN}" != 1 ]; then
               sudo usermod -a -G ${GROUP_NAME_HOMEDIR}
            fi
         fi
         # set password
         if [ ! -z "${pw}" ]; then
            echo "Password requested for ${user_name}:${pw}"
            if [ "${DRYRUN}" != 1 ]; then
               echo ${user_name}:${pw} | sudo chpasswd
            fi
         else
            if (( "${VERBOSE}" > 0 )); then
               echo "No password requested for ${user_name}"
            fi
         fi
      else
         #================================================================
         # Neither user exists in /etc/passwd or home directory exists, so
         #   create a user from scratch
         #================================================================
         echo "User does not exist and home directory does not exist"
         if [ "$group_name" != "" ]; then
            GROUP_EXIST=`getent group $group_name | cut -d: -f4 | wc -l`
            #echo "Group exist is ${GROUP_EXIST}"
            if [[ "${GROUP_EXIST}" != "1" ]]; then
               # should add a check that the subdirectory matches the group name?
               echo "Group does not exist -- creating group"
               if (( "${VERBOSE}" > 0 )); then
                  echo "  sudo groupadd -f -g ${HACKATHONBASEGROUP} $group_name"
               fi
               if [ "${DRYRUN}" != 1 ]; then
                  sudo groupadd -f -g ${HACKATHONBASEGROUP} $group_name
               fi
               #echo "HACKATHONBASEGROUP=$((HACKATHONBASEGROUP+1))"
            fi
            USERHOMEDIR=${HOMEDIR_BASE}/${group_name}/${user_name}
            if [ ! -d ${HOMEDIR_BASE}/${group_name} ]; then
               sudo mkdir -p ${HOMEDIR_BASE}/${group_name}
               sudo chgrp ${group_name}  ${HOMEDIR_BASE}/${group_name}
            fi
         else
            USERHOMEDIR=${HOMEDIR_BASE}/${user_name}
         fi

         id=$((HACKATHONBASEUSER+i))
         gid=`getent group $group_name | cut -d: -f3`
         echo "User does not exist -- creating user account"
         if (( "${VERBOSE}" > 0 )); then
		 # Insert check if gid or group already exists
            echo "  sudo groupadd -f -g $id $user_name"
	    if [ "$gid" == "" ]; then
	       echo "  sudo useradd --create-home --skel $HOME/init_scripts --shell /bin/bash --home ${USERHOMEDIR} --uid $id --gid (gid=gent $group_name) ${user_name}"
            else
	       echo "  sudo useradd --create-home --skel $HOME/init_scripts --shell /bin/bash --home ${USERHOMEDIR} --uid $id --gid ${gid} ${user_name}"
	    fi
	    echo "  sudo usermod -G ${user_name} $user_name"
	 fi
         if (( "${VERBOSE}" > 1 )); then
            echo "  sudo chmod -R go-rwx  ${USERHOMEDIR}"
            echo "  sudo chgrp -R ${group_name}  ${USERHOMEDIR}"
         fi
         if [ "${DRYRUN}" != 1 ]; then
            sudo groupadd -f -g $id $user_name
            sudo useradd --create-home --skel $HOME/init_scripts --shell /bin/bash --home ${USERHOMEDIR} --uid $id --gid ${gid} ${user_name}
	    sudo usermod -G ${user_name} $user_name
            sudo chmod -R go-rwx  ${USERHOMEDIR}
            sudo chgrp -R ${user_name}  ${USERHOMEDIR}
         fi
         # set password
         if [ ! -z "${pw}" ]; then
            echo "Password requested for ${user_name}:${pw}"
            if [ "${DRYRUN}" != 1 ]; then
               echo ${user_name}:${pw} | sudo chpasswd
            fi
         else
            if (( "${VERBOSE}" > 1 )); then
               echo "No password requested for ${user_name}"
            fi
         fi
      fi
   fi

   if id "${user_name}" &>/dev/null; then
      VIDEO_GROUP=`id -nG "$user_name" | grep -w video | wc -l`
      AUDIO_GROUP=`id -nG "$user_name" | grep -w audio | wc -l`
      RENDER_GROUP=`id -nG "$user_name" | grep -w render | wc -l`
   else
      VIDEO_GROUP=0
      AUDIO_GROUP=0
      RENDER_GROUP=0
   fi

   if [ "${VERBOSE}" > 0 ]; then
      echo "sudo sacctmgr -i add user name=$user_name partition=$PARTITION1 cluster=$CLUSTER_NAME defaultaccount=$group_name"
      echo "sudo sacctmgr -i add user name=$user_name partition=$PARTITION2 cluster=$CLUSTER_NAME account=${group_name}"
   fi
   if [ "${DRYRUN}" != 1 ]; then
      sudo sacctmgr -i add user name=$user_name defaultaccount="$group_name" partition="$PARTITION1" cluster="$CLUSTER_NAME"
      sudo sacctmgr -i add user name=$user_name partition="$PARTITION2" cluster="$CLUSTER_NAME" account="${group_name}"
   else
      echo "sudo sacctmgr -i add user name=$user_name partition=$PARTITION1 cluster=$CLUSTER_NAME defaultaccount=$group_name"
      echo "sudo sacctmgr -i add user name=$user_name partition=$PARTITION2 cluster=$CLUSTER_NAME account=$group_name"
   fi
   if [[ $VIDEO_GROUP != 1 ]] || [[ $AUDIO_GROUP != 1 ]] || [[ $RENDER_GROUP != 1 ]] ; then
      if (( "${VERBOSE}" > 2 )); then
         echo "Add groups for access to the GPU (see /dev/dri /dev/kfd)"
         #sudo usermod -a -G video,audio,render, slurmusers ${user_name}
         echo "  sudo usermod -a -G video,audio,render,slurmusers ${user_name}"
      fi
      if [ "${DRYRUN}" != 1 ]; then
         sudo usermod -a -G video,audio,render,slurmusers ${user_name}
      fi
   fi
   # add the ssh key to the users authorized_keys file
   #sudo chmod a+rwx  ${USERHOMEDIR}
   if [ ! -z "${sshkey}" ]; then
      if (( "${VERBOSE}" > 1 )); then
         echo "  sudo chmod a+rwx ${USERHOMEDIR}"
      fi
      if [ "${DRYRUN}" != 1 ]; then
         sudo chmod a+rwx ${USERHOMEDIR}
      fi
      if [ ! -d ${USERHOMEDIR}/.ssh ]; then
         if (( "${VERBOSE}" > 1 )); then
            echo "  sudo mkdir -p  ${USERHOMEDIR}/.ssh"
            echo "  sudo chgrp teacher ${USERHOMEDIR}/.ssh"
            echo "  sudo chmod g+rwx ${USERHOMEDIR}/.ssh"
	 fi
         if [ "${DRYRUN}" != 1 ]; then
            sudo mkdir -p  ${USERHOMEDIR}/.ssh
            sudo chgrp teacher ${USERHOMEDIR}/.ssh
            sudo chmod g+rwx ${USERHOMEDIR}/.ssh
	 fi
      fi
      if [ ! -f ${USERHOMEDIR}/.ssh/authorized_keys ]; then
         if (( "${VERBOSE}" > 1 )); then
            echo "  sudo touch  ${USERHOMEDIR}/.ssh/authorized_keys"
	 fi
         if [ "${DRYRUN}" != 1 ]; then
            sudo touch  ${USERHOMEDIR}/.ssh/authorized_keys
	 fi
      fi
      KEY_EXIST=0
      if sudo test -f ${USERHOMEDIR}/.ssh/authorized_keys ; then
         KEY_EXIST=`sudo grep "${key}" ${USERHOMEDIR}/.ssh/authorized_keys | wc -l`
      fi
      if [ "${KEY_EXIST}" == 0 ]; then
         if (( "${VERBOSE}" > 1 )); then
            echo "  sudo chmod a+rwx ${USERHOMEDIR}/.ssh/authorized_keys"
            echo "  sudo cat ${USERHOMEDIR}/.ssh/authorized_keys > key.txt"
            echo "  sudo echo "${sshkey}" >> key.txt"
            echo "  sudo scp -p key.txt ${USERHOMEDIR}/.ssh/authorized_keys"
            echo "  sudo chmod 600 ${USERHOMEDIR}/.ssh/authorized_keys"
            echo "  sudo chown $user_name ${USERHOMEDIR}/.ssh"
            echo "  sudo chown $user_name ${USERHOMEDIR}/.ssh/authorized_keys"
            echo "  sudo chgrp $group_name ${USERHOMEDIR}/.ssh"
            echo "  sudo chgrp $group_name ${USERHOMEDIR}/.ssh/authorized_keys"
            echo "  sudo rm key.txt"
            echo "  sudo chmod a-rwx ${USERHOMEDIR}/.ssh/authorized_keys"
            echo "  sudo chmod u+rw  ${USERHOMEDIR}/.ssh/authorized_keys"
	 fi
         if [ "${DRYRUN}" != 1 ]; then
            sudo chmod a+rwx ${USERHOMEDIR}/.ssh/authorized_keys
            sudo cat ${USERHOMEDIR}/.ssh/authorized_keys > key.txt
            sudo echo "${sshkey}" >> key.txt
            sudo scp -p key.txt ${USERHOMEDIR}/.ssh/authorized_keys
            sudo chmod 600 ${USERHOMEDIR}/.ssh/authorized_keys
            sudo chown $user_name ${USERHOMEDIR}/.ssh
            sudo chown $user_name ${USERHOMEDIR}/.ssh/authorized_keys
            sudo chgrp $group_name ${USERHOMEDIR}/.ssh
            sudo chgrp $group_name ${USERHOMEDIR}/.ssh/authorized_keys
            sudo rm key.txt
            sudo chmod a-rwx ${USERHOMEDIR}/.ssh/authorized_keys
            sudo chmod u+rw  ${USERHOMEDIR}/.ssh/authorized_keys
	 fi
      fi

      if (( "${VERBOSE}" > 1 )); then
         echo "  sudo chmod a-rwx ${USERHOMEDIR}/.ssh"
         echo "  sudo chmod u+rwx ${USERHOMEDIR}/.ssh"
         echo "  sudo chmod a-rwx ${USERHOMEDIR}"
         echo "  sudo chmod u+rwx ${USERHOMEDIR}"
      fi
      if [ "${DRYRUN}" != 1 ]; then
         sudo chmod a-rwx ${USERHOMEDIR}/.ssh
         sudo chmod u+rwx ${USERHOMEDIR}/.ssh
         sudo chmod a-rwx ${USERHOMEDIR}
         sudo chmod u+rwx ${USERHOMEDIR}
      fi
   fi

   if sudo test ! -f ${USERHOMEDIR}/.bashrc ; then
      if (( "${VERBOSE}" > 2 )); then
         echo "Missing bashrc file for $user_name. Creating it"
         echo "  sudo cp /home/amd/init_scripts/bashrc ${USERHOMEDIR}/.bashrc"
         echo "  sudo chown ${user_name} ${USERHOMEDIR}/.bashrc"
         echo "  sudo chgrp ${group_name} ${USERHOMEDIR}/.bashrc"
         echo "  sudo chmod 600 ${USERHOMEDIR}/.bashrc"
      fi
      if [ "${DRYRUN}" != 1 ]; then
         sudo cp /home/amd/init_scripts/bashrc ${USERHOMEDIR}/.bashrc
         sudo chown ${user_name} ${USERHOMEDIR}/.bashrc
         sudo chgrp ${group_name} ${USERHOMEDIR}/.bashrc
         sudo chmod 600 ${USERHOMEDIR}/.bashrc
      fi
   fi
   if sudo test ! -f ${USERHOMEDIR}/.profile ; then
      if (( "${VERBOSE}" > 2 )); then
         echo "Missing profile file for $user_name. Creating it"
         echo "  sudo cp /home/amd/init_scripts/profile ${USERHOMEDIR}/.profile"
         echo "  sudo chown ${user_name} ${USERHOMEDIR}/.profile"
         echo "  sudo chgrp ${group_name} ${USERHOMEDIR}/.profile"
         echo "  sudo chmod 600 ${USERHOMEDIR}/.profile"
      fi
      if [ "${DRYRUN}" != 1 ]; then
         sudo cp /home/amd/init_scripts/profile ${USERHOMEDIR}/.profile
         sudo chown ${user_name} ${USERHOMEDIR}/.profile
         sudo chgrp ${group_name} ${USERHOMEDIR}/.profile
         sudo chmod 600 ${USERHOMEDIR}/.profile
      fi
   fi 
done
