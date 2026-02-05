#!/bin/bash
#
# deploymentovpn.sh (Ultimate Edition: Feature-Complete & RAM-Optimized)
#
# This script combines the best of both worlds:
# 1. FEATURE-COMPLETE: It can parse rotated logs and supports agent decommission.
# 2. RAM-OPTIMIZED: It streams large log files line-by-line to keep RAM usage low.
#
# Usage: sudo ./deploymentovpn.sh
#
set -e

# --- Default Configuration ---
PYTHON_AGENT_SCRIPT_NAME="main.py"
CLIENT_MANAGER_SCRIPT_NAME="openvpn-client-manager.sh"
OPENVPN_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/Angristan/openvpn-install/master/openvpn-install.sh"
OPENVPN_INSTALL_SCRIPT_PATH=""
AGENT_USER="root"
BASE_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SCRIPT_DIR="$BASE_DIR/openvpn-agent"
VENV_PATH="$SCRIPT_DIR/venv"
EASY_RSA_INDEX_PATH=""
EASY_RSA_SERVER_NAME_PATH=""

AGENT_API_KEY=""
APP_NAME=""
DASHBOARD_API_URL=""
SERVER_ID=""
OVPN_DIRS_STRING=""

# --- Functions ---

check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        echo "⛔ Please run this script with root privileges (e.g., sudo $0)"
        exit 1
    fi
    echo "✅ Script is running with root privileges."
}

