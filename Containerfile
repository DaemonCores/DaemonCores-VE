#####################################################################################
# Base image
#####################################################################################
FROM ghcr.io/daemoncores/debian-bootc:latest
STOPSIGNAL SIGRTMIN+3

# Environement Setup
LABEL org.opencontainers.image.title="Proxmox VE Atomic"
LABEL org.opencontainers.image.description="Proxmox VE 9 Atomic — Debian 13 Trixie"
LABEL org.opencontainers.image.base.name="ghcr.io/daemoncores/debian-bootc:latest"
LABEL org.opencontainers.image.source="https://github.com/DaemonCores/Proxmox-Atomic"
LABEL org.opencontainers.image.licenses="LGPL-2.1"
LABEL containers.bootc=1
LABEL ostree.bootable=1

# SHA-256 checksums of the APT repository signing keys fetched below.
ARG PROXMOX_ATOMIC_GPG_SHA256=4920000cfcd8f5a618822c8e57222a3c10768d2efb8c0250a71a19ba0c76ff55
ARG PVE_GPG_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
# Setup all environement variables
ENV DEBIAN_FRONTEND=noninteractive
# Default shell: fail build on error. Honored with `--format docker` in CI.
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Proxmox setup
COPY ./src/pvepreinstall /
RUN chmod +x /usr/sbin/policy-rc.d \
    && wget \
        -O /usr/share/keyrings/proxmox-atomic-keyring.gpg \
        https://daemoncores.github.io/Proxmox-Atomic/gpg.key \
    && printf '%s  /usr/share/keyrings/proxmox-atomic-keyring.gpg\n' "${PROXMOX_ATOMIC_GPG_SHA256}" \
        | sha256sum -c - \
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
    && apt update \
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
    # Remove standard Debian kernels to keep only proxmox-default-kernel
    # which includes ZFS and KVM modules, then prune stale module trees so
    # only the active Proxmox kernel's modules remain on disk.
    && KVER=$(ls -1v /usr/lib/modules | tail -1) \
    && find /usr/lib/modules -mindepth 1 -maxdepth 1 ! -name "${KVER}" -exec rm -rf {} +

COPY ./assets/banner/etc /etc/

# Post install patch
# COPY ships /etc/network/interfaces with a pre-configured vmbr0 (and extra
# bridges) carrying a {{ WAN_DEVICE }} placeholder. Pre-configure default
# bridge for Proxmox VE networking — proxmox-firstboot resolves the
# placeholder to the real WAN interface at first boot.
COPY ./src/pvepostinstall /
RUN echo "vm.swappiness = 1" >> /etc/sysctl.conf \
    && chmod +x /usr/local/bin/* \
    && mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -sf /etc/systemd/system/pve-domain-set.service \
        /etc/systemd/system/multi-user.target.wants/pve-domain-set.service \
    && ln -sf /etc/systemd/system/proxmox-firstboot.service \
        /etc/systemd/system/multi-user.target.wants/proxmox-firstboot.service \
    # Guard: abort if pve-manager is missing (proxmox-ve install failed earlier).
    && dpkg -s pve-manager >/dev/null 2>&1 \
        || { echo "ERROR: pve-manager not installed; proxmox-ve install failed." >&2; exit 1; } \
    && removepvepopup \
    && rm -f /etc/apt/sources.list.d/pve-install-repo.sources \
        /tmp/* \
        /var/tmp/* \
        /usr/sbin/policy-rc.d

# bootc images are updated in-place via ostree; no runtime healthcheck applies.
HEALTHCHECK NONE
