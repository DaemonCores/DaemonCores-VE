#####################################################################################
# Base image
#####################################################################################
# The shared CI (bootc-build.yml) builds Containerfile.base once per job as
# localhost/daemoncores-ve-base and passes it as BASE_IMAGE; the base's FROM
# (the published proxmox-ve-bootc vanilla image) feeds the image content
# hash. The fork layer only: every vanilla package, fix and kernel lane
# lives in proxmox-ve-bootc.
ARG BASE_IMAGE=localhost/daemoncores-ve-base
FROM ${BASE_IMAGE}
STOPSIGNAL SIGRTMIN+3

# Environement Setup
LABEL org.opencontainers.image.title="DaemonCores VE"
LABEL org.opencontainers.image.description="DaemonCores VE — the DaemonCores fork of Proxmox VE (vanilla proxmox-ve-bootc base + fork layer)"
LABEL org.opencontainers.image.base.name="ghcr.io/daemoncores/proxmox-ve-bootc:latest"
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

# Proxmox setup — the fork layer. The vanilla base image already carries the
# Proxmox installation, the PVE sources/keyring, the host config
# (hostname/hosts/motd, the drop-ins), openresolv + dnsmasq and the vanilla
# APT repo; this layer only adds the fork APT repo and installs the fork
# packages. pve-manager upgrades to the fork +dcve2 build (strictly newer
# than the vanilla +bootc1 base).
COPY ./src/pvepreinstall /
RUN chmod +x /usr/sbin/policy-rc.d \
    && url="${BOOTC_APT_URL%/}" \
    && wget \
        -O /usr/share/keyrings/daemoncores-ve-keyring.gpg \
        "${url}/gpg.key" \
    && printf '%s  /usr/share/keyrings/daemoncores-ve-keyring.gpg\n' "${BOOTC_GPG_SHA256}" \
        | sha256sum -c - \
    && echo "postfix postfix/main_mailer_type string Local only" | debconf-set-selections \
    && echo "postfix postfix/mailname string proxmox.local" | debconf-set-selections \
    && echo "grub-pc grub-pc/install_devices_empty boolean true" | debconf-set-selections \
    && mkdir -p /usr/lib/bootc \
    && { [ -z "${PRODUCT_NAME}" ] \
        || printf '%s' "${PRODUCT_NAME}" > /usr/lib/bootc/product-name; } \
    && apt update \
    && apt update \
    && apt install -y \
        pve-manager \
        dc-zramctl \
        fanctl \
        powerctl \
        dc-firewall-seed \
        dc-config-zfs \
        pvect-ostree \
        compose2bootc \
        dc-gpu-lxc \
        ifupdown2

# Post install patch
# COPY ships the fork overlay: the ddns bridge/domain/dhcp-range dnsmasq
# layout, the /etc/issue.tpl rebrand template (rendered at boot by the
# fork's ifupdown2 domain-set), and the fork systemd drop-ins. The
# hostname/hosts(.tpl)/motd and the generic resolver chain arrive from the
# vanilla base layers.
COPY ./src/pvepostinstall /
# NOTE: the WAN-interface autoconf and /etc/hosts FQDN pinning live in the
# networking.service drop-ins shipped by the fork's ifupdown2 repack
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