get_user_input() {
    echo ""
    while [ -z "$APP_NAME" ]; do
        read -p "🏷️  Enter the Service Name for systemd (Default: openvpn-agent): " APP_NAME
        APP_NAME=${APP_NAME:-openvpn-agent}
        [ -z "$APP_NAME" ] && echo "⛔ Service name cannot be empty."
    done
    echo ""
    while [ -z "$AGENT_API_KEY" ]; do
        read -p "🔑 Enter the AGENT_API_KEY (must match the dashboard): " AGENT_API_KEY
        [ -z "$AGENT_API_KEY" ] && echo "⛔ API Key cannot be empty."
    done
    echo ""
    while [ -z "$SERVER_ID" ]; do
        read -p "🏷️  Enter the Server ID (e.g., SERVER-01): " SERVER_ID
        [ -z "$SERVER_ID" ] && echo "⛔ Server ID cannot be empty."
    done
    echo ""
    while [ -z "$SECRET_ENCRYPTION_KEY" ]; do
        read -p "🔐  Enter the ENCRYPTION KEY (e.g., SERVER-01): " SECRET_ENCRYPTION_KEY
        [ -z "$SECRET_ENCRYPTION_KEY" ] && echo "⛔ ENCRYPTION KEY cannot be empty."
    done
    echo ""
    echo "Select the Dashboard API protocol:"
    echo "1) HTTPS (Recommended)"
    echo "2) HTTP"
    read -p "Your choice [Default 1]: " PROTOCOL_CHOICE
    PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-1}
    case "$PROTOCOL_CHOICE" in
        1) DEFAULT_PROTOCOL="https://";;
        2) DEFAULT_PROTOCOL="http://";;
        *) DEFAULT_PROTOCOL="https://";;
    esac
    echo ""
    read -p "🌐 Enter the Dashboard API address (e.g., vpn.clouddonut.net or 192.168.1.42): " DASHBOARD_HOST_RAW
    DASHBOARD_HOST_RAW=${DASHBOARD_HOST_RAW:-vpn.clouddonut.net}
    if [[ "$DASHBOARD_HOST_RAW" =~ ^(http|https):// ]]; then
        PROTOCOL=$(echo "$DASHBOARD_HOST_RAW" | grep -oE '^(http|https)://')
        DASHBOARD_HOST_CLEAN=${DASHBOARD_HOST_RAW#*//}
    else
        PROTOCOL="$DEFAULT_PROTOCOL"
        DASHBOARD_HOST_CLEAN=$DASHBOARD_HOST_RAW
    fi
    if [[ "$DASHBOARD_HOST_CLEAN" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        BASE_URL="${PROTOCOL}${DASHBOARD_HOST_CLEAN}"
        if ping -c 1 -W 1 "$DASHBOARD_HOST_CLEAN" &>/dev/null; then
            echo "✅ Dashboard API IP ($DASHBOARD_HOST_CLEAN) is reachable."
        else
            echo "⚠️  Dashboard API IP ($DASHBOARD_HOST_CLEAN) might not be reachable, but proceeding..."
        fi
    elif [[ "$DASHBOARD_HOST_CLEAN" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
        BASE_URL="${PROTOCOL}${DASHBOARD_HOST_CLEAN}"
        echo "✅ Domain ($DASHBOARD_HOST_CLEAN) accepted."
    else
        echo "⛔ Invalid format. Please enter a valid IP address or domain name."
        exit 1
    fi
    read -p "Does the Dashboard API use a custom port? (Default: N) [y/N]: " USE_CUSTOM_PORT
    USE_CUSTOM_PORT=${USE_CUSTOM_PORT:-N}
    local FINAL_PORT_PART=""
    if [[ "$USE_CUSTOM_PORT" =~ ^[yY]$ ]]; then
        local port_valid=0
        while [ $port_valid -eq 0 ]; do
            read -p "🔌 Enter the Custom Port (e.g., 3000): " DASHBOARD_PORT
            if [[ "$DASHBOARD_PORT" =~ ^[0-9]+$ ]] && [ "$DASHBOARD_PORT" -ge 1 ] && [ "$DASHBOARD_PORT" -le 65535 ]; then
                FINAL_PORT_PART=":${DASHBOARD_PORT}"
                port_valid=1
            else
                echo "⛔ Invalid port. Enter 1-65535."
            fi
        done
    fi
    local TEMP_URL="${BASE_URL}${FINAL_PORT_PART}"
    [[ "$TEMP_URL" != */api ]] && DASHBOARD_API_URL="${TEMP_URL}/api" || DASHBOARD_API_URL="${TEMP_URL}"
    echo "✅ Dashboard API URL set to: $DASHBOARD_API_URL"

    echo ""
    echo "📁 Please enter the directories where .ovpn files are stored."
    declare -a OVPN_DIRS_ARRAY
    local first_dir=true
    while true; do
        local prompt_text="Enter an OVPN directory path"
        local default_dir=""
        if $first_dir; then
            prompt_text="Enter the primary OVPN directory path (Default: /root)"
            default_dir="/root"
        fi
        read -p "$prompt_text: " dir_input
        dir_input=${dir_input:-$default_dir}
        if [ -z "$dir_input" ] && ! $first_dir; then
             echo "Directory path cannot be empty. Please try again."
             continue
        fi
        if [ ! -d "$dir_input" ]; then
            echo "⚠️  Warning: Directory '$dir_input' does not exist. It will be added anyway."
        fi
        OVPN_DIRS_ARRAY+=("$dir_input")
        echo "✅ Added directory: $dir_input"
        first_dir=false
        read -p "Add another directory? [y/N]: " add_more
        if [[ ! "$add_more" =~ ^[yY]$ ]]; then
            break
        fi
    done
    OVPN_DIRS_STRING=$(printf "%s," "${OVPN_DIRS_ARRAY[@]}")
    OVPN_DIRS_STRING=${OVPN_DIRS_STRING%,}
    echo "✅ Final OVPN directories: $OVPN_DIRS_STRING"

    echo ""
    read -p "💾 Enter RAM limit for the agent (e.g., 100M). Default: 100M: " RAM_LIMIT
    RAM_LIMIT=${RAM_LIMIT:-100M}
    echo "✅ Agent will be limited to $RAM_LIMIT of RAM."

    echo ""
    read -p "⏱️  Enter main loop interval in seconds (Default: 60): " METRICS_INTERVAL
    METRICS_INTERVAL=${METRICS_INTERVAL:-60}
    echo "✅ Main loop interval: $METRICS_INTERVAL sec."

    read -p "⏱️  Enter CPU/RAM monitoring interval (Default: 60, 'N' to disable): " CPU_RAM_INTERVAL_INPUT
    CPU_RAM_INTERVAL_INPUT=${CPU_RAM_INTERVAL_INPUT:-60}
    if [[ "${CPU_RAM_INTERVAL_INPUT^^}" == "N" ]]; then
        CPU_RAM_INTERVAL="disabled"
        echo "✅ CPU/RAM monitoring disabled."
    elif [[ "$CPU_RAM_INTERVAL_INPUT" =~ ^[0-9]+$ ]] && [ "$CPU_RAM_INTERVAL_INPUT" -gt 0 ]; then
        CPU_RAM_INTERVAL="$CPU_RAM_INTERVAL_INPUT"
        echo "✅ CPU/RAM monitoring: $CPU_RAM_INTERVAL sec."
    else
        echo "⚠️  Invalid input, using default 60s."
        CPU_RAM_INTERVAL=60
    fi
}

cleanup_old_pm2_installation() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🧹 CLEANING UP OLD PM2-BASED AGENT INSTALLATION"
    echo "═══════════════════════════════════════════════"
    echo ""
    if command -v pm2 &> /dev/null; then
        echo "[-] Found old PM2 installation. Stopping and removing processes..."
        pm2 stop all >/dev/null 2>&1 || true
        pm2 delete all >/dev/null 2>&1 || true
        pm2 kill >/dev/null 2>&1 || true
        echo "[-] Uninstalling PM2 globally..."
        export NVM_DIR="/root/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        if command -v npm &> /dev/null; then
            npm uninstall -g pm2 >/dev/null 2>&1 || true
            echo "✅ PM2 uninstalled."
        else
            echo "⚠️   npm not found, cannot uninstall PM2 automatically. Skipping."
        fi
        echo "[-] Removing PM2 startup scripts..."
        pm2 unstartup >/dev/null 2>&1 || true
        echo "[-] Removing PM2 home directory..."
        rm -rf "/root/.pm2"
    else
        echo "✅ No PM2 installation found. Skipping PM2 cleanup."
    fi
    if [ -d "/root/.nvm" ]; then
        echo "[-] Found old NVM installation. Removing..."
        command -v nvm &> /dev/null && nvm unload || true
        rm -rf "/root/.nvm"
        sed -i '/NVM_DIR/d' "/root/.bashrc" "/root/.profile" >/dev/null 2>&1 || true
        sed -i '/nvm.sh/d' "/root/.bashrc" "/root/.profile" >/dev/null 2>&1 || true
        echo "✅ NVM and Node.js removed."
    else
        echo "✅ No NVM installation found. Skipping NVM cleanup."
    fi
    echo "[-] Removing old symlinks..."
    rm -f /usr/local/bin/node
    rm -f /usr/local/bin/pm2
    if dpkg -l | grep "snmpd"; then
        echo "[-] Found old snmpd package. Removing..."
        apt-get purge --auto-remove -y snmpd >/dev/null 2>&1
        echo "✅ snmpd package removed."
    else
        echo "✅ No snmpd package found. Skipping."
    fi
    echo ""
    echo "✅ OLD INSTALLATION CLEANUP COMPLETE"
}

check_and_install_openvpn() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║  🔎 CHECKING OPENVPN INSTALLATION STATUS      ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    local service_names=("openvpn-server@server" "openvpn@server" "openvpn")
    local openvpn_found=false
    echo "🔎 Searching for OpenVPN service..."
    for service in "${service_names[@]}"; do
        if systemctl is-active "$service" &>/dev/null; then
            echo "✅ OpenVPN service ($service) found and running."
            openvpn_found=true
            break
        fi
    done

    if ! $openvpn_found && pgrep openvpn &>/dev/null; then
        echo "✅ OpenVPN process found running."
        openvpn_found=true
    fi

    if $openvpn_found; then
        echo "✅ OpenVPN is already installed and running."
    else
        echo "⚠️ OpenVPN is not installed or not running on this server. The installer script is required."
    fi

    echo ""
    echo "🔎 Searching for the OpenVPN installer script (e.g., ubuntu-22.04-lts-vpn-server.sh)..."
    local installer_found=false
    local search_paths=("/root" "${OVPN_DIRS_ARRAY[@]}")
    local possible_names=("openvpn-install.sh" "ubuntu-22.04-lts-vpn-server.sh")

    for dir in "${search_paths[@]}"; do
        for name in "${possible_names[@]}"; do
            local full_path="$dir/$name"
            if [ -f "$full_path" ]; then
                OPENVPN_INSTALL_SCRIPT_PATH="$full_path"
                echo "✅ Found existing installer script at: $OPENVPN_INSTALL_SCRIPT_PATH"
                installer_found=true
                break 2
            fi
        done
    done

    if ! $installer_found; then
        echo "⚠️ Installer script not found in provided directories."
        echo "What would you like to do?"
        echo "  1) Download the script automatically to /root/ubuntu-22.04-lts-vpn-server.sh (Recommended)"
        echo "  2) Specify the path to an existing script manually"
        echo "  3) Exit installation"
        read -p "Your choice [1]: " installer_choice
        installer_choice=${installer_choice:-1}

        case "$installer_choice" in
            1)
                OPENVPN_INSTALL_SCRIPT_PATH="/root/ubuntu-22.04-lts-vpn-server.sh"
                echo "📥 Downloading Angristan's OpenVPN installation script to $OPENVPN_INSTALL_SCRIPT_PATH..."
                if ! wget "$OPENVPN_INSTALL_SCRIPT_URL" -O "$OPENVPN_INSTALL_SCRIPT_PATH"; then
                    echo "⛔ Failed to download OpenVPN installation script."
                    exit 1
                fi
                echo "✅ Script downloaded successfully."
                ;;
            2)
                # --- LOGIKA BARU UNTUK INPUT PINTAR ---
                while true; do
                    read -p "📂 Enter the full path to the script OR the directory containing it: " user_path
                    if [ -f "$user_path" ]; then
                        # Jika input adalah file yang valid
                        OPENVPN_INSTALL_SCRIPT_PATH="$user_path"
                        echo "✅ Using installer script at: $OPENVPN_INSTALL_SCRIPT_PATH"
                        break
                    elif [ -d "$user_path" ]; then
                        # Jika input adalah direktori, cari di dalamnya
                        local found_in_dir=false
                        for name in "${possible_names[@]}"; do
                            local potential_file="$user_path/$name"
                            if [ -f "$potential_file" ]; then
                                OPENVPN_INSTALL_SCRIPT_PATH="$potential_file"
                                echo "✅ Found installer script inside the directory: $OPENVPN_INSTALL_SCRIPT_PATH"
                                found_in_dir=true
                                break
                            fi
                        done
                        if $found_in_dir; then
                            break
                        else
                            echo "⛔ Installer script not found inside directory '$user_path'. Please try again."
                        fi
                    else
                        echo "⛔ Path '$user_path' is not a valid file or directory. Please try again."
                    fi
                done
                ;;
            *)
                echo "❌ Exiting installation."
                exit 1
                ;;
        esac
    fi

    echo "🔐 Making installer script executable..."
    chmod -v +x "$OPENVPN_INSTALL_SCRIPT_PATH"
    echo ""

    if ! $openvpn_found; then
        echo "▶️  Running OpenVPN installation script..."
        echo "⚠️  Please follow the prompts to configure your OpenVPN server."
        echo ""
        if ! sudo bash "$OPENVPN_INSTALL_SCRIPT_PATH"; then
            echo "⛔ Failed to install OpenVPN. Please check the errors above."
            exit 1
        fi
        echo ""
        echo "✅ OpenVPN installed and configured successfully."
        echo "⏳ Waiting for OpenVPN service to start..."
        sleep 5
        local install_verified=false
        for service in "${service_names[@]}"; do
            if systemctl is-active "$service" &>/dev/null; then
                echo "✅ OpenVPN service ($service) is now running."
                install_verified=true
                break
            fi
        done
        if ! $install_verified; then
            echo "⛔ OpenVPN installation verification failed. Please check manually."
            exit 1
        fi
    fi
}

find_easy_rsa_path() {
    echo "🔍 Dynamically searching for Easy-RSA index.txt path..."
    local paths_to_check=(
        "/etc/openvpn/easy-rsa/pki/index.txt"
        "/etc/openvpn/pki/index.txt"
        "/usr/share/easy-rsa/pki/index.txt"
        "/etc/easy-rsa/pki/index.txt"
        "/etc/openvpn/server/easy-rsa/pki/index.txt"
    )
    for path in "${paths_to_check[@]}"; do
        if [ -f "$path" ]; then
            EASY_RSA_INDEX_PATH="$path"
            EASY_RSA_DIR=$(dirname "$EASY_RSA_INDEX_PATH" | xargs dirname)
            EASY_RSA_SERVER_NAME_PATH="$EASY_RSA_DIR/SERVER_NAME_GENERATED"
            echo "✅ Found index.txt path: $EASY_RSA_INDEX_PATH"
            return 0
        fi
    done
    echo "⚠️  Easy-RSA index.txt path not found in common locations."
    echo "   Locations checked:"
    for path in "${paths_to_check[@]}"; do
        echo "   • $path"
    done
    
    # Ask user for the path instead of failing
    while true; do
        read -p "📁 Please enter the full path to your Easy-RSA index.txt file: " user_index_path
        if [ -f "$user_index_path" ]; then
            EASY_RSA_INDEX_PATH="$user_index_path"
            EASY_RSA_DIR=$(dirname "$EASY_RSA_INDEX_PATH" | xargs dirname)
            EASY_RSA_SERVER_NAME_PATH="$EASY_RSA_DIR/SERVER_NAME_GENERATED"
            echo "✅ Using index.txt path: $EASY_RSA_INDEX_PATH"
            return 0
        else
            echo "⛔ The file '$user_index_path' does not exist. Please try again."
        fi
    done
}

install_dependencies() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "⚙️  INSTALLING SYSTEM DEPENDENCIES (FOR ROOT)"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "📦 Updating package lists..."
    apt-get update 
    echo "📦 Installing system dependencies..."
    apt-get install -y python3 python3-pip python3-venv dos2unix at
    dos2unix "$0" >/dev/null 2>&1
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🐍 CONFIGURING PYTHON VIRTUAL ENVIRONMENT"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "🏗️  Creating Python virtual environment at $VENV_PATH..."
    python3 -m venv "$VENV_PATH"
    echo "✅ Virtual environment created successfully."
    echo "📦 Installing Python dependencies..."
    "$VENV_PATH/bin/pip" install --upgrade pip
    echo "   Installing: python-dotenv, requests, psutil, pycryptodome..."
    if "$VENV_PATH/bin/pip" install python-dotenv psutil requests pycryptodome; then
        echo "✅ All Python dependencies installed successfully."
    else
        echo "⛔ Failed to install Python dependencies."
        exit 1
    fi
    echo ""
    echo "✅ DEPENDENCY INSTALLATION COMPLETE"
}

