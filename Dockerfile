#####################################################################################
# Base image
#####################################################################################
FROM ghcr.io/daemoncores/debian-bootc:latest

# Environement Setup
LABEL org.opencontainers.image.title="Proxmox VE"
LABEL org.opencontainers.image.description="Proxmox VE 9 bootc — Debian 13 Trixie"
LABEL org.opencontainers.image.base.name="ghcr.io/daemoncores/debian-bootc:latest"
LABEL containers.bootc=1
LABEL ostree.bootable=1

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Proxmox kernel setup
COPY ./src/pvepreinstall /

RUN rm -f /etc/apt/sources.list \
    && chmod +x \
        /usr/sbin/policy-rc.d \
        /usr/local/bin/pve-domain-set \
    && wget \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        -O /usr/share/keyrings/proxmox-archive-keyring.gpg \
    && mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -sf /etc/systemd/system/pve-domain-set.service \
        /etc/systemd/system/multi-user.target.wants/pve-domain-set.service

RUN apt update \
    && apt full-upgrade -y \
    && apt install -y proxmox-default-kernel

# Proxmox VE setup
RUN echo "postfix postfix/main_mailer_type string Local only" | debconf-set-selections \
    && echo "postfix postfix/mailname string proxmox.local" | debconf-set-selections \
    && echo "grub-pc grub-pc/install_devices_empty boolean true" | debconf-set-selections \
    && apt install -y \
        proxmox-ve \
        postfix \
        open-iscsi \
        chrony

RUN apt remove -y \
        linux-image-amd64 \
        os-prober \
        $(dpkg -l 'linux-image-[0-9]*' | awk '/^ii/{print $2}' | grep -v proxmox) \
    2>/dev/null || true

RUN KVER=$(ls -1v /usr/lib/modules | tail -1) \
    && cp /boot/vmlinuz-${KVER} /usr/lib/modules/${KVER}/vmlinuz \
    && rm -rf /boot/* \
    && dracut \
        --kver "${KVER}" \
        --force /usr/lib/modules/${KVER}/initramfs.img

# Optimisations setup
RUN apt install -y \
        systemd-zram-generator \
        dnsmasq

COPY ./src/pvepostinstall /
RUN echo "vm.swappiness = 1" >> /etc/sysctl.conf \
    && chmod +x /usr/local/bin/* \
    && ln -sf /etc/systemd/system/proxmox-firstboot.service \
        /etc/systemd/system/multi-user.target.wants/proxmox-firstboot.service \
    && removepvepopup \
    && rm -f /etc/apt/sources.list.d/pve-install-repo.sources

# Clean and purge image
RUN apt autoremove -y \
    && apt clean \
    && rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /usr/sbin/policy-rc.d
