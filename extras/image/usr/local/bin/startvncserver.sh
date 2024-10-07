#!/bin/bash
# Find an available display and set ports for VNC and NoVNC
for i in $(seq 0 9); do
    if [ ! -e /tmp/.X${i}-lock -a ! -e /tmp/.X11-unix/X${i} ]; then
        DISP=$i
        break
    fi
done
if [ -z "$DISP" ]; then
    echo "Cannot find a free DISPLAY port"
    exit
fi
mkdir $HOME/.log
Xorg -noreset +extension GLX +extension RANDR +extension RENDER -logfile $HOME/.log/Xorg_X$DISP.log 
     -config $HOME/.config/xorg_X$DISP.conf :$DISP &> $HOME/.log/Xorg_X${DISP}_err.log &
XORG_PID=$!
ps $XORG_PID > /dev/null || { cat $HOME/.log/Xorg_X${DISP}_err.log && exit -1; }
lxsession -s LXDE -e LXDE

if [ ! -f $HOME/.vnc/passwd ]; then
   /usr/bin/x11vnc -storepasswd
fi
touch $HOME/.Xauthority
/usr/bin/x11vnc -display :$DISP -auth $HOME/.Xauthority -rfbauth $HOME/.vnc/passwd \
    --autoport n -forever -loop -noxdamage -repeat -shared -capslock -nomodtweak &
sleep 5