create_env_file() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "📄 CREATING CONFIGURATION FILE"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "📝 Creating .env file with configuration..."
    cat << EOF | tee "$SCRIPT_DIR/.env" > /dev/null
# OpenVPN Agent Configuration
# Generated by deploymentovpn.sh on $(date)
AGENT_API_KEY="$AGENT_API_KEY"
SERVER_ID="$SERVER_ID"
DASHBOARD_API_URL="$DASHBOARD_API_URL"
SCRIPT_PATH="$SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME"
OVPN_DIRS="$OVPN_DIRS_STRING"
EASY_RSA_INDEX_PATH="$EASY_RSA_INDEX_PATH"
EASY_RSA_SERVER_NAME_PATH="$EASY_RSA_SERVER_NAME_PATH"
OVPN_ACTIVITY_LOG_PATH="/var/log/openvpn/user_activity.log"
OPENVPN_LOG_PATH="/var/log/openvpn/openvpn.log"
SERVICE_NAME="$APP_NAME"
METRICS_INTERVAL_SECONDS="$METRICS_INTERVAL"
CPU_RAM_MONITORING_INTERVAL="$CPU_RAM_INTERVAL"
SECRET_ENCRYPTION_KEY="$SECRET_ENCRYPTION_KEY"
EOF
    chown "$AGENT_USER":"$AGENT_USER" "$SCRIPT_DIR/.env"
    chmod 600 "$SCRIPT_DIR/.env"
    echo "✅ .env file created successfully."
}

