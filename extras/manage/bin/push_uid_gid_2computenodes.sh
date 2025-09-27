#!/bin/bash
# Copyright (c) 2025 Advanced Micro Devices, Inc. All Rights Reserved.
# Description: Script to push uids, gids and add to slurm partitions
# Author: Bob.Robey@amd.com
# Revision: V1.0
# V1.0: Initial version
# Heavily modified from Ozzie Moreno's script

DRY_RUN=0
VERBOSE=1

# Save users from /etc/passwd to users.txt
#awk -F: '$3 >= 8000 && $3 < 9000 {print $0}' /etc/passwd > users.txt
awk -F: '$3 >= 12101 && $3 < 14000 {print $0}' /etc/passwd > users.txt
#awk -F: '$3 >= 8243 && $3 < 8244 {print $0}' /etc/passwd > users.txt

file="users.txt"

#
# Each input line divided into seven fields separated by a colon (:) character
#
CLUSTER_HOME=prerelease

#for host in `sudo cat /shared/slurmadmin/prerelease01/hostlist`
for host in `sudo cat short_hostlist`
do

   echo "=============== working on host $host"
   echo ""

   if ssh $host "true"; then
      echo "host responds: "
   else
      echo "No route to host"
      continue
   fi

   while IFS=: read -r f1 f2 f3 f4 f5 f6 f7
   do
