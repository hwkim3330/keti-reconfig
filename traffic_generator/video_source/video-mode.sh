#!/bin/sh
# Switch the video-source Pi between the looping file and the live webcam.
#   video-mode.sh file   # Big Buck Bunny loop (default, autostarts on boot)
#   video-mode.sh cam    # live Logitech StreamCam (HW-encoded)
case "$1" in
  cam)  sudo systemctl start video-cam ;;
  file) sudo systemctl start video-stream ;;
  *) echo "usage: video-mode.sh file|cam"
     echo "now: file=$(systemctl is-active video-stream) cam=$(systemctl is-active video-cam)"; exit 1 ;;
esac
sleep 1; echo "-> file=$(systemctl is-active video-stream) cam=$(systemctl is-active video-cam)"