deploy_scripts() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "📂 DEPLOYING APPLICATION SCRIPTS"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "📁 Ensuring directory structure..."
    mkdir -p "$SCRIPT_DIR/logs"
    mkdir -p "/var/log/openvpn"

    touch "/var/log/openvpn/user_activity.log"
    chown nobody:nogroup "/var/log/openvpn/user_activity.log"
    chmod 640 "/var/log/openvpn/user_activity.log"

    touch "/var/log/openvpn/openvpn.log"
    chown nobody:nogroup "/var/log/openvpn/openvpn.log"
    chmod 640 "/var/log/openvpn/openvpn.log"

    touch "/var/log/openvpn/status.log"
    chown nobody:nogroup "/var/log/openvpn/status.log"
    chmod 640 "/var/log/openvpn/status.log"
    
    chown -R "$AGENT_USER":"$AGENT_USER" "$SCRIPT_DIR"

    echo "🐍 Writing Python agent script to $SCRIPT_DIR/$PYTHON_AGENT_SCRIPT_NAME..."
    cat << '_PYTHON_SCRIPT_EOF_' | tee "$SCRIPT_DIR/$PYTHON_AGENT_SCRIPT_NAME" > /dev/null
#!/usr/bin/env python3
# main.py (FINAL VERSION: True RAM-Optimized Stateful Agent)
import os
import sys
import time
import requests
import hashlib
import re
import glob
import json
from datetime import datetime, timezone
from typing import Dict, Optional, List
from dotenv import load_dotenv
import psutil
from Crypto.Cipher import AES
from Crypto.Random import get_random_bytes
import base64

load_dotenv()
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# --- Konfigurasi ---
AGENT_API_KEY = os.getenv("AGENT_API_KEY")
SERVER_ID = os.getenv("SERVER_ID")
DASHBOARD_API_URL = os.getenv("DASHBOARD_API_URL")
SCRIPT_PATH = os.getenv("SCRIPT_PATH", "./openvpn-client-manager.sh")
OVPN_DIRS_STR = os.getenv("OVPN_DIRS", "/root")
OVPN_DIRS = [d.strip() for d in OVPN_DIRS_STR.split(',') if d.strip()]
EASY_RSA_INDEX_PATH = os.getenv("EASY_RSA_INDEX_PATH")
EASY_RSA_SERVER_NAME_PATH = os.getenv("EASY_RSA_SERVER_NAME_PATH")
OVPN_ACTIVITY_LOG_PATH = os.getenv("OVPN_ACTIVITY_LOG_PATH")
OPENVPN_LOG_PATH = os.getenv("OPENVPN_LOG_PATH")
METRICS_INTERVAL = int(os.getenv("METRICS_INTERVAL_SECONDS", "60"))
CPU_RAM_MONITORING_INTERVAL_STR = os.getenv("CPU_RAM_MONITORING_INTERVAL", "60")
LOG_BATCH_SIZE = 500
STATE_FILE_PATH = os.path.join(SCRIPT_DIR, ".agent_state.json")

if CPU_RAM_MONITORING_INTERVAL_STR.lower() == "disabled":
    CPU_RAM_MONITORING_INTERVAL = None
else:
    try:
        CPU_RAM_MONITORING_INTERVAL = int(CPU_RAM_MONITORING_INTERVAL_STR)
        if CPU_RAM_MONITORING_INTERVAL <= 0: raise ValueError
    except (ValueError, TypeError):
        CPU_RAM_MONITORING_INTERVAL = 60

# --- Validasi Konfigurasi ---
if not all([AGENT_API_KEY, SERVER_ID, DASHBOARD_API_URL, EASY_RSA_INDEX_PATH]):
    print("❌ Missing required environment variables. Check .env file.")
    sys.exit(1)

# --- State Management ---
def load_state():
    if not os.path.exists(STATE_FILE_PATH): return {"files": {}}
    try:
        with open(STATE_FILE_PATH, 'r') as f: return json.load(f)
    except (json.JSONDecodeError, FileNotFoundError): return {"files": {}}

def save_state(state):
    with open(STATE_FILE_PATH, 'w') as f: json.dump(state, f, indent=4)

# --- Global State ---
last_vpn_profiles_checksum = None

# === HELPER FUNCTIONS ===

# << MERGED FROM SCRIPT 2: RAM-optimized checksum calculation
def get_streamed_checksum(filepath: str) -> Optional[str]:
    if not os.path.exists(filepath): return None
    hasher = hashlib.md5()
    try:
        with open(filepath, 'rb') as f:
            for chunk in iter(lambda: f.read(8192), b""):
                hasher.update(chunk)
        return hasher.hexdigest()
    except Exception as e:
        print(f"Could not calculate checksum for {filepath}: {e}")
        return None

def get_cpu_usage() -> float:
    return psutil.cpu_percent(interval=0.1)

def get_ram_usage() -> float:
    return psutil.virtual_memory().percent

def find_ovpn_file(username: str) -> Optional[str]:
    target_filename_lower = f"{username.lower()}.ovpn"
    for base_dir in OVPN_DIRS:
        for root, _, files in os.walk(base_dir):
            for file in files:
                if file.lower() == target_filename_lower:
                    file_path = os.path.join(root, file)
                    try:
                        with open(file_path, 'r') as f:
                            return f.read()
                    except Exception as e:
                        print(f"⚠️  Could not read {file_path}: {e}")
                        continue
    return None

def sanitize_username(username: str) -> str:
    sanitized = re.sub(r'[^a-zA-Z0-9_\-]', '', username.strip()).lower()
    if not re.match(r"^[a-zA-Z0-9_\-]{3,30}$", sanitized):
        raise ValueError("Invalid username format")
    return sanitized

def get_openvpn_service_status() -> str:
    try:
        result = os.system("systemctl is-active --quiet openvpn@server")
        return "running" if result == 0 else "stopped"
    except:
        return "error"

def get_server_cn() -> str:
    if EASY_RSA_SERVER_NAME_PATH and os.path.exists(EASY_RSA_SERVER_NAME_PATH):
        try:
            with open(EASY_RSA_SERVER_NAME_PATH, 'r') as f:
                return f.read().strip()
        except:
            pass
    return "server_irL5Kfmg3FnRZaGE"

