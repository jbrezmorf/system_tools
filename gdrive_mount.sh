#!/bin/bash
# gdrive_mount.sh
# A single script to manage an rclone mount with interactive drive configuration,
# automatic mounting/unmounting, periodic network check, and cleaning.
#
# Usage:
#   ./gdrive_mount.sh {setup|mount|unmount|check|clean} [config_file]
#
# The optional config_file argument defaults to "./gdrive_mount.conf" if not provided.
#
# Make sure this script is executable: chmod +x gdrive_mount.sh

set -euo pipefail

#############################
# Global Variables
#############################

# Set the check interval in minutes.
# You can also define this in your config file if desired.
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"  # Default is 5 minutes if not already set.

#############################
# Load External Configuration
#############################

CONFIG_FILE="${2:-./gdrive_mount.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file '$CONFIG_FILE' not found. Exiting."
  exit 1
fi

# The config file should define the following variables:
#   MOUNT_NAME        - a unique name for the mount (e.g., "mydrive")
#   MOUNT_POINT       - local mount point (e.g., "/mnt/mydrive")
#   REMOTE            - rclone remote path (e.g., "mygoogledrive:shared-folder")
#   CACHE_DIR         - path to the rclone VFS cache (e.g., "/var/cache/rclone/mydrive")
#   ALLOWED_NETWORKS  - an array of allowed SSIDs (e.g., ( "HomeSSID" "OfficeSSID" ))
#   RCLONE_OPTIONS    - additional options for rclone mount (e.g., "--vfs-cache-mode full --daemon")
#
# In this updated setup, if REMOTE is not defined in the config file, the script
# will interactively configure it.
#
# Example config file content (gdrive_mount.conf):
# --------------------------------------------------
# MOUNT_NAME="mydrive"
# MOUNT_POINT="/mnt/mydrive"
# CACHE_DIR="/var/cache/rclone/mydrive"
# ALLOWED_NETWORKS=( "HomeSSID" "OfficeSSID" )
# RCLONE_OPTIONS="--vfs-cache-mode full --daemon"
# --------------------------------------------------
#
# Note: REMOTE is intentionally left out if not yet configured.
source "$CONFIG_FILE"

#############################
# Interactive Remote Setup
#############################

setup_drive_config() {
  # Check if REMOTE is already set.
  if [[ -z "${REMOTE:-}" ]]; then
    echo "REMOTE variable is not set in ${CONFIG_FILE}."
    echo "Let's configure your Google Drive remote for rclone."
    echo "------------------------------------------------------"
    echo "Step 1: rclone configuration"
    echo "A browser window will open to help you authenticate with Google Drive."
    echo "Make sure that rclone is installed and available in your PATH."
    echo
    read -p "Press [ENTER] to run 'rclone config'..." unused
    rclone config
    echo "------------------------------------------------------"
    echo "Step 2: Remote details"
    read -p "Enter the name of the rclone remote you just created (e.g., mygoogledrive): " remoteName
    read -p "Enter the folder to mount on that remote (e.g., shared-folder or a folder ID): " folderPath
    REMOTE="${remoteName}:${folderPath}"
    echo "Your remote is now set to: ${REMOTE}"
    echo
    echo "Updating configuration file (${CONFIG_FILE}) with REMOTE value..."
    # Append REMOTE to the config file. (You could also update in place if desired.)
    echo "" >> "$CONFIG_FILE"
    echo "# Added by gdrive_mount.sh interactive setup on $(date)" >> "$CONFIG_FILE"
    echo "REMOTE=\"${REMOTE}\"" >> "$CONFIG_FILE"
    echo "Configuration updated."
  else
    echo "REMOTE variable is already set to: ${REMOTE}"
  fi
}

#############################
# Helper Functions
#############################

# Check if we're connected to an allowed Wi-Fi network.
check_network() {
  # This example uses 'iwgetid' to get the current SSID.
  # Adjust this if your system uses another method (e.g., nmcli).
  CURRENT_SSID=$(iwgetid -r || echo "none")
  if [[ " ${ALLOWED_NETWORKS[*]} " =~ " ${CURRENT_SSID} " ]]; then
    echo "Connected to allowed network: ${CURRENT_SSID}"
    return 0
  else
    echo "Not connected to an allowed network. Current SSID: ${CURRENT_SSID}"
    return 1
  fi
}

