#!/bin/bash

VERBOSE=1
DRYRUN=0

source grouplist.sh

for u  in "${groups[@]}"
do
   IFS=",", read -r -a arr <<< "${u}"

   ((i=i+1))
   group_name="${arr[0]}"
   users=()
   users=("${arr[@]:1}")

   echo "Group is $group_name. Users are ${users[@]}"

   GROUP_NAME_EXIST=`getent group $group_name | cut -d: -f3 | wc -l`
   #echo "Group exist is ${GROUP_EXIST}"
   if [[ "${GROUP_NAME_EXIST}" != "1" ]]; then
      echo "group $group_name is missing from /etc/group -- creating it"
      if (( "${VERBOSE}" > 0 )); then
         echo "  sudo groupadd $group_name"
      fi
      if [ "${DRYRUN}" != 1 ]; then
         sudo groupadd $group_name
      fi
      if [[ ! -d /Shared/$group_name ]]; then
         echo "Group shared directory at /Shared/$group_name does not exist -- creating it"
         if (( "${VERBOSE}" > 0 )); then
            echo "  sudo mkdir /Shared/$group_name"
         fi
         if [ "${DRYRUN}" != 1 ]; then
            sudo mkdir /Shared/$group_name
         fi
      fi
      if (( "${VERBOSE}" > 0 )); then
         echo "  sudo chgrp $group_name /Shared/$group_name"
         echo "  sudo chmod g+rwx /Shared/$group_name"
      fi
      if [ "${DRYRUN}" != 1 ]; then
         sudo chgrp $group_name /Shared/$group_name
         sudo chmod g+rwx /Shared/$group_name
      fi
   else
      echo "Group $group_name already exists in /etc/group"
   fi
   for user in "${users[@]}"
   do
      USER_EXISTS=`id -u "$user" 2>/dev/null`
      #echo "USER_EXISTS $USER_EXISTS"
      if [ "${USER_EXISTS}x" != "x" ]; then
         USER_BELONGS_TO_GROUP=`id -nG "$user" | grep -w "$group_name"`
         #echo "USER_BELONGS_TO_GROUP $USER_BELONGS_TO_GROUP"
         if [[ "${USER_BELONGS_TO_GROUP}x" = "x" ]]; then
            echo "user $user does not belong to group $group_name"
               if (( "${VERBOSE}" > 0 )); then
               echo "  sudo usermod -a -G $group_name $user"
            fi
            if [ "${DRYRUN}" != 1 ]; then
               sudo usermod -a -G $group_name $user
            fi
         else
            echo "user $user already belongs to group $group_name"
         fi
      else
         echo "user $user does not exist -- skipping"
      fi
   done
done