def get_openvpn_active_users() -> list:
    users = []
    status_log_path = "/var/log/openvpn/status.log"
    if not os.path.exists(status_log_path):
        return []
    try:
        with open(status_log_path, 'r') as f:
            content = f.read()
            parsing = False
            for line in content.split('\n'):
                if line.startswith("Common Name,Real Address"):
                    parsing = True
                    continue
                if line.startswith("ROUTING TABLE") or line.startswith("GLOBAL STATS"):
                    break
                if parsing and line:
                    parts = line.split(',')
                    if parts and parts[0]:
                        users.append(parts[0].lower())
    except:
        pass
    return users

def run_command(cmd: list) -> None:
    import subprocess
    subprocess.run(cmd, check=True)

# === DATA PARSING FUNCTIONS ===

def parse_full_profiles(encryption_key: bytes) -> list:
    """
    Mem-parse index.txt, mengenkripsi konten .ovpn, dan mengembalikan daftar profil.
    """
    profiles = []
    if not os.path.exists(EASY_RSA_INDEX_PATH):
        return []

    server_cn = get_server_cn()
    try:
        with open(EASY_RSA_INDEX_PATH, 'r') as f:
            for line in f:
                parts = line.strip().split('\t')
                if len(parts) < 6:
                    continue

                cn_match = re.search(r'/CN=([^/]+)', line)
                username_raw = cn_match.group(1) if cn_match else "unknown"
                if username_raw == server_cn:
                    continue

                username = "".join(filter(str.isprintable, username_raw)).lower().strip()
                cert_status, exp_str, rev_str, serial = parts[0], parts[1], parts[2], parts[3]

                expiration_date, revocation_date = None, None
                try:
                    if exp_str and exp_str != 'Z':
                        dt = datetime.strptime(exp_str, '%y%m%d%H%M%SZ')
                        expiration_date = dt.replace(tzinfo=timezone.utc)
                except ValueError:
                    pass

                try:
                    if cert_status == 'R' and rev_str and rev_str != 'Z':
                        dt = datetime.strptime(rev_str, '%y%m%d%H%M%SZ')
                        revocation_date = dt.replace(tzinfo=timezone.utc)
                except ValueError:
                    pass

                status_map = {'V': 'VALID', 'R': 'REVOKED', 'E': 'EXPIRED'}
                vpn_status = status_map.get(cert_status, "UNKNOWN")

                ovpn_content_plain = find_ovpn_file(username) if vpn_status == "VALID" else None

                encrypted_content = None
                if ovpn_content_plain:
                    try:
                        # Enkripsi konten di sini
                        encrypted_content = encrypt(ovpn_content_plain, encryption_key)
                    except Exception as e:
                        print(f"⚠️  Gagal mengenkripsi profil untuk {username}: {e}")

                profiles.append({
                    "username": username,
                    "status": vpn_status,
                    "expirationDate": expiration_date.isoformat() if expiration_date else None,
                    "revocationDate": revocation_date.isoformat() if revocation_date else None,
                    "serialNumber": serial,
                    "ovpnFileContent": encrypted_content,  # Gunakan konten yang sudah terenkripsi
                })
        return profiles
    except Exception as e:
        print(f"Error parsing index.txt: {e}")
        return []

# --- Fungsi Sinkronisasi Profil ---
def sync_profiles(headers: Dict[str, str], encryption_key: bytes) -> None:
    """
    Memeriksa perubahan pada index.txt dan mengirimkan profil terenkripsi jika ada perubahan.
    """
    global last_vpn_profiles_checksum
    try:
        prof_checksum = get_streamed_checksum(EASY_RSA_INDEX_PATH)
        if prof_checksum and prof_checksum != last_vpn_profiles_checksum:
            print("Change detected, syncing full VPN profiles...")
            # Teruskan kunci enkripsi saat memanggil parse_full_profiles
            full_profiles = parse_full_profiles(encryption_key)

            requests.post(
                f"{DASHBOARD_API_URL}/agent/sync-profiles",
                json={"serverId": SERVER_ID, "vpnProfiles": full_profiles},
                headers=headers,
                timeout=30
            )
            last_vpn_profiles_checksum = prof_checksum
            del full_profiles  # Hapus dari memori setelah dikirim
    except Exception as e:
        print(f"[ERROR] Failed during profile sync: {e}")

# --- ✅ FUNGSI PENGIRIMAN BATCH YANG DIPERBARUI ---
def send_batch(batch: list, endpoint: str, headers: dict) -> bool:
    if not batch: return True
    payload_key = "activityLogs" if "activity" in endpoint else "openvpnLogs"
    payload = {"serverId": SERVER_ID, payload_key: batch}
    try:
        response = requests.post(f"{DASHBOARD_API_URL}{endpoint}", json=payload, headers=headers, timeout=60)
        response.raise_for_status()
        print(f"Successfully sent batch of {len(batch)} logs to {endpoint}.")
        return True
    except requests.RequestException as e:
        print(f"⛔ Failed to send log batch to {endpoint}: {e}. State will not be updated.")
        return False

# --- ✅ FUNGSI PROSES LOG YANG BENAR-BENAR HEMAT RAM ---
def process_log_file(log_key: str, base_path: str, parser_func, endpoint: str, headers: dict):
    agent_state = load_state()
    file_state = agent_state.get("files", {}).get(log_key, {})

    is_first_run = not bool(file_state)

    # --- ✅ PERUBAHAN UTAMA: Logika "Skip" hanya untuk "openvpn_log" ---
    if is_first_run and log_key == "openvpn_log":
        print(f"First run for {log_key}. Skipping all existing content.")
        try:
            current_stat = os.stat(base_path)
            agent_state["files"][log_key] = {"inode": current_stat.st_ino, "position": current_stat.st_size}
            save_state(agent_state)
            print(f"State initialized for {log_key}. Will only process new logs from now on.")
            return
        except FileNotFoundError:
            return
    # --- AKHIR DARI PERUBAHAN ---

    last_inode = file_state.get("inode")
    last_position = file_state.get("position", 0)

    try:
        current_stat = os.stat(base_path)
        current_inode = current_stat.st_ino
    except FileNotFoundError:
        return

    if last_inode and last_inode != current_inode:
        print(f"Log rotation detected for {log_key}. Resetting position for new file.")
        last_position = 0

    try:
        with open(base_path, 'r', errors='ignore') as f:
            f.seek(last_position)
            batch = []

            while True:
                line = f.readline()
                if not line: break

                parsed = parser_func(line)
                if parsed: batch.append(parsed)

                if len(batch) >= LOG_BATCH_SIZE:
                    if send_batch(batch, endpoint, headers):
                        new_position = f.tell()
                        agent_state["files"][log_key] = {"inode": current_inode, "position": new_position}
                        save_state(agent_state)
                        batch = []
                        time.sleep(1)
                    else:
                        return

            if batch:
                if send_batch(batch, endpoint, headers):
                    new_position = f.tell()
                    agent_state["files"][log_key] = {"inode": current_inode, "position": new_position}
                    save_state(agent_state)
    except Exception as e:
        print(f"[ERROR] in process_log_file for {log_key}: {e}")

