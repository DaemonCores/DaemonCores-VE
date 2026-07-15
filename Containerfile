#####################################################################################
# Base image
#####################################################################################
FROM ghcr.io/daemoncores/debian-bootc:latest
STOPSIGNAL SIGRTMIN+3

# Environement Setup
LABEL org.opencontainers.image.title="DaemonCores VE"
LABEL org.opencontainers.image.description="DaemonCores VE — Debian 13 Trixie"
LABEL org.opencontainers.image.base.name="ghcr.io/daemoncores/debian-bootc:latest"
LABEL org.opencontainers.image.source="https://github.com/DaemonCores/DaemonCores-VE"
LABEL org.opencontainers.image.licenses="LGPL-2.1"
LABEL containers.bootc=1
LABEL ostree.bootable=1

# SHA-256 checksums of the APT repository signing keys fetched below.
ARG DAEMONCORES_VE_GPG_SHA256=4920000cfcd8f5a618822c8e57222a3c10768d2efb8c0250a71a19ba0c76ff55
ARG PVE_GPG_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
# Product display name, injected by the CI from the repo name (dashes -> spaces).
# Overrides the base's value so bootc-finalize (re-run by the pve-kernel install)
# brands the UEFI boot-entry label with this product; empty keeps the base value.
ARG PRODUCT_NAME=""
# Setup all environement variables
ENV DEBIAN_FRONTEND=noninteractive
# Default shell: fail build on error. Honored with `--format docker` in CI.
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Proxmox setup
COPY ./src/pvepreinstall /
RUN chmod +x /usr/sbin/policy-rc.d \
    && wget \
        -O /usr/share/keyrings/daemoncores-ve-keyring.gpg \
        https://daemoncores.github.io/DaemonCores-VE/gpg.key \
    && printf '%s  /usr/share/keyrings/daemoncores-ve-keyring.gpg\n' "${DAEMONCORES_VE_GPG_SHA256}" \
        | sha256sum -c - \
    && wget \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        -O /usr/share/keyrings/proxmox-archive-keyring.gpg \
    && printf '%s  /usr/share/keyrings/proxmox-archive-keyring.gpg\n' "${PVE_GPG_SHA256}" \
        | sha256sum -c - \
    && echo "postfix postfix/main_mailer_type string Local only" | debconf-set-selections \
    && echo "postfix postfix/mailname string proxmox.local" | debconf-set-selections \
    && echo "grub-pc grub-pc/install_devices_empty boolean true" | debconf-set-selections \
    && mkdir -p /usr/lib/bootc \
    && { [ -z "${PRODUCT_NAME}" ] \
        || printf '%s' "${PRODUCT_NAME}" > /usr/lib/bootc/product-name; } \
    && apt update \
    && apt full-upgrade -y \
    && apt update \
    && apt install -y \
        proxmox-default-kernel \
        proxmox-ve \
        postfix \
        open-iscsi \
        chrony \
        ksmtuned \
        dc-zramctl \
        dnsmasq \
        fanctl \
        powerctl \
        dc-firewall-seed \
        dc-config-zfs \
        proxmox-firewall \
        pvect-ostree \
        compose2bootc \
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

# Post install patch
# COPY ships /etc/hostname (a baked default so pmxcfs can create the node dir
# and pve-ssl.pem on the very first boot, before the first-boot wizard renames
# the host), a matching bootstrap /etc/hosts entry, and the Proxmox drop-in
# configs. The WAN interface + default bridges are (re)generated on boot by
# ifupdown2-autoconf; /etc/hosts is refined to the real IP by domain-set.
COPY ./src/pvepostinstall /
# NOTE: the WAN-interface autoconf and /etc/hosts FQDN pinning that used to live
# in the standalone proxmox-firstboot.service / pve-domain-set.service now run as
# networking.service drop-ins shipped by the ifupdown2 repack
# (ExecStartPre=/usr/sbin/ifupdown2-autoconf, ExecStartPost=/usr/sbin/domain-set),
# so no target.wants symlinks are needed for them here.
RUN mkdir -p /etc/systemd/system/multi-user.target.wants \
    # Guard: abort if pve-manager is missing (proxmox-ve install failed earlier).
    && dpkg -s pve-manager >/dev/null 2>&1 \
        || { echo "ERROR: pve-manager not installed; proxmox-ve install failed." >&2; exit 1; } \
    && rm -f /etc/apt/sources.list.d/pve-install-repo.sources \
        /tmp/* \
        /var/tmp/* \
        /usr/sbin/policy-rc.d \
    # Enable KSM adaptive tuning (dedup guest memory under pressure) via symlink
    && ln -sf /usr/lib/systemd/system/ksmtuned.service \
        /etc/systemd/system/multi-user.target.wants/ksmtuned.service \
    # Enable chrony via symlink (bootc-compatible, avoids systemctl enable)
    && ln -sf /lib/systemd/system/chrony.service \
        /etc/systemd/system/multi-user.target.wants/chrony.service \
    # Create chronyd alias for Anaconda (Fedora naming convention)
    && ln -sf /lib/systemd/system/chrony.service /etc/systemd/system/chronyd.service

# bootc images are updated in-place via ostree; no runtime healthcheck applies.
HEALTHCHECK NONE
