FROM docker.io/i386/alpine:3.21.0

ENV KERNEL=virt

# BashTab dependencies: bash, fzf, git (for cloning), ncurses (for fzf/tput)
# coretuils, findutils, grep, bash-completion for the usual Linux experience
RUN apk add --no-cache openrc alpine-base agetty alpine-conf linux-${KERNEL} linux-firmware-none \
    bash fzf git ncurses ncurses-terminfo-base coreutils findutils grep bash-completion \
    musl-locales jq gawk

# Set up autologin on tty1 (VGA) and ttyS0 (serial)
RUN sed -i 's/getty 38400 tty1/agetty --autologin root tty1 linux/' /etc/inittab
RUN echo 'ttyS0::respawn:/sbin/agetty --autologin root -s ttyS0 115200 vt100' >> /etc/inittab
RUN echo "root:" | chpasswd

# Set bash as root's default shell
RUN sed -i 's|root:.*|root:x:0:0:root:/root:/bin/bash|' /etc/passwd

RUN setup-hostname localhost

# Networking setup script
RUN echo -e "rmmod ne2k-pci && modprobe ne2k-pci\nrmmod virtio-net && modprobe virtio-net\nhwclock -s\nsetup-interfaces -a -r" > /root/networking.sh && chmod +x /root/networking.sh

# ── BashTab ──────────────────────────────────────────────
# Copy the BashTab source into the image
COPY ./ /opt/bash-tab/

# Source BashTab in .bashrc so it's active on login
RUN printf '\n# BashTab\nsource /opt/bash-tab/activate\n' >> /root/.bashrc
# Also for /etc/bash/bashrc so it works system-wide
RUN printf '\n# BashTab\nsource /opt/bash-tab/activate 2>/dev/null || true\n' >> /etc/bash/bashrc

# Create a welcome message
RUN printf '\ncat /etc/motd\n' >> /root/.bashrc
RUN printf \
    '\n'\
    '╔══════════════════════════════════════════════════╗\n'\
    '║              🐚  BashTab  Demo  🐚               ║\n'\
    '║                                                  ║\n'\
    '║  Try these commands:                              ║\n'\
    '║    bu           — list all commands              ║\n'\
    '║    bu <TAB>     — fzf autocomplete               ║\n'\
    '║    bu get-<TAB> — discover commands by namespace ║\n'\
    '║    bu new-command --help                         ║\n'\
    '║    bu new-module --help                          ║\n'\
    '║    bu get-module                                 ║\n'\
    '║    ls <TAB>     — file completion with metadata  ║\n'\
    '║    echo $HO<TAB> — variable completion           ║\n'\
    '║                                                  ║'\
    '╚══════════════════════════════════════════════════╝\n'\
    '\n' > /etc/motd

# Init services
RUN for i in devfs dmesg mdev hwdrivers; do rc-update add $i sysinit; done
RUN for i in hwclock modules sysctl hostname syslog bootmisc; do rc-update add $i boot; done
RUN rc-update add killprocs shutdown

# Generate initramfs with 9p and virtio modules
RUN mkinitfs -F "base virtio 9p" $(cat /usr/share/kernel/$KERNEL/kernel.release)
