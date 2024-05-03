#!/bin/bash

echo
echo Manage the Users in the Hack-a-thon environment...
echo
sleep 1

SHARED="/datasets/teams/hackathon-testing"
PWPREFIX="@AmdTrain"
HACKATHONGROUP=12000
HACKATHONBASEUSER=12000

opt1="Show Users" 
opt2="Add Users" 
opt3="Change Password"
opt4="Delete User"


PS3='Please enter your choice: '
options=("${opt1}" \
         "${opt2}" \
         "${opt3}" \
         "${opt4}" \
         "Quit")

function showUserids ()
{
   grep student /etc/passwd  
}

function createUserids ()
{
  echo " " 	
  echo "Now creating 30 default student(n) userids. " 
  echo " " 	
  read -p "Continue? (Y/N): " confirm && [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]] || return 

  # create 30 userids and fixup home directories

  for ((i=1;i<=30;i++)) do
     # see if user already exists
     if id "student$i" &>/dev/null; then
       echo "user student$i already exists."
       # uncomment next line to remove existing student userids if so desired
       # sudo deluser student$i
     else
       id=$((HACKATHONBASEUSER+i))
       sudo groupadd -f -g ${HACKATHONGROUP} hackathon
       echo "user student$i was not found. adding the user now..."
       echo useradd --create-home --skel /users/default --shell /bin/bash --home ${SHARED}/student$i --password $PWPREFIX$i --uid $id --gid ${HACKATHONGROUP} student$i
       sudo useradd --create-home --skel /users/default --shell /bin/bash --home ${SHARED}/student$i --password $PWPREFIX$i --uid $id --gid ${HACKATHONGROUP} student$i
       echo 'student'$i':'$PWPREFIX$i
       echo 'student'$i':'$PWPREFIX$i | sudo chpasswd
       # add groups for access to the GPU (see /dev/dri /dev/kfd)
       sudo usermod -a -G audio,video student$i
     fi
  done
  # teacher should always have hackathon as an extra group to help the students
  sudo usermod -a -G  hackathon teacher

}

function changePassword()
{
  echo " " 
  echo "Changing a password..."
  echo " " 
  read -p "Enter userid: " user 

  if [[ "$user" =~ .*"student".* ]]; then
    if id -u "$user" >/dev/null 2>&1; then
      read -p "Enter new password: " pw
      echo "You requested changing password for " $user " to " $pw 
      read -p "Continue? (Y/N): " confirm && [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]] || return 
      echo $user":"$pw
      echo $user":"$pw | sudo chpasswd
      echo "rc=$?"
    else
      echo "User $user does not exist."
    fi
  else
    echo "You are only allowed to change passwords for student accounts."
  fi

}

function deleteUser()
{
  echo " " 
  echo "Delete an userid..."
  echo " " 
  read -p "Enter userid: " user 

  if [[ "$user" =~ .*"student".* ]]; then
     if id -u "$user" >/dev/null 2>&1; then
       echo "User $user exists and will be deleted."
       read -p "Continue? (Y/N): " confirm && [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]] || return 
       sudo deluser $user
     else
       echo "Request ignored. User $user does not exist."
     fi
  else  
     echo "Request ignored. You can only delete student userids."
  fi

}

select opt in "${options[@]}"
do
    case $opt in
        "${opt1}")
            echo "you chose ${opt1}"
	    showUserids
            ;;
        "${opt2}")
            echo "you chose ${opt2}"
	    createUserids
            ;;
        "${opt3}")
            echo "you chose ${opt3}"
	    changePassword
            ;;            
        "${opt4}")
            echo "you chose ${opt4} "
	    deleteUser
            ;;
        "Quit")
            break
            ;;
        *) echo "invalid option $REPLY";;
    esac
    echo "1) Show Users"
    echo "2) Add Users"
    echo "3) Change Password"
    echo "4) Delete User"
    echo "5) Quit"
done