def encrypt(plain_text: str, key: bytes) -> str:
    """Enkripsi teks menggunakan AES-GCM dan mengembalikan string Base64."""
    cipher = AES.new(key, AES.MODE_GCM)
    ciphertext, tag = cipher.encrypt_and_digest(plain_text.encode('utf-8'))
    # Gabungkan nonce, tag, dan ciphertext, lalu encode ke Base64
    # Nonce (16 bytes) + Tag (16 bytes) + Ciphertext
    encrypted_payload = base64.b64encode(cipher.nonce + tag + ciphertext).decode('utf-8')
    return encrypted_payload

# === MAIN AGENT LOOP (OPTIMIZED BATCH SYNC) ===
def main_loop():
    headers = {"Authorization": f"Bearer {AGENT_API_KEY}", "Content-Type": "application/json"}

    SECRET_KEY_STR = os.getenv("SECRET_ENCRYPTION_KEY")
    if not SECRET_KEY_STR or len(SECRET_KEY_STR) < 32:
        print("❌ SECRET_ENCRYPTION_KEY tidak valid atau terlalu pendek di .env. Harus minimal 32 karakter.")
        sys.exit(1)
    
    SECRET_KEY_BYTES = SECRET_KEY_STR.encode('utf-8')[:32]

    while True:
        try:
            # 5. Proses Aksi dari Dashboard
            resp = requests.get(f"{DASHBOARD_API_URL}/agent/action-logs?serverId={SERVER_ID}", headers=headers, timeout=10)
            actions = resp.json()
            
            # --- 🔥 OPTIMIZATION START: Flagging System ---
            needs_profile_sync = False 
            # ---------------------------------------------

            for action in actions:
                try:
                    action_id, action_type, details = action.get('id'), action.get('action'), action.get('details')
                    result = {"status": "success", "message": "", "ovpnFileContent": None}

                    action_performed = False
                    
                    print(f"Processing action: {action_type} for {details}...") # Debug print dikit

                    if action_type == "CREATE_USER":
                        username = sanitize_username(details)
                        run_command([SCRIPT_PATH, "create", username])
                        ovpn_content = find_ovpn_file(username)
                        if ovpn_content:
                            result["ovpnFileContent"] = encrypt(ovpn_content, SECRET_KEY_BYTES)
                        else:
                            result["ovpnFileContent"] = None
                        result["message"] = f"User {username} created."
                        action_performed = True
                    
                    elif action_type in ["REVOKE_USER", "DELETE_USER"]:
                        username = sanitize_username(details)
                        run_command([SCRIPT_PATH, "revoke", username])
                        result["message"] = f"User {username} revoked."
                        action_performed = True
                    
                    elif action_type == "DECOMMISSION_AGENT":
                        try:
                            requests.post(f"{DASHBOARD_API_URL}/agent/decommission-complete", json={"serverId": SERVER_ID}, headers=headers, timeout=5)
                        except:
                            pass
                        import subprocess
                        subprocess.run([
                            "sudo", "systemd-run", "--on-active=3s",
                            "/bin/bash", f"{SCRIPT_DIR}/self-destruct.sh", os.getenv("SERVICE_NAME", "openvpn-agent")
                        ])
                        print("💀 Shutting down for self-destruct...")
                        sys.exit(0)
                    
                    elif action_type == "RESTART_AGENT":
                        try:
                            # Kirim laporan awal bahwa restart sedang berlangsung
                            requests.post(f"{DASHBOARD_API_URL}/agent/action-logs/complete",
                                        json={
                                            "actionLogId": action_id,
                                            "status": "success",
                                            "message": "Restart initiated, agent going offline shortly"
                                        },
                                        headers=headers,
                                        timeout=10)
                            
                            # Lakukan restart layanan agent
                            import subprocess
                            subprocess.run(["sudo", "systemctl", "restart", os.getenv("SERVICE_NAME", "openvpn-agent")])
                            
                            print("🔄 Agent restart command issued successfully")
                            
                        except Exception as restart_error:
                            # Dalam kasus error, laporkan ke dashboard
                            try:
                                requests.post(f"{DASHBOARD_API_URL}/agent/action-logs/complete",
                                            json={
                                                "actionLogId": action_id,
                                                "status": "failed",
                                                "message": f"Failed to restart agent: {str(restart_error)}"
                                            },
                                            headers=headers,
                                            timeout=10)
                            except:
                                pass  # Abaikan error saat mengirim laporan error
                            
                            print(f"Failed to restart agent: {restart_error}")

                    # Kirim laporan per-item (ini tetep di dalam loop biar dashboard cepet dapet update status per user)
                    if action_type != "DECOMMISSION_AGENT":
                        requests.post(f"{DASHBOARD_API_URL}/agent/action-logs/complete",
                            json={"actionLogId": action_id, **result}, headers=headers, timeout=10)

                    # Kalau sukses, tandain flag jadi True. JANGAN SYNC DISINI.
                    if action_performed:
                        needs_profile_sync = True

                except Exception as e:
                    print(f"⚠️ Error processing action {action.get('id')}: {e}")
                    requests.post(f"{DASHBOARD_API_URL}/agent/action-logs/complete",
                        json={"actionLogId": action.get('id'), "status": "failed", "message": str(e)},
                        headers=headers, timeout=10)

            # --- 🔥 OPTIMIZATION END: Batch Sync ---
            # Cek flag setelah keluar dari loop
            if needs_profile_sync:
                print(f"⚡ Batch actions completed. Triggering SINGLE profile sync.")
                time.sleep(1) # Kasih jeda dikit biar file system settle
                sync_profiles(headers, SECRET_KEY_BYTES)
            # ---------------------------------------

            # 1. Report Status
            status_payload = {
                "serverId": SERVER_ID,
                "serviceStatus": get_openvpn_service_status(),
                "activeUsers": get_openvpn_active_users(),
            }
            if CPU_RAM_MONITORING_INTERVAL is not None:
                status_payload["cpuUsage"] = get_cpu_usage()
                status_payload["ramUsage"] = get_ram_usage()
            requests.post(f"{DASHBOARD_API_URL}/agent/report-status", json=status_payload, headers=headers, timeout=10)

            # 2. Sync Full Profiles (Routine check)
            # Ini tetep jalan buat handle kasus manual change di server (bukan via dashboard)
            # Karena ada checksum check di dalem sync_profiles, ini aman & murah kalau gak ada perubahan.
            sync_profiles(headers, SECRET_KEY_BYTES)

            # Proses log
            process_log_file(
                log_key="activity_log",
                base_path=OVPN_ACTIVITY_LOG_PATH,
                parser_func=parse_activity_log_line,
                endpoint="/agent/report-activity-logs",
                headers=headers
            )
            process_log_file(
                log_key="openvpn_log",
                base_path=OPENVPN_LOG_PATH,
                parser_func=package_raw_log_line,
                endpoint="/agent/report-openvpn-logs",
                headers=headers
            )

        except requests.exceptions.RequestException as e:
            print(f"[NETWORK ERROR] Could not connect to dashboard: {e}")
        except Exception as e:
            print(f"[FATAL ERROR] in main loop: {e}")

        print(f"--- Cycle complete, sleeping for {METRICS_INTERVAL} seconds ---")
        time.sleep(METRICS_INTERVAL)

