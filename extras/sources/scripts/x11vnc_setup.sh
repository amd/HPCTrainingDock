#!/bin/bash

# Variables controlling setup process
BUILD_X11VNC=0

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

usage()
{
    echo "Usage:"
    echo "  --build-x11vnc [ BUILD_X11VNC ] default 0-no"
    echo "  --help: this usage information"
    exit 1
}

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}


n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--build-x11vnc")
         shift
	 BUILD_X11VNC=${1}
	 reset-last
	 ;;
      "--help")
          usage
          ;;
      "--*")
          send-error "Unsupported argument at position $((${n} + 1)) :: ${1}"
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

${SUDO} apt-get update
${SUDO} ${DEB_FRONTEND} apt-get install -y x11vnc xvfb

cat <<-EOF | ${SUDO} tee /usr/bin/startvncserver.sh
	#!/bin/bash
	if [ ! -f $HOME/.vnc/passwd ]; then
	   x11vnc -storepasswd
	fi
	/usr/bin/x11vnc -display :0 -auth $HOME/.Xauthority -rfbauth $HOME/.vnc/passwd -rfbport 5900 -forever -loop -noxdamage -repeat -shared -capslock -nomodtweak -create -auth guess &
EOF
${SUDO} chmod 755 /usr/bin/startvncserver.sh

 
cat <<-EOF | ${SUDO} tee /usr/bin/stopvncserver.sh
	#!/bin/bash
	killall x11vnc
EOF
${SUDO} chmod 755 /usr/bin/stopvncserver.sh
