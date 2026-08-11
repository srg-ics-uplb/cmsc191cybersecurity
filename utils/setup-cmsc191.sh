#!/bin/bash
#
# setup-cmsc125.sh - CMSC 125 lab setup for Ubuntu 24.04 Desktop
# Usage: sudo ./setup-cmsc125.sh
#
set -e

# =============================================================
# CONFIG - edit these
# =============================================================
USERNAME="cmsc191"
PASSWORD="exploit"

# VirtualBox is installed from Oracle's own APT repo instead of Ubuntu's
# multiverse package, since Oracle's repo tracks the current upstream
# release. Set the branch to install here (Oracle publishes versioned
# packages like virtualbox-7.2, not a generic "virtualbox" package).
VBOX_VERSION="7.2"

# All packages below (other than virtualbox-$VBOX_VERSION, added by the
# Oracle repo step) come from the standard Ubuntu repositories.
# Add or remove lines freely. Check a name first with:  apt-cache show <pkg>
PACKAGES="
build-essential
gcc
g++
gdb
make
manpages-dev
manpages-posix-dev
valgrind
nasm
qemu-system-x86
qemu-utils
qemu-kvm
ovmf
git
docker.io
docker-compose-v2
docker-buildx
virtualbox-$VBOX_VERSION
vim
nano
gedit
openssh-server
dkms
linux-headers-generic
"

# Groups the user is added to. 'sudo' gives root access.
USER_GROUPS="sudo docker vboxusers kvm"

# =============================================================
# Setup
# =============================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

# Suppress all prompts: debconf, config file conflicts, service restarts
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT="apt-get -y -o Dpkg::Options::=--force-confold"

echo "==> Creating user $USERNAME"
if id "$USERNAME" >/dev/null 2>&1; then
    echo "    already exists, resetting password"
else
    useradd -m -s /bin/bash "$USERNAME"
fi
echo "$USERNAME:$PASSWORD" | chpasswd

echo "==> Enabling universe/multiverse (needed by some packages)"
$APT update
$APT install software-properties-common
add-apt-repository -y universe
add-apt-repository -y multiverse

echo "==> Adding Oracle's VirtualBox APT repository"
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
KEYRING=/usr/share/keyrings/oracle-virtualbox-2016.gpg
wget -q -O- https://www.virtualbox.org/download/oracle_vbox_2016.asc \
    | gpg --yes --dearmor --output "$KEYRING"
echo "deb [arch=amd64 signed-by=$KEYRING] https://download.virtualbox.org/virtualbox/debian $CODENAME contrib" \
    > /etc/apt/sources.list.d/virtualbox.list

$APT update

echo "==> Installing packages"
for pkg in $PACKAGES; do
    echo "--- $pkg"
    $APT install "$pkg" || echo "    FAILED: $pkg"
done

echo "==> Adding $USERNAME to groups"
for grp in $USER_GROUPS; do
    if getent group "$grp" >/dev/null; then
        usermod -aG "$grp" "$USERNAME"
        echo "    $grp"
    fi
done

echo "==> Starting docker"
systemctl enable --now docker || echo "    docker failed to start"

# =============================================================
# Check
# =============================================================
echo
echo "==> Versions"
for cmd in gcc nasm git qemu-system-x86_64 docker vboxmanage vim; do
    if command -v "$cmd" >/dev/null; then
        echo "  ok    $cmd"
    else
        echo "  MISSING  $cmd"
    fi
done

if [ ! -e /dev/kvm ]; then
    echo
    echo "WARNING: /dev/kvm missing - enable VT-x/AMD-V in the BIOS"
fi

if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    echo
    echo "WARNING: Secure Boot is ON - VirtualBox kernel modules will not load."
    echo "         Disable Secure Boot in firmware."
fi

echo
echo "==> Done. Log out and back in for group changes to apply."
