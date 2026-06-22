# personal-server net-install kickstart
# Anaconda pulls the bootc image from GHCR at install time.

network --hostname=alma-builder

# Pull the bootc image from the registry
bootc --source-imgref=ghcr.io/daemoncores/proxmox-atomic:latest --target-imgref=ghcr.io/daemoncores/proxmox-atomic:latest

# Reboot after install
reboot
