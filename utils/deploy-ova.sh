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
# SSH keys should already be set up (ssh-copy-id user@ip).

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
# Step 1: copy the OVA to every machine's home directory
# ---------------------------------------------------------------
echo "########## STEP 1: COPYING ##########"
echo

for host in "${hosts[@]}"; do
    echo "Copying to $host ..."

    # scp cannot create folders, so make it first with ssh.
    # The remote shell expands ~ to the remote home directory.
    if ! ssh -n "$SSH_USER@$host" "mkdir -p ~/.ova"; then
        echo "  Could not create the .ova folder."
        failed=$((failed + 1))
        echo
        continue
    fi

    if scp "$OVA_FILE" "$SSH_USER@$host:~/.ova/"; then
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
    if ssh -n "$SSH_USER@$host" \
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
