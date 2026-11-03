#####################################################################################
# Base image
#####################################################################################
# The shared CI (bootc-build.yml) builds Containerfile.base once per job as
# localhost/debian-bootc-base and passes it as BASE_IMAGE; the base's FROM
# (the published debian-bootc image) feeds the image content hash. See
# docs/ci-catchup-plan.md ("image build contract").
ARG BASE_IMAGE=localhost/debian-bootc-base
FROM ${BASE_IMAGE}
STOPSIGNAL SIGRTMIN+3

# Environement Setup
LABEL org.opencontainers.image.title="DaemonCores VE"
LABEL org.opencontainers.image.description="DaemonCores VE — Debian 13 Trixie"
LABEL org.opencontainers.image.base.name="ghcr.io/daemoncores/debian-bootc:latest"
LABEL org.opencontainers.image.source="https://github.com/DaemonCores/DaemonCores-VE"
LABEL org.opencontainers.image.licenses="LGPL-2.1"
LABEL containers.bootc=1
LABEL ostree.bootable=1
# GPU model: the NVIDIA driver lane belongs to debian-bootc (owner order
# 2026-11-03); VE consumes it through apt. No GPU image descriptor here —
# the -nvidia twin label and its GPU_EXTRA_PKGS RUN were removed with it.

# APT repository trust — same mechanics as debian-bootc: the full pipeline
# hashes the APT_GPG_KEY secret at every run (full-pipeline.yml apt_key job)
# and bootc-build.yml passes both build-args (BOOTC_GPG_SHA256 / BOOTC_APT_URL
# env, consumed by build-arch.sh apt_build_args). Nothing to hand-edit after a
# key rotation; the committed defaults only serve plain local podman builds.
# The sources stanza below carries the same URL (src/pvepreinstall).
ARG BOOTC_APT_URL=https://daemoncores.github.io/DaemonCores-VE/
ARG BOOTC_GPG_SHA256=4920000cfcd8f5a618822c8e57222a3c10768d2efb8c0250a71a19ba0c76ff55
# The Proxmox archive key is an upstream artifact (not our secret-derived repo
# key): its pin stays committed, refreshed with the release that fetches it.
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
    && url="${BOOTC_APT_URL%/}" \
    && wget \
        -O /usr/share/keyrings/daemoncores-ve-keyring.gpg \
        "${url}/gpg.key" \
    && printf '%s  /usr/share/keyrings/daemoncores-ve-keyring.gpg\n' "${BOOTC_GPG_SHA256}" \
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
        dc-gpu-lxc \
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
