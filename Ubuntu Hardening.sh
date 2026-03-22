#!/bin/bash

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

echo_warning() {
  echo -e "⚠️ \033[1;33m$1\033[0m"
}

echo_success() {
  echo -e "✅ \033[1;32m$1\033[0m"
}

echo_error() {
  echo -e "❌ \033[1;31m$1\033[0m"
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
# Ensure script runs as root
# ================================
if [ "$EUID" -ne 0 ]; then
    if command -v sudo &> /dev/null; then
        echo "Not running as root. Re-running with sudo..."
        exec sudo bash "$0" "$@"
    else
        echo "Error: This script must be run as root or sudo is not installed."
        exit 1
    fi
fi

# ================================
# Ensure OS is Ubuntu
# ================================
# Read OS name from /etc/os-release
OS_NAME=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

if [ "$OS_NAME" != "ubuntu" ]; then
  echo "Error: This script is only for Ubuntu. Exiting." >&2
  exit 1
fi


# ================================
# Function to check internet connectivity using apt
# ================================
internet_is_available() {
    apt update -o Acquire::http::Timeout=5 -o Acquire::https::Timeout=5 -qq &> /dev/null
    return $?
}

# ================================
# Function to check if a package is installed
# ================================
software_is_installed() {
  if command -v "$1" >/dev/null 2>&1; then
      echo_success "$1 is installed."
      return 0   # 0 = success
  else
      echo_error "$1 is NOT installed."
      return 1   # 1 = failure
  fi
}

# ================================
# Ensure presence of software packages
# ================================
REQUIRED_SOFTWARE=("which" "dpkg" "apt" "sed" "service")
AUX_SOFTWARE=("sshd" "ufw" "fail2ban" "sudo")

print_banner "Checking required software"
for software in "${REQUIRED_SOFTWARE[@]}"; do
  if ! software_is_installed "$software"; then
      echo_error "Required software $software is missing. Aborting."
      exit 1
  fi
done
echo

print_banner "Checking auxiliary software"
for software in "${AUX_SOFTWARE[@]}"; do
  if ! software_is_installed "$software"; then
      echo_warning "$software is missing. You will be asked if you wish to install it later."
  fi
done
echo

# ================================
# System Update
# ================================
print_banner "System Update"

if internet_is_available; then
  echo_message "Updating and upgrading system packages..."
  apt update && apt upgrade -y
  echo

  # Installing essential security tools
  echo_message "Installing fail2ban, net-tools and ufw"
  echo
  apt install -y fail2ban net-tools ufw
else
  echo_error "No internet connectivity. Unable to proceed with updates or installations. Skipping system update and package installation."
fi


# ================================
# Configure UFW Firewall
# ================================
print_banner "Configure UFW Firewall"

if [ -f /.dockerenv ]; then
    echo_message "Running inside Docker. Skipping UFW configuration."
    echo
else
    
    if internet_is_available; then
        echo_message "Installing UFW..."
        if apt update && apt install -y ufw; then
            echo_success "UFW installed successfully."
        else
            echo_error "Failed to install UFW. Skipping configuration."
        fi
    else
        echo_error "No internet connectivity. Cannot install UFW."
    fi

    # Only configure if ufw is installed
    if software_is_installed ufw; then
        echo_message "Configuring UFW firewall..."
        ufw --force enable
        ufw allow ssh
        echo_success "[SECURE] Firewall setup complete. UFW is enabled."
    else
        echo_error "UFW is not installed. Skipping UFW configuration."
    fi
fi


# ================================
# Add or Configure a Privileged User
# ================================

print_banner "Add or Configure a Privileged User"

echo_question "Choose an option: [c]reate new user, [e]xisting user, [s]kip: "
read -r USER_CHOICE

if [[ "$USER_CHOICE" == "c" || "$USER_CHOICE" == "e" ]]; then

  # Check if sudo is installed
  if ! software_is_installed sudo; then
      echo_question "Do you want to install sudo? (Y/n) "
      read -r INSTALL_SUDO_RESPONSE

      if [[ -z "$INSTALL_SUDO_RESPONSE" || "$INSTALL_SUDO_RESPONSE" =~ ^[Yy]$ ]]; then
          echo_message "Installing sudo..."
          apt update && apt install -y sudo

          if ! software_is_installed sudo; then
              echo_error "Failed to install sudo. Continuing without sudo privileges."
              SUDO_INSTALLED=0
          else
              SUDO_INSTALLED=1
          fi
      else
          echo_error "Skipping sudo installation. Continuing without sudo privileges."
          SUDO_INSTALLED=0
      fi
  else
      SUDO_INSTALLED=1
  fi

  # Handle new or existing user
  if [[ "$USER_CHOICE" == "c" ]]; then
      echo -n "Enter the new username: "
      read -r USERNAME

      if id "$USERNAME" >/dev/null 2>&1; then
          echo_error "User $USERNAME already exists. Skipping creation."
      else
          useradd -m -s /bin/bash "$USERNAME"
          passwd "$USERNAME"
          echo_success "User $USERNAME created."
      fi

  elif [[ "$USER_CHOICE" == "e" ]]; then
      echo -n "Enter the existing username to grant privileges: "
      read -r USERNAME

      if ! id "$USERNAME" >/dev/null 2>&1; then
          echo_error "User $USERNAME does not exist. Cannot grant privileges."
          USERNAME=""
      fi
  fi

  # Grant passwordless sudo only if sudo is installed and user exists
  if [[ "$SUDO_INSTALLED" -eq 1 && -n "$USERNAME" ]]; then
      echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | tee /etc/sudoers.d/"$USERNAME" >/dev/null
      chmod 440 /etc/sudoers.d/"$USERNAME"
      echo_success "[SECURE] $USERNAME now has passwordless sudo access."
  else
      echo_info "Skipping passwordless sudo configuration."
  fi

else
  if [[ "$USER_CHOICE" == "s" ]]; then
      echo_info "Skipping user privilege configuration."
  else
      echo_error "Invalid option. Skipping."
  fi
fi

# ================================
# OpenSSH Configuration
# ================================
print_banner "SSH Configuration"

if ! software_is_installed sshd; then
    echo_question "Do you want to install OpenSSH Server? (Y/n) "
    read -r INSTALL_SSH_RESPONSE

    if [ -z "$INSTALL_SSH_RESPONSE" ] || [[ "$INSTALL_SSH_RESPONSE" =~ ^[Yy]$ ]]; then
        echo_message "Installing OpenSSH server..."
        apt update && apt install -y openssh-server

        # Check installation success
        if software_is_installed sshd; then
            echo_success "SSH server installed successfully."

            #Starting the service
            service ssh start
        else
            echo_error "Failed to install SSH server. Skipping SSH configuration."
        fi
    else
        echo_message "Skipping SSH configuration."
        SSH_INSTALLED=0
    fi
fi

# Only proceed with SSH configuration if OpenSSH Server is installed
if software_is_installed sshd; then
  SSH_CONFIG="/etc/ssh/sshd_config"
  PUB_KEY_FILE="/home/$USERNAME/.ssh/authorized_keys"

  ROOT_SSH_LOGIN="Enabled"
  LIMIT_SSH_USER="No"
  PUBKEY_AUTH="Disabled"
  PASSWORD_AUTH="Enabled"

  echo_question "Would you like to set up SSH key authentication for $USERNAME? (Y/n) "
  read -r SETUP_SSH
  if [ -z "$SETUP_SSH" ] || [ "$SETUP_SSH" == "y" ] || [ "$SETUP_SSH" == "Y" ]; then
    mkdir -p "/home/$USERNAME/.ssh"
    chmod 700 "/home/$USERNAME/.ssh"
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
    echo -n "Paste the public key for $USERNAME, then press Enter: "
    read -r PUB_KEY
    echo "$PUB_KEY" | tee "$PUB_KEY_FILE" > /dev/null
    chmod 600 "$PUB_KEY_FILE"
    chown "$USERNAME:$USERNAME" "$PUB_KEY_FILE"
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
      sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
      sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
      
      # Enable public key authentication
      sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"

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
    sed -i 's/^#PermitRootLogin yes/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    ROOT_SSH_LOGIN="Disabled"
    echo_success "[SECURE] Root login disabled."
  fi

  # Reload SSH safely
  if service ssh reload 2>/dev/null; then
      echo_success "SSH service configuration reloaded successfully."
  else
      echo_error "Failed to restart SSH service."
  fi

fi

# ================================
# Fail2Ban Configuration
# ================================
print_banner "Fail2Ban Configuration"

# Check internet connectivity before attempting installation
if internet_is_available; then
    echo_message "Installing Fail2Ban..."
    apt install -y fail2ban
else
    echo_error "No internet connectivity. Unable to install Fail2Ban."
fi

# Configure Fail2Ban only if the package is installed
if software_is_installed "fail2ban-server"; then
    echo_message "Configuring Fail2Ban for SSH protection..."

    # Create or overwrite jail.local with SSH protection settings
    cat <<EOF | tee /etc/fail2ban/jail.local > /dev/null
[ssh]
enabled   = true
banaction = iptables-multiport
port      = ssh
filter    = sshd
logpath   = /var/log/auth.log
maxretry  = 5
findtime  = 43200
bantime   = 86400
EOF

    # Restart Fail2Ban to apply the configuration
    service fail2ban restart
    echo_success "Fail2Ban setup complete. SSH is now protected."
else
    echo_error "Skipping Fail2Ban configuration: package not installed."
fi

# ================================
# Summary of Security Measures
# ================================
print_banner "Summary of Security Measures"

echo_message "
Security measures applied:
1. System updated and essential security tools installed.
2. UFW firewall enabled and configured.
3. A privileged user ($USERNAME) was set up with passwordless sudo access.
4. SSH security enhancements:
   - SSH Passowrd Authentication: $PASSWORD_AUTH
   - SSH Public Key Authentication: $PUBKEY_AUTH
   - SSH Root Login: $ROOT_SSH_LOGIN
5. Fail2Ban installed and configured to protect SSH.
"

echo_success "System hardening is complete!"
