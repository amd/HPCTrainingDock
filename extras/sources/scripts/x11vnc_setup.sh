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
#${SUDO} ${DEB_FRONTEND} apt-get install -y x11vnc xvfb xserver-xorg-core fvwm lxde
${SUDO} ${DEB_FRONTEND} apt-get install -y xserver-xorg-video-dummy \
        lxde \
        x11-xserver-utils xdotool \
        xterm \
        gnome-themes-standard \
        gtk2-engines-pixbuf \
        gtk2-engines-murrine \
        libcanberra-gtk-module libcanberra-gtk3-module \
        fonts-liberation \
        xfonts-base xfonts-100dpi xfonts-75dpi xfonts-scalable xfonts-cyrillic \
        libopengl0 mesa-utils libglu1-mesa libgl1-mesa-dri libjpeg8 libjpeg62 \
        xauth xdg-utils \
        x11vnc
${SUDO} sed -i -e '/allowed_users/s/console/anybody/' /etc/X11/Xwrapper.config

#cat <<-EOF | ${SUDO} tee /usr/local/bin/startvncserver.sh
#	#!/bin/bash
#	# Find an available display and set ports for VNC and NoVNC
#	for i in \$(seq 0 9); do
#	    if [ ! -e /tmp/.X\${i}-lock -a ! -e /tmp/.X11-unix/X\${i} ]; then
#	        DISP=\$i
#	        break
#	    fi
#	done
#	if [ -z "\$DISP" ]; then
#	    echo "Cannot find a free DISPLAY port"
#	    exit
#	fi
#	mkdir \$HOME/.log
#	Xorg -noreset +extension GLX +extension RANDR +extension RENDER \
#	     -logfile \$HOME/.log/Xorg_X\$DISP.log -config \$HOME/.config/xorg_X\$DISP.conf \
#	     :\$DISP &> \$HOME/.log/Xorg_X\${DISP}_err.log &
#	XORG_PID=\$!
#	ps \$XORG_PID > /dev/null || { cat \$HOME/.log/Xorg_X\${DISP}_err.log && exit -1; }
#	lxsession -s LXDE -e LXDE
#	
#	if [ ! -f \$HOME/.vnc/passwd ]; then
#	   x11vnc -storepasswd
#	fi
#	touch \$HOME/.Xauthority
#	/usr/bin/x11vnc -display :\$DISP -auth \$HOME/.Xauthority -rfbauth \$HOME/.vnc/passwd --autoport n -forever -loop -noxdamage -repeat -shared -capslock -nomodtweak &
#	sleep 5
#EOF
#${SUDO} chmod 755 /usr/local/bin/startvncserver.sh
#
# 
#cat <<-EOF | ${SUDO} tee /usr/local/bin/stopvncserver.sh
#	#!/bin/bash
#	killall -i x11vnc
#EOF
#${SUDO} chmod 755 /usr/local/bin/stopvncserver.sh