# --- Parser/Packager ---
def parse_activity_log_line(line: str) -> Optional[Dict]:
    parts = line.strip().split(',')
    if len(parts) < 2: return None
    try:
        ts = datetime.strptime(parts[0], '%Y-%m-%d %H:%M:%S').isoformat() + "Z"
        action, username = parts[1], (parts[2] if len(parts) > 2 else None)
        public_ip, vpn_ip, bytes_r, bytes_s = (parts[3] if len(parts) > 3 else None), None, None, None
        if action == "CONNECT" and len(parts) > 4: vpn_ip = parts[4]
        elif action == "DISCONNECT" and len(parts) > 5:
            bytes_r, bytes_s = int(parts[4]), int(parts[5])
        return {"timestamp": ts, "action": action, "username": username, "publicIp": public_ip, "vpnIp": vpn_ip, "bytesReceived": bytes_r, "bytesSent": bytes_s}
    except (ValueError, IndexError): return None

def package_raw_log_line(line: str) -> Optional[Dict]:
    stripped_line = line.strip()
    if stripped_line: return {"message": stripped_line}
    return None

if __name__ == "__main__":
    print("🚀 OpenVPN Agent (True RAM-Optimized) Started")
    main_loop()
_PYTHON_SCRIPT_EOF_
    chmod +x "$SCRIPT_DIR/$PYTHON_AGENT_SCRIPT_NAME"
    chown "$AGENT_USER":"$AGENT_USER" "$SCRIPT_DIR/$PYTHON_AGENT_SCRIPT_NAME"
    echo "✅ Python agent script deployed successfully."

    echo "⚙️  Writing client manager script..."
    # Hilangkan tanda kutip dari 'EOF' agar variabel bisa terbaca
    cat << CLIENT_MANAGER_EOF | tee "$SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME" > /dev/null
#!/bin/bash
# Skrip ini menggunakan path installer yang ditemukan secara dinamis.
OPENVPN_INSTALL_SCRIPT="$OPENVPN_INSTALL_SCRIPT_PATH"

create_client() {
    local username=\$1
    if [ -z "\$username" ]; then
        echo "⛔ Please provide a username. Usage: \$0 create <username>"
        exit 1
    fi
    # Membuat user secara non-interaktif
    printf "1\\n%s\\n1\\n" "\$username" | sudo "\$OPENVPN_INSTALL_SCRIPT"
    sleep 1
}

revoke_client() {
    local username="\$1"
    if [ -z "\$username" ]; then exit 1; fi

    # Membaca path index.txt secara dinamis dari file .env
    local index_path="\$(grep -oP 'EASY_RSA_INDEX_PATH=\\K.*' "$SCRIPT_DIR/.env" | tr -d '\"')"
    if [ ! -f "\$index_path" ]; then
        echo "⛔ Easy RSA index file not found at '\$index_path'."
        exit 1
    fi
    # Mencari nomor klien (case-insensitive)
    local num=\$(sudo tail -n +2 "\$index_path" | grep "^V" | cut -d '=' -f2 | nl -w1 -s' ' | awk -v name="\$username" 'BEGIN{IGNORECASE=1} \$2 == name {print \$1; exit}')
    
    if [ -z "\$num" ]; then 
        echo "⛔ Client '\$username' not found or already revoked."
        exit 1
    fi

    # Mencabut user secara non-interaktif
    printf "2\\n%s\\ny\\n" "\$num" | sudo "\$OPENVPN_INSTALL_SCRIPT"
    sleep 1
}

case "\$1" in
    create) create_client "\$2" ;;
    revoke) revoke_client "\$2" ;;
    *) echo "Usage: \$0 {create|revoke} <username>"; exit 1 ;;
esac
CLIENT_MANAGER_EOF
    chmod +x "$SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME"
    chown "$AGENT_USER":"$AGENT_USER" "$SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME"
    echo "✅ Client manager script deployed."

    echo "🗑️  Writing self-destruct script..."
    cat << 'SELF_DESTRUCT_EOF' | tee "$SCRIPT_DIR/self-destruct.sh" > /dev/null
#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then exit 1; fi
SERVICE_NAME="$1"
AGENT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
pkill -f "$AGENT_DIR/main.py" 2>/dev/null || true
sleep 2
rm -f "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
rm -rf "$AGENT_DIR"
echo "✅ Self-destruct complete."
SELF_DESTRUCT_EOF
    chmod +x "$SCRIPT_DIR/self-destruct.sh"
    chown "$AGENT_USER":"$AGENT_USER" "$SCRIPT_DIR/self-destruct.sh"
    echo "✅ Self-destruct script deployed."
}

# --- Systemd and Final Setup ---
# --- GANTI SEMUA FUNGSI LOGROTATE LAMA DENGAN TIGA FUNGSI BARU INI ---

setup_openvpn_logrotate() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🔄 CONFIGURING LOG ROTATION FOR OPENVPN LOG"
    echo "═══════════════════════════════════════════════"
    echo ""

    local log_file="/var/log/openvpn/openvpn.log"
    local rotate_conf_dir="/etc/logrotate.d"
    local new_conf_file="$rotate_conf_dir/openvpn-main-log"

    # Periksa apakah sudah ada file konfigurasi yang mengatur log ini
    if grep -rq "$log_file" "$rotate_conf_dir"; then
        echo "✅ Log rotation for $log_file seems to be already configured. Skipping."
        return
    fi

    # Tanya pengguna
    read -p "Do you want to set up log rotation for $log_file? [Y/n]: " choice
    choice=${choice:-Y} # Default ke Y jika pengguna hanya menekan Enter

    if [[ "$choice" =~ ^[yY]$ ]]; then
        echo "📝 Creating logrotate configuration at $new_conf_file..."
        
        cat << 'EOF' | tee "$new_conf_file" > /dev/null
