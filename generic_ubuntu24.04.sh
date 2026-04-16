#!/bin/bash
set -euo pipefail

# Default values
DEFAULT_SSH_PORT=2222
DEFAULT_HOSTNAME=""
DEFAULT_LOCAL_IPADDRESS=""

# Argument parsing
SSH_PORT=$DEFAULT_SSH_PORT
HOSTNAME=$DEFAULT_HOSTNAME
LOCAL_IPADDRESS=$DEFAULT_LOCAL_IPADDRESS

# Help display function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --ssh-port PORT         Specify SSH port (default: $DEFAULT_SSH_PORT)
    --hostname NAME         Specify hostname (default: no change)
    --local-ipaddress IP/PREFIX    Local IP address with prefix (e.g., 192.168.100.1/24)
    -h, --help             Show this help

Examples:
    # Run with default settings
    $0

    # Specify SSH port and hostname
    $0 --ssh-port 2222 --hostname myserver-01

    # With local IP address
    $0 --ssh-port 2222 --hostname myserver-01 --local-ipaddress 192.168.100.1/24

    # When running from curl
    curl -fsSL https://raw.githubusercontent.com/miiton/ubuntu-setup/refs/heads/main/generic_ubuntu24.04.sh | bash -s -- --ssh-port 2222 --hostname myserver-01 --local-ipaddress 192.168.100.1/24

EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        --hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        --local-ipaddress)
            LOCAL_IPADDRESS="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Argument validation
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Error: SSH port must be a number between 1 and 65535"
    exit 1
fi

if [[ -n "$HOSTNAME" ]] && ! [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
    echo "Error: Invalid hostname format. Hostname must contain only alphanumeric characters and hyphens, and cannot start or end with a hyphen"
    exit 1
fi

# Validate local IP address
if [[ -n "$LOCAL_IPADDRESS" ]]; then
    if ! [[ "$LOCAL_IPADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "Error: Invalid IP address format. Must be in IP/PREFIX notation (e.g., 192.168.100.1/24)"
        exit 1
    fi

    # Extract IP address and prefix
    STATIC_IP="${LOCAL_IPADDRESS%/*}"
    PREFIX="${LOCAL_IPADDRESS#*/}"

    # Validate prefix length
    if [ "$PREFIX" -lt 8 ] || [ "$PREFIX" -gt 30 ]; then
        echo "Error: Network prefix must be between 8 and 30"
        exit 1
    fi

    # Validate IP octets
    IFS='.' read -r -a octets <<< "$STATIC_IP"
    for octet in "${octets[@]}"; do
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            echo "Error: Invalid IP address. Each octet must be between 0 and 255"
            exit 1
        fi
    done
fi

# Log all output
exec > >(tee -a /var/log/generic-setup.log)
exec 2>&1

echo "Starting generic setup at $(date)"
echo "Configuration:"
echo "  SSH Port: $SSH_PORT"
echo "  Hostname: ${HOSTNAME:-"(no change)"}"
echo "  Local IP Address: ${LOCAL_IPADDRESS:-"(no local IP address)"}"
if [[ -n "$LOCAL_IPADDRESS" ]]; then
    echo "  Static IP: ${STATIC_IP}/${PREFIX}"
fi
echo "========================================="

# Hostname configuration
if [[ -n "$HOSTNAME" ]]; then
    echo "Setting hostname to: $HOSTNAME"
    hostnamectl set-hostname "$HOSTNAME"

    # Update /etc/hosts file
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/127.0.1.1.*/127.0.1.1 $HOSTNAME/" /etc/hosts
    else
        echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
    fi

    echo "Hostname set successfully"
fi

# Update and upgrade system
apt-get update
apt-get -y upgrade

# Change SSH port
echo "Configuring SSH port to: $SSH_PORT"
sed -i "s/^#\?Port [0-9]*/Port $SSH_PORT/" /etc/ssh/sshd_config

# Ensure Port directive exists if not found
if ! grep -q "^Port" /etc/ssh/sshd_config; then
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi

# Enable SSH service
systemctl enable ssh
systemctl start ssh

# Set timezone to Asia/Tokyo
timedatectl set-timezone Asia/Tokyo

# Configure journald to limit log size
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/00-journal.conf <<EOF
[Journal]
SystemMaxUse=2G
SystemMaxFileSize=200M
MaxRetentionSec=1week
EOF

systemctl restart systemd-journald

# Install useful tools and security packages
apt-get -y install htop iotop net-tools jq fail2ban unattended-upgrades

# Configure fail2ban for SSH protection on custom port
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
backend = systemd
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# Configure automatic security updates
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF

systemctl enable unattended-upgrades
systemctl start unattended-upgrades

# Configure second network interface for local network (static IP only)
if [[ -n "$LOCAL_IPADDRESS" ]]; then
    # Find the second physical network interface (excluding lo)
    SECOND_INTERFACE=""
    INTERFACE_COUNT=0
    for interface in /sys/class/net/*; do
        if [ -d "$interface" ] && [ "$(basename "$interface")" != "lo" ]; then
            # Check if it's a physical interface (has a device symlink)
            if [ -L "$interface/device" ]; then
                INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
                if [ $INTERFACE_COUNT -eq 2 ]; then
                    SECOND_INTERFACE=$(basename "$interface")
                    break
                fi
            fi
        fi
    done

    if [ -n "$SECOND_INTERFACE" ] && [ -f "/sys/class/net/$SECOND_INTERFACE/address" ]; then
        echo "Configuring second network interface: $SECOND_INTERFACE"

        # Get MAC address of the second interface
        MAC_ADDRESS=$(cat "/sys/class/net/$SECOND_INTERFACE/address")
        echo "$SECOND_INTERFACE MAC address: $MAC_ADDRESS"

        echo "Setting up static IP ${STATIC_IP}/${PREFIX}..."
        cat > /etc/netplan/99-local.yaml <<EOF
network:
  version: 2
  ethernets:
    local0:
      match:
        macaddress: $MAC_ADDRESS
      addresses:
        - ${STATIC_IP}/${PREFIX}
      optional: true
EOF

        # Apply netplan configuration
        netplan apply

        # Verify IP assignment
        sleep 2
        IP=$(ip -4 addr show "$SECOND_INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1)
        if [ -n "$IP" ]; then
            echo "Successfully configured static IP: $IP"
            echo "$IP" > /etc/local-ip
        else
            echo "WARNING: Failed to configure static IP"
        fi
    else
        echo "Second network interface not found, skipping local network configuration"
    fi
else
    echo "No local IP address specified, skipping local network configuration"
fi

# Final cleanup
apt-get clean
apt-get -y autoremove

rm /etc/machine-id
systemd-machine-id-setup

# Display completion status
echo "========================================="
echo "Generic setup completed at $(date)"
echo "========================================="
echo "SSH Port: $SSH_PORT"
if [[ -n "$HOSTNAME" ]]; then
    echo "Hostname: $HOSTNAME"
fi
if [ -f /etc/local-ip ]; then
    echo "Local IP: $(cat /etc/local-ip)"
fi
echo "Log file: /var/log/generic-setup.log"
echo "========================================="

reboot
