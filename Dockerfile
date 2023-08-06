# #####################################################
# onemarcfifty/kali-linux
# #####################################################
#
# This Dockerfile will build a Kali Linux Docker 
# image with a graphical environment
#
# It loads the following variables from the env file:
# 
#  - Ports to use for VNC, SSH, and RDP 
#    (RDP_PORT, VNC_DISPLAY, VNC_PORT, SSH_PORT)
#  - Desktop environment(DESKTOP_ENVIRONMENT)
#  - Remote access software (REMOTE_ACCESS)
#  - Kali packages to install (KALI_PACKAGE)
#  - Network configuration  (NETWORK)
#  - Build platform (BUILD_PLATFORM)
#  - Local Docker image name (DockerIMG)
#  - Docker container name (CONTAINER)
#  - Host directory to mount as volume 
#  - Container directory for volume mount (HOSTDIR)
#  - Container username (USERNAME)
#  - Container user password
#
# The start script is called /startkali.sh
# and it will be built dynamically by the Docker build
# process
#
# #####################################################

FROM kalilinux/kali-rolling

ARG DESKTOP_ENVIRONMENT
ARG REMOTE_ACCESS
ARG KALI_PACKAGE
ARG SSH_PORT
ARG RDP_PORT
ARG VNC_PORT
ARG VNC_DISPLAY
ARG BUILD_ENV
ARG HOSTDIR
ARG CONTAINERDIR
ARG UNAME
ARG UPASS

ENV DEBIAN_FRONTEND noninteractive

# #####################################################
# Fix GPG errors, see https://superuser.com/questions/1644520/apt-get-update-issue-in-kali
# RUN apt -o Acquire::AllowInsecureRepositories=true -o Acquire::AllowDowngradeToInsecureRepositories=true update && apt-get -y install wget &&\
#   wget http://http.kali.org/kali/pool/main/k/kali-archive-keyring/kali-archive-keyring_2022.1_all.deb &&\
#   dpkg -i kali-archive-keyring_2022.1_all.deb && rm kali-archive-keyring_2022.1_all.deb
# #####################################################

ENV APT_OPTIONS=' -o Acquire::AllowInsecureRepositories=true -o Acquire::AllowDowngradeToInsecureRepositories=true --allow-unauthenticated '

# #####################################################
# the desktop environment to use
# if it is null then it will default to xfce
# valid choices are 
# e17, gnome, i3, i3-gaps, kde, live, lxde, mate, xfce
# #####################################################

ENV DESKTOP_ENVIRONMENT=${DESKTOP_ENVIRONMENT:-xfce}
ENV DESKTOP_PKG=kali-desktop-${DESKTOP_ENVIRONMENT}

# #####################################################
# the remote client to use
# if it is null then it will default to x2go
# valid choices are vnc, rdp, x2go
# #####################################################

ENV REMOTE_ACCESS=${REMOTE_ACCESS:-x2go}

# #####################################################
# the kali packages to install
# if it is null then it will default to "default"
# valid choices are arm, core, default, everything, 
# firmware, headless, labs, large, nethunter
# #####################################################

ENV KALI_PACKAGE=${KALI_PACKAGE:-default}
ENV KALI_PKG=kali-linux-${KALI_PACKAGE}

# #####################################################
# install packages that we always want
# #####################################################

RUN apt ${APT_OPTIONS} update -q --fix-missing  
RUN apt ${APT_OPTIONS} upgrade -y
RUN apt ${APT_OPTIONS} -y install --no-install-recommends sudo wget curl dbus-x11 xinit openssh-server ${DESKTOP_PKG}
RUN apt ${APT_OPTIONS} -y install locales
RUN sed -i s/^#\ en_US.UTF-8\ UTF-8/en_US.UTF-8\ UTF-8/ /etc/locale.gen
RUN locale-gen

# #####################################################
# create the start bash shell file
# #####################################################

RUN echo "#!/bin/bash" > /startkali.sh
RUN echo "/etc/init.d/ssh start" >> /startkali.sh
RUN chmod 755 /startkali.sh

# #####################################################
# Install the Kali Packages
# #####################################################

RUN apt ${APT_OPTIONS} -y install --no-install-recommends ${KALI_PKG}

# #####################################################
# create the non-root kali user
# #####################################################

RUN useradd -m -s /bin/bash -G sudo ${UNAME}
RUN echo "${UNAME}:${UPASS}" | chpasswd