/var/log/openvpn/openvpn.log {
    # Rotasi setiap bulan
    monthly
    # Simpan 6 file log lama
    rotate 6
    # Lanjutkan meski file log tidak ditemukan
    missingok
    # Jangan rotasi jika file kosong
    notifempty
    # Kompres file log yang sudah dirotasi
    compress
    delaycompress
    # Jalankan skrip post-rotasi hanya sekali
    sharedscripts
    # Beritahu OpenVPN untuk menggunakan file log baru setelah rotasi
    postrotate
        systemctl reload openvpn-server@server >/dev/null 2>&1 || true
    endscript
}
EOF
        echo "✅ Logrotate configuration created successfully."
    else
        echo "⏩ Skipping logrotate setup for openvpn.log."
    fi
}

setup_user_activity_logrotate() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🔄 CONFIGURING LOG ROTATION FOR ACTIVITY LOG"
    echo "═══════════════════════════════════════════════"
    echo ""

    local log_file="/var/log/openvpn/user_activity.log"
    local rotate_conf_dir="/etc/logrotate.d"
    local new_conf_file="$rotate_conf_dir/openvpn-activity-log"

    if grep -rq "$log_file" "$rotate_conf_dir"; then
        echo "✅ Log rotation for $log_file seems to be already configured. Skipping."
        return
    fi

    read -p "Do you want to set up log rotation for $log_file? [Y/n]: " choice
    choice=${choice:-Y}

    if [[ "$choice" =~ ^[yY]$ ]]; then
        echo "📝 Creating logrotate configuration at $new_conf_file..."

        cat << 'EOF' | tee "$new_conf_file" > /dev/null
/var/log/openvpn/user_activity.log {
    monthly
    rotate 6
    missingok
    notifempty
    compress
    delaycompress
    # Buat ulang file log dengan izin yang benar setelah rotasi
    create 0640 nobody nogroup
}
EOF
        echo "✅ Logrotate configuration created successfully."
    else
        echo "⏩ Skipping logrotate setup for user_activity.log."
    fi
}

setup_agent_logrotate() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🔄 CONFIGURING LOG ROTATION FOR AGENT LOGS"
    echo "═══════════════════════════════════════════════"
    echo ""

    local agent_log_path="$SCRIPT_DIR/logs"
    local rotate_conf_dir="/etc/logrotate.d"
    local new_conf_file="$rotate_conf_dir/openvpn-agent-logs"

    if grep -rq "$agent_log_path" "$rotate_conf_dir"; then
        echo "✅ Log rotation for agent logs seems to be already configured. Skipping."
        return
    fi
    
    read -p "Do you want to set up log rotation for agent logs in $agent_log_path? [Y/n]: " choice
    choice=${choice:-Y}

    if [[ "$choice" =~ ^[yY]$ ]]; then
        echo "📝 Creating logrotate configuration at $new_conf_file..."
        
        # Fixed the EOF delimiter - removed quotes to allow variable expansion
        cat << EOF | tee "$new_conf_file" > /dev/null
$SCRIPT_DIR/logs/*.log {
    # Rotasi setiap bulan
    monthly
    # Simpan 2 file log lama (2 bulan)
    rotate 2
    # Rotasi juga jika file lebih besar dari 10MB
    size 10M
    # Lanjutkan meski file log tidak ditemukan
    missingok
    # Jangan rotasi jika file kosong
    notifempty
    # Kompres file log yang sudah dirotasi
    compress
    delaycompress
}
EOF
        echo "✅ Agent logrotate configuration created successfully."
    else
        echo "⏩ Skipping logrotate setup for agent logs."
    fi
}

create_systemd_service_file() {
    cat > "/etc/systemd/system/$APP_NAME.service" << EOF
[Unit]
Description=OpenVPN Polling Agent for $SERVER_ID (RAM-Optimized)
After=network.target

[Service]
Type=simple
User=$AGENT_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$VENV_PATH/bin/python3 $SCRIPT_DIR/$PYTHON_AGENT_SCRIPT_NAME
Restart=always
RestartSec=10
EnvironmentFile=-$SCRIPT_DIR/.env
StandardOutput=append:$SCRIPT_DIR/logs/agent.log
StandardError=append:$SCRIPT_DIR/logs/agent.log
KillMode=mixed
TimeoutStopSec=10

MemoryMax=$RAM_LIMIT

[Install]
WantedBy=multi-user.target
EOF
}

configure_systemd() {
    systemctl daemon-reload
    systemctl stop "$APP_NAME" 2>/dev/null || true
    systemctl start "$APP_NAME"
    systemctl enable "$APP_NAME"
    echo "✅ Agent started as systemd service (no port opened)."
}

main() {
    check_sudo
    get_user_input
    cleanup_old_pm2_installation
    check_and_install_openvpn
    mkdir -p "$SCRIPT_DIR"
    chown -R "$AGENT_USER":"$AGENT_USER" "$SCRIPT_DIR"
    if ! find_easy_rsa_path; then exit 1; fi
    install_dependencies
    create_env_file
    deploy_scripts
    create_systemd_service_file
    setup_openvpn_logrotate
    setup_user_activity_logrotate
    setup_agent_logrotate
    configure_systemd
    read -p "Do you want to rotate logs and restart openvpn@server now? (y/N): " rotate_choice
    rotate_choice=${rotate_choice:-n}
    if [[ "${rotate_choice,,}" == "y" ]]; then
        echo "🔄 Rotating logs and restarting openvpn@server..."
        logrotate -d /etc/logrotate.conf
        logrotate -f /etc/logrotate.conf
        systemctl restart openvpn@server
        echo "✅ Logs rotated and openvpn@server restarted."
    elif [[ "${rotate_choice,,}" != "n" && -n "$rotate_choice" ]]; then
        echo "⚠️  Invalid input, skipping log rotation and openvpn@server restart."
    else
        echo "ℹ️  Skipping log rotation and openvpn@server restart."
    fi

    echo ""
    echo "🎉 DEPLOYMENT COMPLETE (ULTIMATE MODE: FEATURE-COMPLETE & RAM-OPTIMIZED)"
    echo "✅ Agent is running efficiently, streaming all rotated logs to save RAM."
    echo "✅ All features including agent decommission are enabled."
    echo "🔧 Manage with: sudo systemctl {status|stop|restart} $APP_NAME"
}

main "$@"