#      logger "${CLUSTER_HOME}_uid_gid_sync: Adding users to $host"
#      logger 'prerelease_uid_gid_sync: sudo groupadd -g %s %s \n' "$f3" "$f1"
#      logger 'prerelease_uid_gid_sync: sudo useradd -u %s -g %s -G video,render,slurmusers -s /bin/bash -m -d /shared/prerelease/home/%s %s \n' "$f3" "$f3" "$f1" "$f1"

       if [ "$VERBOSE" = "1" ]; then
	  echo "============================"
          echo User $f1
          grep "^$f1:" /etc/passwd
          echo passwd entry is $(getent passwd $f1)
          echo home directory is $f6
          echo checking for user $f1 `ssh $host echo $(getent passwd $f1)`
	  echo "============================"
	  echo ""
       fi

       # Detect whether user is on compute node and add them if not
       passwd_entry=`ssh $host getent passwd $f1`
       if [ "$VERBOSE" = "1" ]; then
          echo "/etc/passwd entry is: " $passwd_entry
       fi
       if [ "$passwd_entry" = "" ]; then
          if [ "$VERBOSE" = "1" ]; then
             echo user $f1 does not exist
	  fi
	  group_entry=`ssh $host getent group $f4`
          if [ "$VERBOSE" = "1" ]; then
	     echo "/etc/group entry is ",$group_entry
	  fi
	  if [ "$group_entry" = "" ]; then
             if [ "$VERBOSE" = "1" ]; then
                echo "sudo groupadd -f -g $f4 $f1"
	     fi
             if [ "$DRY_RUN" = "1" ]; then
                echo "sudo groupadd -f -g $f4 $f1"
             else
                ssh $host "sudo groupadd -f -g $f4 $f1"
	     fi
	  fi
	  if [ -d "$f6" ]; then
             if [ "$VERBOSE" = "1" ]; then
	        echo "need to add user but home directory already exists"
                echo ssh $host "sudo useradd -u $f3 -g $f3 -G video,render,slurmusers -s /bin/bash $f1"
	     fi
             if [ "$DRY_RUN" = "1" ]; then
                echo ssh $host "sudo useradd -u $f3 -g $f3 -G video,render,slurmusers -s /bin/bash $f1"
             else
                ssh $host "sudo useradd -u $f3 -g $f3 -G video,render,slurmusers -s /bin/bash $f1"
	     fi
	  else
             if [ "$VERBOSE" = "1" ]; then
	        echo "need to add user and home directory"
	     fi
             if [ "$DRY_RUN" = "1" ]; then
                echo ssh $host "sudo useradd -u $f3 -g $f3 -G video,render,slurmusers -s /bin/bash -m -d $f6 $f1"
             else
                ssh $host "sudo useradd -u $f3 -g $f3 -G video,render,slurmusers -s /bin/bash -m -d $f6 $f1"
	     fi
	  fi
       fi

       # Get groups for user on control node
       user_groups=$(id -nG $f1 | tr " " ",")
       if [ "$VERBOSE" = "1" ]; then
          echo user_groups are $user_groups
       fi

       # Get groups for user on compute node
       current_group_list=`ssh $host id -nG $f1`
       if [ "$VERBOSE" = "1" ]; then
          echo current group list $current_group_list
       fi
 
       for group_name in `echo $user_groups | tr ',' ' '`
       do
          # Add missing groups on compute node
	  group_entry=`ssh $host getent group $group_name`
          #if [ "`ssh $host echo $(getent group $group_name)`" = "" ]; then
          if [ "$group_entry" = "" ]; then
             echo group $group_name needs to be added to compute node
             gid=`echo $(getent group $group_name) | cut -f3 -d':'`
             if [ "$VERBOSE" > "0" ]; then
                echo ssh $host "sudo groupadd -g $gid $group_name" 
	     fi
             if [ "$DRY_RUN" = "1" ]; then
                echo ssh $host "sudo groupadd -g $gid $group_name" 
	     else
                ssh $host "sudo groupadd -g $gid $group_name" 
	     fi
          fi
          # Checking and reporting what groups a user needs to be added to
          if [ "$VERBOSE" = "1" ]; then
             echo Checking whether $f1 is a member of group $group_name on compute node
	     user_member_of_group=`echo $current_group_list | tr ' ' '\n' | grep -w $group_name`
	     if [ "$user_member_of_group" == "" ]; then
                echo user $f1 is not a member of group $group_name on compute node
	     fi
	  fi
          # Add user to their groups that are missing on compute node
          if [ "`echo $current_group_list | tr ' ' '\n' | grep -w $group_name`" == "" ];then
             if [ "$VERBOSE" = "1" ]; then
                echo user $f1 needs to be addd to group $group_name
	     fi
             if [ "$DRY_RUN" = "1" ]; then
                echo ssh $host "sudo usermod -aG $group_name $f1"
	     else
                ssh $host "sudo usermod -aG $group_name $f1"
	     fi
	  fi
       done

       # We should not need this since sacctmgr visible on all nodes?
       # Adding user to partitions on compute node if not currently
       #for partition_name in 1CN192C4G1H_MI300A_Ubuntu22 1CN48C1G1H_MI300A_Ubuntu22 Single_MI300A_Ubuntu22
       slurm_account=`sudo sacctmgr list associations where user=$f1 format=Account | grep -v Account | grep -v "^----" |head -1`
       for partition_name in 1CN192C4G1H_MI300A_Ubuntu22 1CN48C1G1H_MI300A_Ubuntu22
       do
          #echo $partition_name
          #echo "`sudo sacctmgr show User bobrobey --associations`"
          #echo "`sudo sacctmgr show User bobrobey --associations |grep -i ${partition_name:0:9}`"
          #sudo sacctmgr show User $f1 --associations |grep -i ${partition_name:0:9}
	  partition_entry=`ssh $host sudo sacctmgr show User $f1 --associations |grep -i ${partition_name:0:9}`
          if [ "$VERBOSE" = "1" ]; then
	     echo "partition_name: " $partition_name "partition_entry: " $partition_entry
	  fi
          if [ "$partition_entry" = "" ]; then
             if [ "$VERBOSE" = "1" ]; then
                echo does not have access to partition
		if [ "$slurm_account" = "" ]; then
                   echo sacctmgr -i add user name=$f1 partition=$partition_name
		else
                   echo sacctmgr -i add user name=$f1 partition=$partition_name account=$slurm_account
		fi
	     fi
             if [ "$DRY_RUN" = "1" ]; then
		if [ "$slurm_account" = "" ]; then
                   echo sacctmgr -i add user name=$f1 partition=$partition_name
		else
                   echo sacctmgr -i add user name=$f1 partition=$partition_name account=$slurm_account
		fi
	     else
		if [ "$slurm_account" = "" ]; then
                   sacctmgr -i add user name=$f1 partition=$partition_name
		else
                   sacctmgr -i add user name=$f1 partition=$partition_name account=$slurm_account
		fi
	     fi
          fi
       done
   done <"$file"

done

#rm -f users.txt

