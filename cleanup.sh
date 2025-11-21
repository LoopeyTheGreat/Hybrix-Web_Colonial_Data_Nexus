#!/bin/bash

# Script to move Data Nexus Monitor files to its dedicated project folder
# and clean up the original colonial_data_nexus directory.

# Define paths (adjust if your WSL mount point for C: is different)
SOURCE_DIR="/mnt/c/Projects/Hybrid-Web/_Non-Swarm_Services/colonial_data_nexus"
DEST_DIR="/mnt/c/Projects/Hybrid-Web/_Non-Swarm_Services/data_nexus_monitor"

echo "Starting file migration for Data Nexus Monitor..."
echo "Source Directory: ${SOURCE_DIR}"
echo "Destination Directory: ${DEST_DIR}"

# Ensure destination directory exists
mkdir -p "${DEST_DIR}"
if [ $? -eq 0 ]; then
    echo "Ensured destination directory exists: ${DEST_DIR}"
else
    echo "ERROR: Could not create destination directory ${DEST_DIR}. Please check permissions."
    exit 1
fi

declare -a items_to_move=(
    "data_nexus_monitor-compose-fixed.yaml"
    "data"
    "html"
    "ntfy_config.env"
    "README.md"
    "host_autofs_monitor.sh"
    "host-ip-checker.service"
    "setup.sh" # Will move from source if it exists there, potentially overwriting if already in dest
)

echo ""
echo "Moving items to ${DEST_DIR}..."
for item in "${items_to_move[@]}"; do
    if [ -e "${SOURCE_DIR}/${item}" ]; then
        echo "Attempting to move '${item}'..."
        # Using -v for verbose output from mv
        mv -v "${SOURCE_DIR}/${item}" "${DEST_DIR}/"
        if [ $? -eq 0 ]; then
            echo "Successfully moved '${item}' to ${DEST_DIR}."
        else
            echo "ERROR: Failed to move '${item}'. It might still be in ${SOURCE_DIR} or partially moved."
        fi
    else
        echo "WARN: Item '${item}' not found in ${SOURCE_DIR}. Skipping move for this item."
    fi
done

# Files and directories to REMOVE from the SOURCE_DIR (obsolete clutter)
declare -a items_to_remove_from_source=(
    "CLEANUP_SUMMARY.md"
    "DEPLOYMENT_GUIDE.md"
    "deploy_remote.sh"
    "deploy_updates.sh"
    "_obsolete_"
    "env.env" # Added based on previous dir listing, if it's general clutter
)

echo ""
echo "Removing obsolete items from ${SOURCE_DIR}..."
for item in "${items_to_remove_from_source[@]}"; do
    if [ -e "${SOURCE_DIR}/${item}" ]; then
        echo "Attempting to remove '${item}' from ${SOURCE_DIR}..."
        # Using -v for verbose output from rm
        rm -rfv "${SOURCE_DIR}/${item}"
        if [ $? -eq 0 ]; then
            echo "Successfully removed '${item}'."
        else
            echo "ERROR: Failed to remove '${item}'."
        fi
    else
        echo "INFO: Obsolete item '${item}' not found in ${SOURCE_DIR}. Already cleaned or never existed."
    fi
done

echo ""
echo "File migration and cleanup process complete."
echo "Please verify the contents of:"
echo "  - ${DEST_DIR}"
echo "  - ${SOURCE_DIR}"
echo ""
echo "The 'setup.sh' script in ${DEST_DIR} should have already been updated in the previous step to remove 'Colonial Data Nexus' references."
echo "If 'setup.sh' was the only file in ${DEST_DIR} before running this script, this script attempted to move it again from ${SOURCE_DIR} if it existed there."
