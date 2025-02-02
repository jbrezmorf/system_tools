#!/bin/bash
# gdrive_mount.sh
# A single script to manage an rclone mount with interactive drive configuration,
# automatic mounting/unmounting via periodic network check, and cleaning.
#
# Usage:
#   ./gdrive_mount.sh {setup|mount|unmount|check|clean} [config_file]
#
# The config_file argument is based on the script's directory or provided explicitly
# (e.g., if you call: ./gdrive_mount.sh setup myconfig then it looks for "myconfig.cfg")
#
# Make sure this script is executable: chmod +x gdrive_mount.sh

set -euo pipefail

#############################
# Load External Configuration
#############################
# Determine the directory where the script is located.
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Build the config file path.
CONFIG_FILE="$2"
if [[ ! -f "$CONFIG_FILE" ]]; then
  CONFIG_FILE="$SCRIPT_DIR/$2.cfg"
fi

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
# Global Variables
#############################

# Set the check interval in minutes (default is 1 minute).
CHECK_INTERVAL="${CHECK_INTERVAL:-1}"

# Set defaults if not provided in the config file.
CACHE_DIR=${CACHE_DIR:-"${HOME}/.config/gdrive_mount_cache/${MOUNT_NAME}"}
RCLONE_OPTIONS=${RCLONE_OPTIONS:-"--vfs-cache-mode full --daemon"}
# For systemd calls we remove the --daemon flag (see mount_drive below).
MOUNT_POINT="${HOME}/mnt/${MOUNT_NAME}"

#############################
# Interactive Remote Setup
#############################

setup_drive_config() {
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

check_network() {
  CURRENT_SSID=$(iwgetid -r || echo "none")
  if [[ " ${ALLOWED_NETWORKS[*]} " =~ " ${CURRENT_SSID} " ]]; then
    echo "Connected to allowed network: ${CURRENT_SSID}"
    return 0
  else
    echo "Not connected to an allowed network. Current SSID: ${CURRENT_SSID}"
    return 1
  fi
}

mount_drive() {
  echo "Attempting to mount ${REMOTE} at ${MOUNT_POINT}..."

  # Choose options based on whether called from systemd.
  if [[ "${SYSTEMD_CALL:-}" == "1" ]]; then
    echo "Running from systemd: disabling --daemon option"
    RCLONE_OPTS="${RCLONE_OPTIONS/--daemon/}"
  else
    RCLONE_OPTS="$RCLONE_OPTIONS"
  fi

  # Ensure the mount point and cache directories exist.
  #mkdir -p "$MOUNT_POINT" "$CACHE_DIR"

  # Run rclone mount.
  rclone mount "${REMOTE}" "$MOUNT_POINT" \
    --cache-dir "$CACHE_DIR" \
    $RCLONE_OPTS

  echo "Mount command issued. (Check with 'mount' or 'df' if needed.)"
}

unmount_drive() {
  echo "Attempting to unmount ${MOUNT_POINT}..."
  fusermount -uz "$MOUNT_POINT" && echo "Unmounted successfully." || echo "Unmount command may have failed or mount was not active."
}

check_drive() {
  echo "Performing periodic network check..."
  if check_network; then
    echo "Network check passed. Attempting to mount drive if not already mounted."
    if mountpoint -q "$MOUNT_POINT"; then
      echo "Drive already mounted."
    else
      mount_drive
    fi
  else
    echo "Network check failed. Unmounting drive..."
    unmount_drive
  fi
}

clean_drive() {
  echo "Synchronizing mount and clearing cache..."
  rclone sync "$MOUNT_POINT" "${REMOTE}" --verbose
  if [[ -d "$CACHE_DIR" ]]; then
    echo "Clearing cache directory ${CACHE_DIR}..."
    rm -rf "${CACHE_DIR:?}/"*
  else
    echo "Cache directory ${CACHE_DIR} does not exist. Skipping cache cleanup."
  fi
  echo "Clean operation complete."
}

#############################
# Setup: Create systemd user unit files for mounting and periodic network check.
#############################

setup_systemd() {
  # Create necessary directories.
  mkdir -p "$MOUNT_POINT" "$CACHE_DIR"
  mkdir -p "$HOME/.config/systemd/user"

  # Ensure the drive configuration is set.
  setup_drive_config

  echo "Setting up user systemd unit files for rclone mount for ${MOUNT_NAME}..."

  SCRIPT_PATH=$(realpath "$0")

  # Create a service unit file for periodic network check.
  CHECK_SERVICE_FILE="$HOME/.config/systemd/user/rclone-mount-${MOUNT_NAME}-check.service"
  tee "$CHECK_SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Periodic network check for ${MOUNT_NAME} mount

[Service]
Type=oneshot
Environment="SYSTEMD_CALL=1"
ExecStart=${SCRIPT_PATH} check ${CONFIG_FILE}
EOF

  echo "Created user check service unit file: ${CHECK_SERVICE_FILE}"

  # Create a timer unit file to run the network check.
  # Here, we use a full calendar expression.
  CHECK_TIMER_FILE="$HOME/.config/systemd/user/rclone-mount-${MOUNT_NAME}-check.timer"
  tee "$CHECK_TIMER_FILE" > /dev/null <<EOF
[Unit]
Description=Run network check for ${MOUNT_NAME} every ${CHECK_INTERVAL} minute(s)

[Timer]
OnCalendar=*-*-* *:0/${CHECK_INTERVAL}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  echo "Created user network check timer: ${CHECK_TIMER_FILE}"

  echo "Reloading user systemd daemon..."
  systemctl --user daemon-reload

  echo "Enabling and starting rclone mount service and network check timer..."
  systemctl --user enable --now "rclone-mount-${MOUNT_NAME}-check.timer"

  # Explicitly mount the drive immediately.
  echo "Attempting explicit mount..."
  ${SCRIPT_PATH} mount ${CONFIG_FILE}
  echo "Waiting a few seconds for the mount to settle..."
  sleep 5

  if mountpoint -q "$MOUNT_POINT"; then
    echo "Mount successful: ${MOUNT_POINT} is active."
    echo "Mount status:"
    mount | grep "$MOUNT_POINT"
  else
    echo "Mount failed: ${MOUNT_POINT} is not mounted."
  fi

  echo "Setup complete."
}


#############################
# Stop: Disable and stop user systemd unit files.
#############################

stop_systemd() {
  echo "Stopping rclone mount service and network check timer..."
  systemctl --user stop "rclone-mount-${MOUNT_NAME}-check.timer"
  systemctl --user stop "rclone-mount-${MOUNT_NAME}-check.service"
  systemctl --user disable "rclone-mount-${MOUNT_NAME}-check.timer"
  systemctl --user disable "rclone-mount-${MOUNT_NAME}-check.service"
  echo "Stopped and disabled user systemd units."
}

#############################
# List: Show status of the user systemd units.
#############################

list_systemd() {
  echo "Listing status of rclone mount related units:"
  systemctl --user status "rclone-mount-${MOUNT_NAME}.service" \
    "rclone-mount-${MOUNT_NAME}-check.service" \
    "rclone-mount-${MOUNT_NAME}-check.timer"
}


#############################
# Main Command Processing
#############################

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 {setup|mount|unmount|check|clean|stop|list} [config_file]"
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
  stop)
    stop_systemd
    ;;
  list)
    list_systemd
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Usage: $0 {setup|mount|unmount|check|clean|stop|list} [config_file]"
    exit 1
    ;;
esac
