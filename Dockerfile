FROM debian:trixie

LABEL org.opencontainers.image.title="Proxmox VE"
LABEL org.opencontainers.image.description="Proxmox VE 9 bootc — Debian 13 Trixie"
LABEL org.opencontainers.image.base.name="docker.io/library/debian:trixie"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update \
    && apt install -y \
        wget \
        curl

COPY ./src/preinstall /

RUN rm -f /etc/apt/sources.list \
    && chmod +x \
        /usr/sbin/policy-rc.d \
        /usr/local/bin/pve-domain-set \
    && wget \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        -O /usr/share/keyrings/proxmox-archive-keyring.gpg \
    && mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -sf /etc/systemd/system/pve-domain-set.service \
        /etc/systemd/system/multi-user.target.wants/pve-domain-set.service \
    && pve-domain-set

RUN apt update \
    && apt full-upgrade -y \
    && apt install -y proxmox-default-kernel

RUN echo "postfix postfix/main_mailer_type string Local only" | debconf-set-selections \
    && echo "postfix postfix/mailname string proxmox.local" | debconf-set-selections \
    && echo "grub-pc grub-pc/install_devices string /dev/sda" | debconf-set-selections \
    && echo "grub-pc grub-pc/install_devices_empty boolean true" | debconf-set-selections \
    && apt install -y \
        proxmox-ve \
        postfix \
        open-iscsi \
        chrony

RUN apt remove -y \
        linux-image-amd64 \
        'linux-image-6.12*' \
        os-prober \
    2>/dev/null || true \
    && apt-get autoremove -y

RUN apt install -y \
        systemd-zram-generator \
        dnsmasq

COPY ./src/postinstall /

RUN echo "vm.swappiness = 1" >> /etc/sysctl.conf \
    && chmod +x /usr/local/bin/* \
    && removepvepopup \
    && rm -f /etc/apt/sources.list.d/pve-install-repo.sources

RUN apt install -y \
        bootc \
    && apt clean \
    && rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /usr/sbin/policy-rc.d
