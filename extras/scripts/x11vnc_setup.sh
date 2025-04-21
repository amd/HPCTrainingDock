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
    echo "  --build-x11vnc [ BUILD_X11VNC ] default ${BUILD_X11VNC}"
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
        x11vnc \
	novnc \
	dbus-x11
echo "Starting dbus"
${SUDO} service dbus status
${SUDO} service dbus start
echo "Checking dbus status"
${SUDO} service dbus status

#curl -O https://bootstrap.pypa.io/get-pip.py && \
#    python3 get-pip.py && \
#    pip3 install --no-cache-dir \
#        setuptools && \

#     pip3 install -U https://github.com/novnc/websockify/archive/refs/tags/v0.10.0.tar.gz && \
#     mkdir /usr/local/noVNC && \
#     curl -s -L https://github.com/x11vnc/noVNC/archive/refs/heads/x11vnc.zip | \
#           bsdtar zxf - -C /usr/local/noVNC --strip-components 1 && \
#     (chmod a+x /usr/local/noVNC/utils/launch.sh || \
#         (chmod a+x /usr/local/noVNC/utils/novnc_proxy && \
#          ln -s -f /usr/local/noVNC/utils/novnc_proxy /usr/local/noVNC/utils/launch.sh))
#    #rm -rf /tmp/* /var/tmp/*
${SUDO} sed -i -e '/allowed_users/s/console/anybody/' /etc/X11/Xwrapper.config