# #####################################################
# change the ssh port in /etc/ssh/sshd_config
# When you use the bridge network, then you would
# not have to do that. You could rather add a port
# mapping argument such as -p 2022:22 to the 
# Docker create command. But we might as well
# use the host network and port 22 might be taken
# on the Docker host. Hence we change it 
# here inside the container
# #####################################################

RUN echo "Port $SSH_PORT" >>/etc/ssh/sshd_config

# #################################
# disable power manager plugin xfce
# #################################

RUN rm /etc/xdg/autostart/xfce4-power-manager.desktop >/dev/null 2>&1
RUN if [ -e /etc/xdg/xfce4/panel/default.xml ] ; \
    then \
        sed -i s/power/fail/ /etc/xdg/xfce4/panel/default.xml ; \
    fi

# #############################
# install and configure x2go
# x2go uses ssh
# #############################

RUN if [ "xx2go" = "x${REMOTE_ACCESS}" ]  ; \
    then \
        apt ${APT_OPTIONS} -y install --no-install-recommends x2goserver ; \
        echo "/etc/init.d/x2goserver start" >> /startkali.sh ; \
    fi

# #############################
# install and configure xrdp
# #############################
# currently, xrdp only works
# with the xfce desktop
# #############################

RUN if [ "xrdp" = "x${REMOTE_ACCESS}" ] ; \
    then \
            apt ${APT_OPTIONS} -y install --no-install-recommends xorg xorgxrdp xrdp ; \
            echo "rm -rf /var/run/xrdp >/dev/null 2>&1" >> /startkali.sh ; \
            echo "/etc/init.d/xrdp start" >> /startkali.sh ; \
            sed -i s/^port=3389/port=${RDP_PORT}/ /etc/xrdp/xrdp.ini ; \
            adduser xrdp ssl-cert ; \
            if [ "xfce" = "${DESKTOP_ENVIRONMENT}" ] ; \
            then \
                echo xfce4-session > /home/${UNAME}/.xsession ; \
                chmod +x /home/${UNAME}/.xsession ; \
            fi ; \
    fi

# ###########################################################
# install and configure tigervnc-standalone-server
# ###########################################################
# this needs a bit more tweaking than the other protocols
# we need to set the mandatory security options,
# the password for the connection, the port to use
# and also define the ${UNAME} to be used for the 
# screen VNC_DISPLAY
# the password seems to be overwritten so I am hard
# setting it in the /startkali.sh script each time 
# After running tigervncsession-start, the session will
# terminate once the user logs out. Therefore
# we do a sudo -u ${UNAME} vncserver in an endless loop 
# afterwords. This way we always have a running vnc server
# ###########################################################

RUN if [ "xvnc" = "x${REMOTE_ACCESS}" ] ; \
    then \
        apt ${APT_OPTIONS} -y install --no-install-recommends tigervnc-standalone-server tigervnc-tools; \
        echo "/usr/libexec/tigervncsession-start :${VNC_DISPLAY} " >> /startkali.sh ; \
        echo "echo -e '${UPASS}' | vncpasswd -f >/home/${UNAME}/.vnc/passwd" >> /startkali.sh  ;\
        echo "while true; do sudo -u ${UNAME} vncserver -fg -v ; done" >> /startkali.sh ; \
        echo ":${VNC_DISPLAY}=${UNAME}" >>/etc/tigervnc/vncserver.users ;\
        echo '$localhost = "no";' >>/etc/tigervnc/vncserver-config-mandatory ;\
        echo '$SecurityTypes = "VncAuth";' >>/etc/tigervnc/vncserver-config-mandatory ;\
        mkdir -p /home/${UNAME}/.vnc ;\
        chown ${UNAME}:${UNAME} /home/${UNAME}/.vnc ;\
        touch /home/${UNAME}/.vnc/passwd ;\
        chown ${UNAME}:${UNAME} /home/${UNAME}/.vnc/passwd ;\
        chmod 600 /home/${UNAME}/.vnc/passwd ;\
    fi

# ###########################################################
# The /startkali.sh script may terminate, i.e. if we only 
# have statements inside it like /etc/init.d/xxx start
# then once the startscript has finished, the container 
# would stop. We want to keep it running though.
# therefore I just call /bin/bash at the end of the start
# script. This will not terminate and keep the container
# up and running until it is stopped.
# ###########################################################

RUN echo "/bin/bash" >> /startkali.sh

# ###########################################################
# expose the right ports and set the entrypoint
# ###########################################################

EXPOSE ${SSH_PORT} ${RDP_PORT} ${VNC_PORT}
WORKDIR "/root"
ENTRYPOINT ["/bin/bash"]
CMD ["/startkali.sh"]