# Mount the rclone remote. This command now mounts on any network.
mount_drive() {
  echo "Attempting to mount ${REMOTE} at ${MOUNT_POINT}..."

  # Create mount point and cache directory if they don't exist.
  mkdir -p "$MOUNT_POINT" "$CACHE_DIR"

  # Run rclone mount. (Make sure your rclone config already includes the remote.)
  rclone mount "${REMOTE}" "$MOUNT_POINT" \
    --cache-dir "$CACHE_DIR" \
    $RCLONE_OPTIONS

  echo "Mount command issued. (Check with 'mount' or 'df' if needed.)"
}

# Unmount the rclone mount.
unmount_drive() {
  echo "Attempting to unmount ${MOUNT_POINT}..."
  # Use lazy unmount (-uz) so that it detaches even if busy.
  fusermount -uz "$MOUNT_POINT" && echo "Unmounted successfully." || echo "Unmount command may have failed or mount was not active."
}

# Check: Called periodically to verify allowed network connectivity.
# If not connected to an allowed network, the drive is unmounted.
check_drive() {
  echo "Performing periodic network check..."
  if ! check_network; then
    echo "Network check failed. Unmounting drive..."
    unmount_drive
  else
    echo "Network check passed. No action needed."
  fi
}

# Clean: Synchronize active changes and clear cache.
clean_drive() {
  echo "Synchronizing mount and clearing cache..."
  # Example: sync local changes back to remote.
  # WARNING: rclone sync is one‐way and may delete files if not used carefully.
  # Adjust the command below to match your intended direction.
  rclone sync "$MOUNT_POINT" "${REMOTE}" --verbose

  # Clear the rclone VFS cache.
  if [[ -d "$CACHE_DIR" ]]; then
    echo "Clearing cache directory ${CACHE_DIR}..."
    rm -rf "${CACHE_DIR:?}/"*
  else
    echo "Cache directory ${CACHE_DIR} does not exist. Skipping cache cleanup."
  fi
  echo "Clean operation complete."
}

# Setup: Create sample systemd unit files for automounting and periodic network check.
setup_systemd() {
  # First, ensure the drive configuration is set.
  setup_drive_config

  echo "Setting up systemd unit files for ${MOUNT_NAME}..."

  # Determine the full path to this script.
  SCRIPT_PATH=$(realpath "$0")

  # Service unit file for mounting the drive.
  SERVICE_FILE="/etc/systemd/system/rclone-mount-${MOUNT_NAME}.service"
  sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Rclone mount for ${MOUNT_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} mount ${CONFIG_FILE}
ExecStop=${SCRIPT_PATH} unmount ${CONFIG_FILE}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  echo "Created systemd service file: ${SERVICE_FILE}"

  # Create a service and timer for periodic network check.
  CHECK_SERVICE_FILE="/etc/systemd/system/rclone-mount-${MOUNT_NAME}-check.service"
  sudo tee "$CHECK_SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Periodic network check for ${MOUNT_NAME} mount

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} check ${CONFIG_FILE}
EOF

  CHECK_TIMER_FILE="/etc/systemd/system/rclone-mount-${MOUNT_NAME}-check.timer"
  sudo tee "$CHECK_TIMER_FILE" > /dev/null <<EOF
[Unit]
Description=Run network check for ${MOUNT_NAME} every ${CHECK_INTERVAL} minutes

[Timer]
OnCalendar=*:0/${CHECK_INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  echo "Created systemd timer and service for periodic network check."
  echo "Reloading systemd daemon..."
  sudo systemctl daemon-reload

  echo "Enabling and starting rclone-mount-${MOUNT_NAME}.service and timer..."
  sudo systemctl enable --now "rclone-mount-${MOUNT_NAME}.service"
  sudo systemctl enable --now "rclone-mount-${MOUNT_NAME}-check.timer"
  echo "Setup complete."
}

#############################
# Main Command Processing
#############################

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 {setup|mount|unmount|check|clean} [config_file]"
  exit 1
fi

COMMAND="$1"

case "$COMMAND" in
  setup)
    setup_systemd
    ;;
  mount)
    mount_drive
    ;;
  unmount)
    unmount_drive
    ;;
  check)
    check_drive
    ;;
  clean)
    clean_drive
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Usage: $0 {setup|mount|unmount|check|clean} [config_file]"
    exit 1
    ;;
esac
