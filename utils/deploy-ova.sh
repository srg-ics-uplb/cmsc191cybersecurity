#!/bin/bash
#
# deploy-ova.sh - Copy an .ova file to several machines, then import it
#                 into VirtualBox on each one.
#
# Usage: ./deploy-ova.sh hosts.txt appliance.ova [ssh-user]
#
# hosts.txt has one IP address per line. Blank lines and lines
# starting with # are ignored.
#
# The OVA is copied to a ".ova" folder in the remote user's home
# directory and kept there as a backup. All copies happen first,
# then all imports.
#
# Target: Ubuntu 24.04, VirtualBox installed on the remote machines.
# The script runs ssh-copy-id against every host first, so you only
# need a password (not a pre-existing key setup) the first time you
# run this against a given machine. After that, key auth takes over
# and no more passwords are needed at all.

# Check the arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 hosts.txt appliance.ova [ssh-user]"
    exit 1
fi

HOSTS_FILE=$1
OVA_FILE=$2
SSH_USER=${3:-$(whoami)}     # use the third argument, or the current user

OVA_NAME=$(basename "$OVA_FILE")   # e.g. "lab.ova"
VM_NAME=${OVA_NAME%.ova}           # e.g. "lab"  (strips the .ova part)

# ---------------------------------------------------------------
# SSH connection reuse: without this, every ssh/scp call below opens
# a brand-new connection and re-prompts for a password if you're not
# using passwordless key auth. ControlMaster keeps one authenticated
# connection open per host and reuses it for all further ssh/scp
# calls to that host, so at most one prompt per host for the whole run.
# ---------------------------------------------------------------
CONTROL_DIR=$(mktemp -d)
SSH_OPTS=(-o ControlMaster=auto -o ControlPersist=10m -o "ControlPath=$CONTROL_DIR/%r@%h:%p")

cleanup() {
    for host in "${hosts[@]}"; do
        ssh "${SSH_OPTS[@]}" -O exit "$SSH_USER@$host" 2>/dev/null
    done
    rm -rf "$CONTROL_DIR"
}
trap cleanup EXIT

if [ ! -f "$HOSTS_FILE" ]; then
    echo "Cannot find hosts file: $HOSTS_FILE"
    exit 1
fi

if [ ! -f "$OVA_FILE" ]; then
    echo "Cannot find OVA file: $OVA_FILE"
    exit 1
fi

# ---------------------------------------------------------------
# Read the hosts file into a list, skipping blanks and comments
# ---------------------------------------------------------------
hosts=()

while read -r line; do
    if [ -z "$line" ] || [ "${line:0:1}" = "#" ]; then
        continue
    fi
    hosts+=("$line")
done < "$HOSTS_FILE"

if [ ${#hosts[@]} -eq 0 ]; then
    echo "No machines listed in $HOSTS_FILE"
    exit 1
fi

echo "Deploying $OVA_NAME as VM '$VM_NAME'"
echo "User: $SSH_USER   Machines: ${#hosts[@]}"
echo

failed=0
copied=()        # machines where the copy worked

# ---------------------------------------------------------------
# Step 0: make sure we have a local key, then copy it to every host
# ---------------------------------------------------------------
echo "########## STEP 0: SSH KEY SETUP ##########"
echo

# Use an existing key if there is one, otherwise generate a fresh
# ed25519 keypair with no passphrase so later steps run unattended.
KEY_FILE="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY_FILE" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
    echo "No SSH key found, generating one at $KEY_FILE"
    ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" -q
fi

for host in "${hosts[@]}"; do
    echo "Copying SSH key to $host ..."
    if ssh-copy-id -o StrictHostKeyChecking=accept-new "$SSH_USER@$host"; then
        echo "  OK"
    else
        echo "  Could not copy key (will fall back to password prompts if needed)."
    fi
    echo
done

# ---------------------------------------------------------------
# Step 1: copy the OVA to every machine's home directory
# ---------------------------------------------------------------
echo "########## STEP 1: COPYING ##########"
echo

for host in "${hosts[@]}"; do
    echo "Copying to $host ..."

    # scp cannot create folders, so make it first with ssh.
    # The remote shell expands ~ to the remote home directory.
    if ! ssh -n "${SSH_OPTS[@]}" "$SSH_USER@$host" "mkdir -p ~/.ova"; then
        echo "  Could not create the .ova folder."
        failed=$((failed + 1))
        echo
        continue
    fi

    if scp "${SSH_OPTS[@]}" "$OVA_FILE" "$SSH_USER@$host:~/.ova/"; then
        echo "  OK"
        copied+=("$host")
    else
        echo "  Copy failed."
        failed=$((failed + 1))
    fi
    echo
done

# ---------------------------------------------------------------
# Step 2: import the OVA on every machine that got a copy
# ---------------------------------------------------------------
echo "########## STEP 2: IMPORTING ##########"
echo

for host in "${copied[@]}"; do
    echo "Importing on $host ..."

    # The OVA stays in ~/.ova afterwards as a backup.
    if ssh -n "${SSH_OPTS[@]}" "$SSH_USER@$host" \
        "VBoxManage import ~/.ova/$OVA_NAME --vsys 0 --vmname '$VM_NAME'"; then
        echo "  OK"
    else
        echo "  Import failed."
        failed=$((failed + 1))
    fi
    echo
done

# ---------------------------------------------------------------
# Final report
# ---------------------------------------------------------------
if [ "$failed" -eq 0 ]; then
    echo "Finished. All ${#hosts[@]} machines succeeded."
else
    echo "Finished with $failed error(s)."
    exit 1
fi
