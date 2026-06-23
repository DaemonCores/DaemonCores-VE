#####################################################################################
# Base image
#####################################################################################
FROM ghcr.io/daemoncores/debian-bootc:latest

# Environement Setup
LABEL org.opencontainers.image.title="Proxmox VE Atomic"
LABEL org.opencontainers.image.description="Proxmox VE 9 Atomic — Debian 13 Trixie"
LABEL org.opencontainers.image.base.name="ghcr.io/daemoncores/debian-bootc:latest"
LABEL org.opencontainers.image.source="https://github.com/DaemonCores/Proxmox-Atomic"
LABEL org.opencontainers.image.licenses="LGPL-2.5"
LABEL containers.bootc=1
LABEL ostree.bootable=1

# SHA-256 checksum of the bootc APT repository signing key fetched below.
# Update this value whenever the key at
# https://daemoncores.github.io/debian-bootc/gpg.key is rotated.
ARG PVE_GPG_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
# Setup all environement variables
ENV DEBIAN_FRONTEND=noninteractive
# Setup default shell with fail build on error
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Proxmox setup
COPY ./src/pvepreinstall /
RUN chmod +x /usr/sbin/policy-rc.d \
    && wget \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        -O /usr/share/keyrings/proxmox-archive-keyring.gpg \
    && printf '%s  /usr/share/keyrings/proxmox-archive-keyring.gpg\n' "${PVE_GPG_SHA256}" \
        | sha256sum -c - \
    && echo "postfix postfix/main_mailer_type string Local only" | debconf-set-selections \
    && echo "postfix postfix/mailname string proxmox.local" | debconf-set-selections \
    && echo "grub-pc grub-pc/install_devices_empty boolean true" | debconf-set-selections \
    && apt update \
    && apt full-upgrade -y \
    && apt install -y \
        proxmox-default-kernel \
        proxmox-ve \
        postfix \
        open-iscsi \
        chrony \
        systemd-zram-generator \
        dnsmasq \
    && apt remove -y \
        linux-image-amd64 \
        os-prober \
        $(dpkg -l 'linux-image-[0-9]*' | awk '/^ii/{print $2}' | grep -v proxmox) \
    2>/dev/null || true \
    && KVER=$(ls -1v /usr/lib/modules | tail -1) \
    && find /usr/lib/modules -mindepth 1 -maxdepth 1 ! -name "${KVER}" -exec rm -rf {} +

# Post install patch
COPY ./src/pvepostinstall /
RUN echo "vm.swappiness = 1" >> /etc/sysctl.conf \
    && chmod +x /usr/local/bin/* \
    && mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -sf /etc/systemd/system/pve-domain-set.service \
        /etc/systemd/system/multi-user.target.wants/pve-domain-set.service \
    && ln -sf /etc/systemd/system/proxmox-firstboot.service \
        /etc/systemd/system/multi-user.target.wants/proxmox-firstboot.service \
    && removepvepopup \
    && rm -f /etc/apt/sources.list.d/pve-install-repo.sources \
        /tmp/* \
        /var/tmp/* \
        /usr/sbin/policy-rc.d
