#####################################################################################
# Base image
#####################################################################################
FROM debian:trixie AS base

# Environement Setup
LABEL org.opencontainers.image.title="Proxmox VE"
LABEL org.opencontainers.image.description="Proxmox VE 9 bootc — Debian 13 Trixie"
LABEL org.opencontainers.image.base.name="docker.io/library/debian:trixie"

ENV DEBIAN_FRONTEND=noninteractive \
    CARGO_HOME=/tmp/rust \
    RUSTUP_HOME=/tmp/rust \
    OSTREE_VER=2025.7 \
    BOOTC_VER=v1.14.0

SHELL ["/bin/bash", "-c"]

# Bootc filesystem migrations
RUN rm -rf /{home,root,mnt,srv,opt}  \
    && mkdir -p /var/{home,roothome,mnt,srv,opt} \
    && ln -s /var/{home,mnt,srv,opt} / \
    && ln -s  /var/roothome /root

# Prepare package
COPY ./src/bootcpreinstall /
RUN rm -f /etc/apt/sources.list \
    && apt update \
    && apt install -y \
        git \
        curl \
        wget \
        dracut

#####################################################################################
# Bootc build image
#####################################################################################
FROM base AS bootc-builder

# Prepare package
RUN rm -f /etc/apt/sources.list \
    && apt update \
    && apt install -y \
        make \
        build-essential \
        go-md2man \
        checkinstall \
        libzstd-dev \
        pkgconf \
        autoconf \
        automake \
        libtool \
        libglib2.0-dev \
        libcurl4-openssl-dev \
        libgpgme-dev \
        libarchive-dev \
        libmount-dev \
        libfuse3-dev \
        libssl-dev \
        libsystemd-dev \
        gobject-introspection \
        libgirepository1.0-dev \
        libsoup-3.0-dev \
        bison

# Ostree build and install
RUN --mount=type=tmpfs,dst=/tmp \
    curl -fsSL \
        https://github.com/ostreedev/ostree/releases/download/v${OSTREE_VER}/libostree-${OSTREE_VER}.tar.xz \
        | tar -xJ -C /tmp \
    && cd /tmp/libostree-${OSTREE_VER} \
    && ./configure --prefix=/usr --sysconfdir=/etc \
        --disable-gtk-doc --disable-man \
    && make -j$(nproc) \
    && mkdir -p /pkg \
    && checkinstall \
        --pkgname=libostree \
        --pkgversion=${OSTREE_VER} \
        --pkglicense=LGPL \
        --pakdir=/pkg \
        --install=yes \
        --default \
        make install

# Bootc build and install
RUN --mount=type=tmpfs,dst=/tmp \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- --profile minimal -y \
    && git clone --depth=1 --branch "${BOOTC_VER}" \
        https://github.com/bootc-dev/bootc.git /tmp/bootc \
    && . ${RUSTUP_HOME}/env \
    && cargo build --release --manifest-path /tmp/bootc/Cargo.toml \
    && checkinstall \
        --pkgname=bootc \
        --pkgversion=1.14.0 \
        --pkglicense=LGPL \
        --pakdir=/pkg \
        --install=no \
        --default \
        make -C /tmp/bootc install-all

#####################################################################################
# Final image
#####################################################################################
FROM base AS final

COPY --from=bootc-builder /pkg/*.deb /tmp/
RUN dpkg -i /tmp/libostree_*.deb /tmp/bootc_*.deb \
    && rm /tmp/*.deb

# Proxmox kernel setup
COPY ./src/pvepreinstall /

RUN chmod +x \
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

# Proxmox VE setup
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
    2>/dev/null || true

COPY ./src/bootcpostinstall /
RUN dracut --force \
        "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/initramfs.img"

# Optimisations setup
RUN apt install -y \
        systemd-zram-generator \
        dnsmasq

COPY ./src/pvepostinstall /
RUN echo "vm.swappiness = 1" >> /etc/sysctl.conf \
    && chmod +x /usr/local/bin/* \
    && removepvepopup \
    && rm -f /etc/apt/sources.list.d/pve-install-repo.sources

# Clean and purge image
RUN apt autoremove -y \
    && apt clean \
    && rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /tmp/bootc \
        /usr/sbin/policy-rc.d
