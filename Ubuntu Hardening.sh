#!/bin/bash
sudo -v

# ================================
# Ubuntu Hardening & Setup Script
# ================================
# This script is designed to configure and secure a fresh Ubuntu installation.

# TODO: restrt ssh service, 
# TODO: ask the user waht ports they want to be opened, tcp and udp


# ================================
# Functions
# ================================

echo_message() {
  echo -ne "\033[1;32m$1\033[0m"
}

echo_success() {
  echo -e "\033[1;32m$1\033[0m"
}

echo_error() {
  echo -e "\033[1;31m$1\033[0m"
}

echo_question() {
  echo -ne "\033[38;5;214m$1\033[0m"
}

print_banner() {
  local title="$1"
  local length=${#title}
  local padding=$(printf "%-${length}s" "" | tr " " "=")

  echo -e ""
  echo -e "\033[1;32m$padding\033[0m"
  echo -e "\033[1;32m$title\033[0m"
  echo -e "\033[1;32m$padding\033[0m"
}

# ================================
# Check if the OS is Ubuntu
# ================================
OS_NAME=$(lsb_release -si)
if [ "$OS_NAME" != "Ubuntu" ]; then
  echo_error "This script is only for Ubuntu. Exiting."
  exit 1
fi

# ================================
# Function to check internet connectivity
# ================================
check_internet() {
  if ! ping -c 1 8.8.8.8 &> /dev/null; then
    return 1
  fi
  return 0
}

# ================================
# Function to check if a package is installed
# ================================
check_package_installed() {
  if ! dpkg -l | grep -q "$1"; then
    return 1
  fi
  return 0
}

# ================================
# System Update & Package Installation
# ================================
print_banner "System Update & Package Installation"

check_internet
if [ $? -eq 0 ]; then
  echo_message "Updating and upgrading system packages..."
  sudo apt update && sudo apt upgrade -y

  # Install essential security tools
  echo_message "Installing fail2ban and networking tools..."
  sudo apt install -y fail2ban net-tools ufw
else
  echo_error "No internet connectivity. Unable to proceed with updates or installations. Skipping system update and package installation."
fi

# ================================
# Configure UFW Firewall
# ================================
print_banner "Configure UFW Firewall"

check_package_installed "ufw"
if [ $? -eq 0 ]; then
  echo_message "Configuring UFW firewall..."
  sudo ufw --force enable
  sudo ufw allow ssh
  echo_success "[SECURE] Firewall setup complete. UFW is enabled."
else
  echo_error "UFW is not installed. Skipping UFW configuration due to missing package."
fi

# ================================
# Add or Configure a Privileged User
# ================================
print_banner "Add or Configure a Privileged User"

echo_question "Choose an option: [c]reate new user, [e]xisting user, [s]kip: "
read -r USER_CHOICE

if [ "$USER_CHOICE" == "c" ]; then
  echo -n "Enter the new username: "
  read -r NEW_USER
  sudo useradd -m -s /bin/bash "$NEW_USER"
  sudo passwd "$NEW_USER"
elif [ "$USER_CHOICE" == "e" ]; then
  echo -n "Enter the existing username to grant privileges: "
  read -r NEW_USER
elif [ "$USER_CHOICE" == "s" ]; then
  echo_info "Skipping user privilege configuration."
else
  echo_error "Invalid option. Skipping."
  USER_CHOICE="s"
fi

if [[ "$USER_CHOICE" == "c" || "$USER_CHOICE" == "e" ]]; then
  # Grant sudo privileges without password
  echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$NEW_USER > /dev/null
  sudo chmod 440 /etc/sudoers.d/$NEW_USER
  echo_success "[SECURE] $NEW_USER now has passwordless sudo access."
fi

# ================================
# SSH Configuration
# ================================
print_banner "SSH Configuration"

SSH_CONFIG="/etc/ssh/sshd_config"
PUB_KEY_FILE="/home/$NEW_USER/.ssh/authorized_keys"

ROOT_SSH_LOGIN="Enabled"
LIMIT_SSH_USER="No"
PUBKEY_AUTH="Disabled"
PASSWORD_AUTH="Enabled"

echo_question "Would you like to set up SSH key authentication for $NEW_USER? (Y/n) "
read -r SETUP_SSH
if [ -z "$SETUP_SSH" ] || [ "$SETUP_SSH" == "y" ] || [ "$SETUP_SSH" == "Y" ]; then
  sudo mkdir -p "/home/$NEW_USER/.ssh"
  sudo chmod 700 "/home/$NEW_USER/.ssh"
  sudo chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
  echo -n "Paste the public key for $NEW_USER, then press Enter: "
  read -r PUB_KEY
  echo "$PUB_KEY" | sudo tee "$PUB_KEY_FILE" > /dev/null
  sudo chmod 600 "$PUB_KEY_FILE"
  sudo chown "$NEW_USER:$NEW_USER" "$PUB_KEY_FILE"
  echo_success "[SECURE] Public key authentication configured."
  PUBKEY_AUTH="Enabled"
else
  echo_question "You have chosen password authentication. This is less secure."
fi

if [ "$PUBKEY_AUTH" == "Enabled" ]; then
  echo_question "Would you like to enforce PUBKEY SSH Login (disabling SSH password login)? (Y/n) "
  read -r RESPONSE
  if [ -z "$RESPONSE" ] || [ "$RESPONSE" == "y" ] || [ "$RESPONSE" == "Y" ]; then
    # Disable password authentication
    sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    sudo sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    
    # Enable public key authentication
    sudo sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"

    PASSWORD_AUTH="Disabled"
    echo_success "[SECURE] SSH Password authentication disabled."
    echo_success "[SECURE] SSH Public key authentication enforced."
    
  else
    echo_error "Password authentication remains enabled. This is not secure"
  fi
fi

echo_question "Would you like to disable root SSH login? (Y/n) "
read -r RESPONSE
if [ -z "$RESPONSE" ] || [ "$RESPONSE" == "y" ] || [ "$RESPONSE" == "Y" ]; then
  sudo sed -i 's/^#PermitRootLogin yes/PermitRootLogin no/' "$SSH_CONFIG"
  sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
  ROOT_SSH_LOGIN="Disabled"
  echo_success "[SECURE] Root login disabled."
fi


# Restart the SSH service
if sudo systemctl restart sshd; then
  echo_success "SSH service restarted successfully."
else
  echo_error "Failed to restart SSH service."
fi

# ================================
# Fail2Ban Configuration
# ================================
print_banner "Fail2Ban Configuration"

check_package_installed "fail2ban"
if [ $? -eq 0 ]; then
  echo_message "Configuring Fail2Ban for SSH protection..."
  echo "
[ssh]
enabled  = true
banaction = iptables-multiport
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
findtime = 43200
bantime  = 86400
" | sudo tee /etc/fail2ban/jail.local > /dev/null

  sudo systemctl restart fail2ban
  echo_success "Fail2Ban setup complete. SSH is now protected."
else
  echo_error "Skipping Fail2Ban configuration due to missing package."
fi

# ================================
# Summary of Security Measures
# ================================
print_banner "Summary of Security Measures"

echo_message "
Security measures applied:
1. System updated and essential security tools installed.
2. UFW firewall enabled and configured.
3. A privileged user ($NEW_USER) was set up with passwordless sudo access.
4. SSH security enhancements:
   - SSH Passowrd Authentication: $PASSWORD_AUTH
   - SSH Public Key Authentication: $PUBKEY_AUTH
   - SSH Root Login: $ROOT_SSH_LOGIN
5. Fail2Ban installed and configured to protect SSH.
"

echo_success "System hardening is complete!"
