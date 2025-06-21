#!/bin/bash
set -euo pipefail

# Default values
DEFAULT_SSH_PORT=2222
DEFAULT_HOSTNAME=""

# Argument parsing
SSH_PORT=$DEFAULT_SSH_PORT
HOSTNAME=$DEFAULT_HOSTNAME

# Help display function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --ssh-port PORT     Specify SSH port (default: $DEFAULT_SSH_PORT)
    --hostname NAME     Specify hostname (default: no change)
    -h, --help         Show this help

Examples:
    # Run with default settings
    $0

    # Specify SSH port and hostname
    $0 --ssh-port 2222 --hostname k3s-node-01

    # When running from curl
    curl -fsSL https://raw.githubusercontent.com/miiton/ubuntu-setup/refs/heads/main/k3s-node_ubuntu24.04.sh | bash -s -- --ssh-port 2222 --hostname k3s-node-01

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

# Log all output
exec > >(tee -a /var/log/k3s-node-setup.log)
exec 2>&1

echo "Starting k3s node setup at $(date)"
echo "Configuration:"
echo "  SSH Port: $SSH_PORT"
echo "  Hostname: ${HOSTNAME:-"(no change)"}"
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

# Add repositories for cloudflared and tailscale
mkdir -p --mode=0755 /usr/share/keyrings

# Install cloudflared
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list

# Install tailscale
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list

# Update and upgrade system
apt-get update
apt-get -y upgrade
apt-get -y install tailscale cloudflared

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

# Disable ufw for k3s nodes
if command -v ufw &> /dev/null; then
    ufw disable
    systemctl disable ufw
fi

# Disable swap for k3s
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Load required kernel modules first
cat > /etc/modules-load.d/k3s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Enable IP forwarding and bridge netfilter (after modules are loaded)
cat > /etc/sysctl.d/k3s.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

# Apply sysctl settings
sysctl --system

# Set timezone to Asia/Tokyo
timedatectl set-timezone Asia/Tokyo

# Configure journald to limit log size
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/00-k3s.conf <<EOF
[Journal]
SystemMaxUse=2G
SystemMaxFileSize=200M
MaxRetentionSec=1week
EOF

systemctl restart systemd-journald

# Install useful tools and security packages
apt-get update
apt-get -y install htop iotop net-tools jq fail2ban unattended-upgrades open-iscsi nfs-common

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

# Configure local network interface enp7s0 for local network
if [ -f /sys/class/net/enp7s0/address ]; then
    echo "Configuring enp7s0 interface..."
    
    # Configure as DHCP client
    cat > /etc/netplan/99-enp7s0.yaml <<EOF
network:
  version: 2
  ethernets:
    enp7s0:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
        use-dns: false
      optional: true
EOF
    
    # Apply netplan configuration
    netplan apply
    
    # Wait for IP assignment with retries
    for i in {1..6}; do
        sleep 5
        IP=$(ip -4 addr show enp7s0 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1)
        if [ -n "$IP" ]; then
            echo "Successfully obtained IP from DHCP: $IP"
            echo "$IP" > /etc/k3s-local-ip
            break
        else
            echo "Attempt $i/6: Waiting for DHCP lease..."
        fi
    done
    
    if [ -z "$IP" ]; then
        echo "WARNING: Failed to obtain IP from DHCP server after 30 seconds"
    fi
else
    echo "enp7s0 interface not found, skipping local network configuration"
fi

# Final cleanup
apt-get clean
apt-get -y autoremove

modprobe dm_crypt
rm /etc/machine-id
systemd-machine-id-setup

# Display completion status
echo "========================================="
echo "k3s node setup completed at $(date)"
echo "========================================="
echo "SSH Port: $SSH_PORT"
if [[ -n "$HOSTNAME" ]]; then
    echo "Hostname: $HOSTNAME"
fi
if [ -f /etc/k3s-local-ip ]; then
    echo "Local IP: $(cat /etc/k3s-local-ip)"
fi
echo "Log file: /var/log/k3s-node-setup.log"
echo "========================================="

reboot