#!/bin/bash
#
# deploymentovpn.sh (Simplified Version - Systemd & No SNMP)
#
# This script automates the deployment of the OpenVPN Agent on a new server.
# It will clean up old PM2-based installations, install dependencies,
# create a Python virtual environment (venv), deploy the agent and
# client manager scripts, and configure them to run as a systemd service.
#
# Usage: sudo ./deploymentovpn.sh
#
# Exit immediately if a command exits with a non-zero status.
set -e

# --- Default Configuration ---
PYTHON_AGENT_SCRIPT_NAME="main.py"
CLIENT_MANAGER_SCRIPT_NAME="openvpn-client-manager.sh"
OPENVPN_INSTALL_SCRIPT_PATH="/root/ubuntu-22.04-lts-vpn-server.sh"

# Get the username of the user running sudo
SUDO_USER=${SUDO_USER:-$(whoami)}

# --- WORKAROUND: Determine directory based on the current script's location ---
# Get the absolute path of the directory where this script resides
BASE_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Define the main working directory within that location
SCRIPT_DIR="$BASE_DIR/openvpn-agent"
VENV_PATH="$SCRIPT_DIR/venv" ## VENV CHANGE: Define the venv path
EASY_RSA_INDEX_PATH=""
EASY_RSA_SERVER_NAME_PATH=""

# Variables to be filled by user input
AGENT_API_KEY=""
APP_NAME="" # This will now be the systemd service name
DASHBOARD_API_URL=""
SERVER_ID=""
OVPN_DIR=""

# --- Functions ---
# Check if the script is run with root privileges (sudo)
check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        echo "⛔ Please run this script with sudo: sudo $0"
        exit 1
    fi
    echo "✅ Script is running with root privileges."
}

# Function to prompt for user input
get_user_input() {
    echo ""
    while [ -z "$APP_NAME" ]; do
        read -p "🏷️ Enter the Service Name for systemd (e.g., vpn-agent): " APP_NAME
        [ -z "$APP_NAME" ] && echo "⛔ Service name cannot be empty."
    done

    echo ""
    while [ -z "$AGENT_API_KEY" ]; do
        read -p "🔑 Enter the AGENT_API_KEY (must match the dashboard): " AGENT_API_KEY
        [ -z "$AGENT_API_KEY" ] && echo "⛔ API Key cannot be empty."
    done

    echo ""
    while [ -z "$SERVER_ID" ]; do
        read -p "🏷️ Enter the Server ID (e.g., SERVER-01): " SERVER_ID
        [ -z "$SERVER_ID" ] && echo "⛔ Server ID cannot be empty."
    done

    echo ""
    echo "Select the Dashboard API protocol:"
    echo "1) HTTPS (Recommended)"
    echo "2) HTTP"
    read -p "Your choice [Default 1]: " PROTOCOL_CHOICE
    PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-1}
    case "$PROTOCOL_CHOICE" in
        1)
            DEFAULT_PROTOCOL="https://"
            ;;
        2)
            DEFAULT_PROTOCOL="http://"
            ;;
        *)
            DEFAULT_PROTOCOL="https://"
            ;;
    esac

    echo ""
    read -p "🌐 Enter the Dashboard API address (e.g., vpn.clouddonut.net or 192.168.1.42 or https://your-domain.com): " DASHBOARD_HOST_RAW
    DASHBOARD_HOST_RAW=${DASHBOARD_HOST_RAW:-vpn.clouddonut.net}

    # Cek apakah input sudah mengandung protokol (http:// atau https://)
    if [[ "$DASHBOARD_HOST_RAW" =~ ^(http|https):// ]]; then
        # Jika ya, gunakan protokol dari input, abaikan pilihan sebelumnya
        PROTOCOL=$(echo "$DASHBOARD_HOST_RAW" | grep -oE '^(http|https)://')
        # Hapus protokol untuk validasi lebih lanjut
        DASHBOARD_HOST_CLEAN=${DASHBOARD_HOST_RAW#*//}
    else
        # Jika tidak, gunakan protokol default dari pilihan
        PROTOCOL="$DEFAULT_PROTOCOL"
        DASHBOARD_HOST_CLEAN=$DASHBOARD_HOST_RAW
    fi

    # Validasi apakah yang tersisa adalah IP atau Domain
    if [[ "$DASHBOARD_HOST_CLEAN" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        # Ini adalah IP Address
        BASE_URL="${PROTOCOL}${DASHBOARD_HOST_CLEAN}"
        # Ping untuk memastikan reachable (opsional, bisa di-skip jika tidak perlu)
        if ping -c 1 -W 1 "$DASHBOARD_HOST_CLEAN" &>/dev/null; then
            echo "✅ Dashboard API IP ($DASHBOARD_HOST_CLEAN) is reachable."
        else
            echo "⚠️ Dashboard API IP ($DASHBOARD_HOST_CLEAN) might not be reachable, but proceeding..."
        fi
    elif [[ "$DASHBOARD_HOST_CLEAN" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
        # Ini adalah Domain Name
        BASE_URL="${PROTOCOL}${DASHBOARD_HOST_CLEAN}"
        echo "✅ Domain ($DASHBOARD_HOST_CLEAN) accepted."
    else
        echo "⛔ Invalid format. Please enter a valid IP address or domain name."
        exit 1
    fi

    # optional port
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

    # build URL
    local TEMP_URL="${BASE_URL}${FINAL_PORT_PART}"
    [[ "$TEMP_URL" != */api ]] && DASHBOARD_API_URL="${TEMP_URL}/api" || DASHBOARD_API_URL="${TEMP_URL}"
    echo "✅ Dashboard API URL set to: $DASHBOARD_API_URL"

    echo ""
    read -p "📁 Enter the directory for OVPN files (Default: /root): " OVPN_DIR_INPUT
    OVPN_DIR=${OVPN_DIR_INPUT:-/root}
    echo "✅ OVPN directory: $OVPN_DIR"

    echo ""
    read -p "⏱️ Enter main loop interval in seconds (Default: 60): " METRICS_INTERVAL
    METRICS_INTERVAL=${METRICS_INTERVAL:-60}
    echo "✅ Main loop interval: $METRICS_INTERVAL sec."

    echo ""
    read -p "⏱️ Enter CPU/RAM monitoring interval (Default: 60, 'N' to disable): " CPU_RAM_INTERVAL_INPUT
    CPU_RAM_INTERVAL_INPUT=${CPU_RAM_INTERVAL_INPUT:-60}
    if [[ "${CPU_RAM_INTERVAL_INPUT^^}" == "N" ]]; then
        CPU_RAM_INTERVAL="disabled"
        echo "✅ CPU/RAM monitoring disabled."
    elif [[ "$CPU_RAM_INTERVAL_INPUT" =~ ^[0-9]+$ ]] && [ "$CPU_RAM_INTERVAL_INPUT" -gt 0 ]; then
        CPU_RAM_INTERVAL="$CPU_RAM_INTERVAL_INPUT"
        echo "✅ CPU/RAM monitoring: $CPU_RAM_INTERVAL sec."
    else
        echo "⚠️ Invalid input, using default 60s."
        CPU_RAM_INTERVAL=60
    fi
}

# --- NEW: Function to Clean Up Old PM2-based Installations ---
cleanup_old_pm2_installation() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🧹 CLEANING UP OLD PM2-BASED AGENT INSTALLATION"
    echo "═══════════════════════════════════════════════"
    echo ""

    # Check for PM2 and remove it
    if command -v pm2 &> /dev/null; then
        echo "[-] Found old PM2 installation. Stopping and removing processes..."
        pm2 stop all >/dev/null 2>&1 || true
        pm2 delete all >/dev/null 2>&1 || true
        pm2 kill >/dev/null 2>&1 || true
        
        echo "[-] Uninstalling PM2 globally..."
        # Source nvm if it exists to find npm
        export NVM_DIR="/root/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        
        if command -v npm &> /dev/null; then
            npm uninstall -g pm2 >/dev/null 2>&1 || true
            echo "✅ PM2 uninstalled."
        else
            echo "⚠️  npm not found, cannot uninstall PM2 automatically. Skipping."
        fi
        
        echo "[-] Removing PM2 startup scripts..."
        pm2 unstartup >/dev/null 2>&1 || true

        echo "[-] Removing PM2 home directory..."
        rm -rf "/root/.pm2"
    else
        echo "✅ No PM2 installation found. Skipping PM2 cleanup."
    fi

    # Check for NVM and remove it
    if [ -d "/root/.nvm" ]; then
        echo "[-] Found old NVM installation. Removing..."
        # Unload nvm
        command -v nvm &> /dev/null && nvm unload || true
        # Remove NVM directory
        rm -rf "/root/.nvm"
        # Clean up shell configuration files for root
        sed -i '/NVM_DIR/d' "/root/.bashrc" "/root/.profile" >/dev/null 2>&1 || true
        sed -i '/nvm.sh/d' "/root/.bashrc" "/root/.profile" >/dev/null 2>&1 || true
        echo "✅ NVM and Node.js removed."
    else
        echo "✅ No NVM installation found. Skipping NVM cleanup."
    fi

    # Remove symlinks that might be left over
    echo "[-] Removing old symlinks..."
    rm -f /usr/local/bin/node
    rm -f /usr/local/bin/pm2
    echo "✅ Symlinks removed."

    # Remove snmpd if installed
    if dpkg -l | grep -q "snmpd"; then
        echo "[-] Found old snmpd package. Removing..."
        apt-get purge --auto-remove -y snmpd >/dev/null 2>&1
        echo "✅ snmpd package removed."
    else
        echo "✅ No snmpd package found. Skipping."
    fi

    echo ""
    echo "✅ OLD INSTALLATION CLEANUP COMPLETE"
}


# Find the Easy-RSA index.txt path dynamically
find_easy_rsa_path() {
    echo "🔍 Dynamically searching for Easy-RSA index.txt path..."
    local paths_to_check=(
        "/etc/openvpn/easy-rsa/pki/index.txt"
        "/etc/openvpn/pki/index.txt"
        "/usr/share/easy-rsa/pki/index.txt"
        "/etc/easy-rsa/pki/index.txt"
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
    echo "⛔ Easy-RSA index.txt path not found in common locations. Deployment failed."
    echo "   Locations checked:"
    for path in "${paths_to_check[@]}"; do
        echo "   • $path"
    done
    return 1
}

# Check if the OpenVPN service is running
check_openvpn_service() {
    echo "🔎 Searching for a running OpenVPN service..."
    local service_names=("openvpn-server@server" "openvpn@server" "openvpn")
    for service in "${service_names[@]}"; do
        if systemctl is-active --quiet "$service"; then
            echo "✅ OpenVPN service ($service) found and running."
            return 0
        fi
    done
    if pgrep openvpn > /dev/null; then
        echo "✅ OpenVPN process found, but the service is not officially registered."
        return 0
    fi
    echo "⛔ OpenVPN service or process not found. Deployment canceled."
    echo "   Ensure OpenVPN is installed and running, or place the installation script at:"
    echo "   $OPENVPN_INSTALL_SCRIPT_PATH"
    return 1
}

# Install system dependencies and Python
install_dependencies() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "⚙️  INSTALLING SYSTEM DEPENDENCIES (FOR ROOT)"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "📦 Updating package lists..."
    apt-get update -qq
    echo "📦 Installing system dependencies..."
    # Removed: nodejs, npm, pm2 related packages. Kept 'at' for potential future use, 'expect' for client manager.
    apt-get install -y openvpn python3 python3-pip python3-venv expect curl dos2unix at
    dos2unix "$0" >/dev/null 2>&1
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🐍 CONFIGURING PYTHON VIRTUAL ENVIRONMENT"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "🏗️ Creating Python virtual environment at $VENV_PATH..."
    python3 -m venv "$VENV_PATH"
    echo "✅ Virtual environment created successfully."
    echo "📦 Installing Python dependencies..."
    "$VENV_PATH/bin/pip" install --upgrade pip --quiet
    echo "   Installing: fastapi, uvicorn, pydantic, python-dotenv, requests, psutil, aiohttp..."
    if "$VENV_PATH/bin/pip" install fastapi "uvicorn[standard]" pydantic python-dotenv psutil requests aiohttp --quiet; then
        echo "✅ All Python dependencies installed successfully."
    else
        echo "⛔ Failed to install Python dependencies."
        exit 1
    fi
    echo ""
    echo "✅ DEPENDENCY INSTALLATION COMPLETE"
}

# Create the .env file from user input
create_env_file() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "📄 CREATING CONFIGURATION FILE"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "📝 Creating .env file with configuration..."
    # Use tee to create the .env file with sudo permissions
    cat << EOF | tee "$SCRIPT_DIR/.env" > /dev/null
# OpenVPN Agent Configuration
# Generated by deploymentovpn.sh on $(date)
# API Configuration
AGENT_API_KEY="$AGENT_API_KEY"
SERVER_ID="$SERVER_ID"
DASHBOARD_API_URL="$DASHBOARD_API_URL"
# Script Paths
SCRIPT_PATH="$SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME"
OVPN_DIR="$OVPN_DIR"
# Easy-RSA Configuration
EASY_RSA_INDEX_PATH="$EASY_RSA_INDEX_PATH"
EASY_RSA_SERVER_NAME_PATH="$EASY_RSA_SERVER_NAME_PATH"
# Logging
OVPN_ACTIVITY_LOG_PATH="/var/log/openvpn/user_activity.log"
# Service Configuration (for systemd)
SERVICE_NAME="$APP_NAME"
# Monitoring Configuration
METRICS_INTERVAL_SECONDS="$METRICS_INTERVAL"
CPU_RAM_MONITORING_INTERVAL="$CPU_RAM_INTERVAL"
EOF
    # Set ownership to SUDO_USER
    chown "$SUDO_USER":"$SUDO_USER" "$SCRIPT_DIR/.env"
    chmod 600 "$SCRIPT_DIR/.env"
    echo "✅ .env file created successfully with complete configuration."
    echo "   Location: $SCRIPT_DIR/.env"
}

# Deploy the Python and Bash scripts
deploy_scripts() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "📂 DEPLOYING APPLICATION SCRIPTS"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "📁 Ensuring directory structure..."
    # Directory was already created, just ensure the logs folder exists
    mkdir -p "$SCRIPT_DIR/logs"
    chown -R "$SUDO_USER":"$SUDO_USER" "$SCRIPT_DIR"
    # Save the Python agent script (using the best version from original)
    echo "🐍 Writing Python agent script to $SCRIPT_DIR/$PYTHON_AGENT_SCRIPT_NAME..."
    # Use sudo tee to write the file as SUDO_USER
    cat << '_PYTHON_SCRIPT_EOF_' | sudo -u "$SUDO_USER" tee "$SCRIPT_DIR/$PYTHON_AGENT_SCRIPT_NAME" > /dev/null
# main.py (OpenVPN Agent - Final Version)
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from subprocess import run, PIPE, CalledProcessError
from pydantic import BaseModel, Field
from dotenv import load_dotenv
import subprocess
import os
import re
import requests
import asyncio
from datetime import datetime, timezone
import hashlib
import sys
from typing import List, Optional
import shlex
import psutil
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
load_dotenv(dotenv_path=os.path.join(SCRIPT_DIR, '.env'))
app = FastAPI()
# Env config
AGENT_API_KEY = os.getenv("AGENT_API_KEY")
SERVER_ID = os.getenv("SERVER_ID")
DASHBOARD_API_URL = os.getenv("DASHBOARD_API_URL")
SCRIPT_PATH = os.getenv("SCRIPT_PATH", "./openvpn-client-manager.sh")
OVPN_DIR = os.getenv("OVPN_DIR", "/home/ovpn")
EASY_RSA_INDEX_PATH = os.getenv("EASY_RSA_INDEX_PATH", "/etc/openvpn/easy-rsa/pki/index.txt")
EASY_RSA_SERVER_NAME_PATH = os.getenv("EASY_RSA_SERVER_NAME_PATH", "/etc/openvpn/easy-rsa/SERVER_NAME_GENERATED")
OVPN_ACTIVITY_LOG_PATH = os.getenv("OVPN_ACTIVITY_LOG_PATH", "/var/log/openvpn/user_activity.log")
SERVICE_NAME = os.getenv("SERVICE_NAME") # For self-destruct
METRICS_INTERVAL = int(os.getenv("METRICS_INTERVAL_SECONDS", "60"))

# Monitoring config
CPU_RAM_MONITORING_INTERVAL_STR = os.getenv("CPU_RAM_MONITORING_INTERVAL", "60")
if CPU_RAM_MONITORING_INTERVAL_STR.lower() == "disabled":
    CPU_RAM_MONITORING_INTERVAL = None
    print("ℹ️  CPU/RAM monitoring is DISABLED.")
else:
    try:
        CPU_RAM_MONITORING_INTERVAL = int(CPU_RAM_MONITORING_INTERVAL_STR)
        if CPU_RAM_MONITORING_INTERVAL <= 0:
            raise ValueError("Interval must be positive")
    except (ValueError, TypeError):
        print(f"⚠️  Invalid CPU_RAM_MONITORING_INTERVAL '{CPU_RAM_MONITORING_INTERVAL_STR}'. Defaulting to 60s.")
        CPU_RAM_MONITORING_INTERVAL = 60

if not AGENT_API_KEY:
    raise RuntimeError("Missing AGENT_API_KEY in .env")
if not SERVER_ID:
    raise RuntimeError("Missing SERVER_ID in .env")
if not DASHBOARD_API_URL:
    raise RuntimeError("Missing DASHBOARD_API_URL in .env")

# Global variables to store the last sent checksums
last_vpn_profiles_checksum = None
last_activity_log_checksum = None

# --- Middleware for auth ---
@app.middleware("http")
async def verify_api_key(request: Request, call_next):
    if request.url.path not in ["/health", "/stats"]:
        auth = request.headers.get("Authorization")
        if not auth or not auth.startswith("Bearer ") or auth.split(" ")[1] != AGENT_API_KEY:
            return JSONResponse(status_code=401, content={"detail": "Unauthorized"})
    return await call_next(request)

# --- FUNGSI BARU UNTUK METRIK ---
# Initialize this once at startup
_last_cpu_times = None

def get_cpu_usage() -> float:
    global _last_cpu_times
    try:
        # Get instantaneous CPU usage without blocking
        cpu_percent = psutil.cpu_percent(interval=None) # Non-blocking
        
        # If it's the first call, store initial values and return 0.0
        if _last_cpu_times is None:
            _last_cpu_times = psutil.cpu_times()
            return 0.0
            
        # Calculate based on time elapsed since last call
        current_times = psutil.cpu_times()
        total_time_diff = sum(getattr(current_times, attr) - getattr(_last_cpu_times, attr) 
                            for attr in ['user', 'system', 'idle', 'iowait'])
        busy_time_diff = sum(getattr(current_times, attr) - getattr(_last_cpu_times, attr) 
                           for attr in ['user', 'system', 'iowait'])
        
        _last_cpu_times = current_times
        
        if total_time_diff > 0:
            return (busy_time_diff / total_time_diff) * 100
        else:
            return 0.0
            
    except Exception as e:
        print(f"Error getting CPU usage: {e}")
        return 0.0

def get_ram_usage() -> float:
    """Returns the system-wide RAM utilization as a percentage."""
    try:
        return psutil.virtual_memory().percent
    except Exception as e:
        print(f"Error getting RAM usage: {e}")
        return 0.0

# --- Utility Functions ---
def sanitize_username(username: str) -> str:
    stripped_username = username.strip()
    sanitized = re.sub(r'[^a-zA-Z0-9_\-]', '', stripped_username).lower()
    if not re.match(r"^[a-zA-Z0-9_\-]{3,30}$", sanitized):
        raise ValueError("Invalid username format")
    return sanitized

def get_openvpn_service_status() -> str:
    # BUG FIX: Check service status with sudo
    try:
        result = run(["sudo", "systemctl", "is-active", "openvpn@server"], stdout=PIPE, stderr=PIPE, text=True)
        if result.stdout.strip() == "active":
            return "running"
        elif result.stdout.strip() == "inactive":
            return "stopped"
        else:
            return "error"
    except Exception as e:
        print(f"Error checking OpenVPN service status: {e}")
        return "error"

def get_server_cn() -> str:
    # BUG FIX: Run as root, so no sudo needed
    try:
        if os.path.exists(EASY_RSA_SERVER_NAME_PATH):
            with open(EASY_RSA_SERVER_NAME_PATH, 'r') as f:
                return f.read().strip()
    except Exception as e:
        print(f"Error reading server CN file: {e}")
    return "server_irL5Kfmg3FnRZaGE"

def parse_index_txt() -> tuple[list[dict], str]:
    profiles = []
    # BUG FIX: Run as root, so no sudo needed
    try:
        with open(EASY_RSA_INDEX_PATH, 'r') as f:
            raw_content = f.read()
            checksum = hashlib.md5(raw_content.encode('utf-8')).hexdigest()
            server_cn = get_server_cn()
            for line in raw_content.strip().split('\n'):
                parts = line.strip().split('\t')
                if len(parts) >= 6:
                    cert_status = parts[0]
                    expiration_date_str = parts[1]
                    expiration_date = None
                    if expiration_date_str and expiration_date_str != 'Z':
                        try:
                            match = re.match(r'(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z', expiration_date_str)
                            if match:
                                year, month, day, hour, minute, second = match.groups()
                                full_year = int(year) + 2000 if int(year) < 70 else int(year) + 1900
                                iso_format_str = f"{full_year}-{month}-{day}T{hour}:{minute}:{second}Z"
                                expiration_date = datetime.strptime(iso_format_str, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                        except ValueError:
                            expiration_date = None
                    revocation_date = None
                    if cert_status == 'R' and len(parts) >= 3 and parts[2] and parts[2] != 'Z':
                        revocation_date_str = parts[2]
                        try:
                            match = re.match(r'(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z', revocation_date_str)
                            if match:
                                year, month, day, hour, minute, second = match.groups()
                                full_year = int(year) + 2000 if int(year) < 70 else int(year) + 1900
                                iso_format_str = f"{full_year}-{month}-{day}T{hour}:{minute}:{second}Z"
                                revocation_date = datetime.strptime(iso_format_str, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                        except ValueError:
                            revocation_date = None
                    serial_number = parts[3]
                    cn_match = re.search(r'/CN=([^/]+)', line)
                    username_raw = cn_match.group(1) if cn_match else "unknown"
                    username = "".join(filter(str.isprintable, username_raw)).lower().strip()
                    if username_raw == server_cn:
                        continue
                    vpn_cert_status = "UNKNOWN"
                    if cert_status == 'V': vpn_cert_status = "VALID"
                    elif cert_status == 'R': vpn_cert_status = "REVOKED"
                    elif cert_status == 'E': vpn_cert_status = "EXPIRED"
                    ovpn_file_content = None
                    if vpn_cert_status == "VALID":
                        ovpn_file_path = os.path.join(OVPN_DIR, f"{username}.ovpn")
                        try:
                            # BUG FIX: Run as root, so no sudo needed
                            if os.path.exists(ovpn_file_path):
                                with open(ovpn_file_path, 'r') as ovpn_f:
                                    ovpn_file_content = ovpn_f.read()
                        except Exception as e:
                            print(f"Warning: Could not read OVPN file for {username}. Error: {e}")
                    profiles.append({
                        "username": username,
                        "status": vpn_cert_status,
                        "expirationDate": expiration_date.isoformat() if expiration_date else None,
                        "revocationDate": revocation_date.isoformat() if revocation_date else None,
                        "serialNumber": serial_number,
                        "ovpnFileContent": ovpn_file_content,
                    })
            return profiles, checksum
    except Exception as e:
        print(f"Error parsing index.txt or calculating checksum: {e}")
        return [], ""

def get_openvpn_active_users_from_status_log() -> list[str]:
    active_users = []
    status_log_path = "/var/log/openvpn/status.log"
    # BUG FIX: Run as root, so no sudo needed
    if not os.path.exists(status_log_path):
        return []
    try:
        with open(status_log_path, 'r') as f:
            content = f.read()
            start_parsing = False
            for line in content.strip().split('\n'):
                if line.startswith("Common Name,Real Address"):
                    start_parsing = True
                    continue
                if line.startswith("ROUTING TABLE") or line.startswith("GLOBAL STATS"):
                    break
                if start_parsing and line:
                    parts = line.split(',')
                    if len(parts) >= 1:
                        username = parts[0].lower()
                        if username:
                            active_users.append(username)
        return active_users
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return []

def parse_activity_logs() -> tuple[list[dict], str]:
    logs = []
    raw_content = ""
    log_files_to_check = [OVPN_ACTIVITY_LOG_PATH, f"{OVPN_ACTIVITY_LOG_PATH}.1"]
    for log_file in log_files_to_check:
        if os.path.exists(log_file):
            try:
                with open(log_file, 'r') as f:
                    raw_content += f.read()
            except Exception as e:
                print(f"Warning: Could not read activity log {log_file}: {e}")
    if not raw_content:
        return [], ""
    checksum = hashlib.md5(raw_content.encode('utf-8')).hexdigest()
    for line in raw_content.strip().split('\n'):
        parts = line.strip().split(',')
        if len(parts) < 2:
            continue
        try:
            timestamp = datetime.strptime(parts[0], '%Y-%m-%d %H:%M:%S').isoformat() + "Z"
            action = parts[1]
            username = parts[2] if len(parts) > 2 else None
            public_ip = parts[3] if len(parts) > 3 else None
            # --- PERBAIKAN LOGIKA DI SINI ---
            vpn_ip = None
            bytes_received = None
            bytes_sent = None
            if action == "CONNECT" and len(parts) > 4:
                vpn_ip = parts[4]
            elif action == "DISCONNECT" and len(parts) > 5:
                # Kolom VPN IP tidak ada, jadi kita langsung ke bytes
                bytes_received = int(parts[4])
                bytes_sent = int(parts[5])
            # --- AKHIR PERBAIKAN ---
            log_entry = {
                "timestamp": timestamp,
                "action": action,
                "username": username,
                "publicIp": public_ip,
                "vpnIp": vpn_ip,
                "bytesReceived": bytes_received,
                "bytesSent": bytes_sent,
            }
            logs.append(log_entry)
        except (ValueError, IndexError) as e:
            print(f"Warning: Skipping malformed log line: '{line}'. Error: {e}")
            continue
    return logs, checksum

# --- Models ---
class CreateUserRequest(BaseModel):
    username: str

class EnhancedServerStatusReport(BaseModel):
    serverId: str
    serviceStatus: str
    activeUsers: list[str]

class VpnUserProfileData(BaseModel):
    username: str
    status: str
    expirationDate: Optional[str] = None
    revocationDate: Optional[str] = None
    serialNumber: Optional[str] = None
    ovpnFileContent: Optional[str] = None

class UserActivityLogEntry(BaseModel):
    timestamp: str
    action: str
    username: Optional[str] = None
    publicIp: Optional[str] = None
    vpnIp: Optional[str] = None
    bytesReceived: Optional[int] = None
    bytesSent: Optional[int] = None

class ActionLogEntry(BaseModel):
    id: str
    action: str
    vpnUserId: Optional[str] = None
    details: Optional[str] = None

# --- Background Task ---
async def background_task_loop():
    global last_vpn_profiles_checksum
    global last_activity_log_checksum
    while True:
        try:
            headers = {"Authorization": f"Bearer {AGENT_API_KEY}"}
            # 1. Report Node Metrics (service status, and optionally CPU/RAM)
            service_status = get_openvpn_service_status()
            active_users = get_openvpn_active_users_from_status_log()

            # Always send service status and active users
            node_metrics_payload = {
                "serverId": SERVER_ID,
                "serviceStatus": service_status,
                "activeUsers": active_users,
            }

            # Conditionally add CPU and RAM
            if CPU_RAM_MONITORING_INTERVAL is not None:
                cpu_usage = round(await asyncio.to_thread(get_cpu_usage), 2)
                ram_usage = round(await asyncio.to_thread(get_ram_usage), 2)
                node_metrics_payload["cpuUsage"] = cpu_usage
                node_metrics_payload["ramUsage"] = ram_usage
                #print(f"Sent status report for server {SERVER_ID} (CPU: {cpu_usage}%, RAM: {ram_usage}%)")
            else:
                #print(f"Sent basic status report for server {SERVER_ID} (CPU/RAM disabled)")
                pass
            await asyncio.to_thread(
                requests.post, f"{DASHBOARD_API_URL}/agent/report-status", json=node_metrics_payload, headers=headers, timeout=10
            )
            # 2. Sync VPN Profiles (on change)
            current_profiles, current_profiles_checksum = parse_index_txt()
            if current_profiles_checksum != last_vpn_profiles_checksum:
                vpn_profiles_payload = {"serverId": SERVER_ID, "vpnProfiles": current_profiles}
                await asyncio.to_thread(
                    requests.post, f"{DASHBOARD_API_URL}/agent/sync-profiles", json=vpn_profiles_payload, headers=headers, timeout=10
                )
                #print(f"Sent VPN profiles sync for server {SERVER_ID} (checksum changed).")
                last_vpn_profiles_checksum = current_profiles_checksum
            else:
                #print(f"VPN profiles checksum unchanged for server {SERVER_ID}. Skipping sync.")
                pass
            # 3. Sync User Activity Logs (on change)
            current_activity_logs, current_activity_checksum = parse_activity_logs()
            if current_activity_checksum and current_activity_checksum != last_activity_log_checksum:
                activity_logs_payload = {
                    "serverId": SERVER_ID,
                    "activityLogs": current_activity_logs
                }
                await asyncio.to_thread(
                    requests.post, f"{DASHBOARD_API_URL}/agent/report-activity-logs", json=activity_logs_payload, headers=headers, timeout=10
                )
                #print(f"Sent user activity logs for server {SERVER_ID} (checksum changed).")
                last_activity_log_checksum = current_activity_checksum
            else:
                #print(f"User activity log checksum unchanged for server {SERVER_ID}. Skipping sync.")
                pass
            # 4. Process Pending Actions from Dashboard
            action_logs_response = await asyncio.to_thread(
                requests.get, f"{DASHBOARD_API_URL}/agent/action-logs?serverId={SERVER_ID}", headers=headers, timeout=10
            )
            action_logs_response.raise_for_status()
            pending_actions = action_logs_response.json()
            for action_log in pending_actions:
                try:
                    log_entry = ActionLogEntry(**action_log)
                    print(f"Processing action log: {log_entry.id} - {log_entry.action}")
                    execution_result = {"status": "success", "message": "", "ovpnFileContent": None}
                    # Run the manager script with sudo as it needs root privileges
                    if log_entry.action == "CREATE_USER":
                        username = sanitize_username(log_entry.details)
                        run(["sudo", SCRIPT_PATH, "create", username], check=True)
                        ovpn_path = os.path.join(OVPN_DIR, f"{username}.ovpn")
                        # Read the OVPN file without sudo as it's run as root
                        result_ovpn = run(["cat", ovpn_path], capture_output=True, text=True, check=True)
                        execution_result["ovpnFileContent"] = result_ovpn.stdout
                        execution_result["message"] = f"User {username} created."
                    elif log_entry.action in ["REVOKE_USER", "DELETE_USER"]:
                        username = sanitize_username(log_entry.details)
                        run(["sudo", SCRIPT_PATH, "revoke", username], check=True)
                        execution_result["message"] = f"User {username} revoked."
                    elif log_entry.action == "DECOMMISSION_AGENT":
                        try:
                            print(f"Sending decommission confirmation for {SERVER_ID}...")
                            try:
                                requests.post(
                                    f"{DASHBOARD_API_URL}/agent/decommission-complete",
                                    json={"serverId": SERVER_ID},
                                    headers=headers,
                                    timeout=5
                                )
                                print("✅ Decommission signal sent to dashboard.")
                            except Exception as e:
                                print(f"⚠️ Could not send decommission signal: {e}. Proceeding with self-destruct anyway.")
                        finally:
                            print("Scheduling self-destruct script with 'systemd-run'...")
                            service_name = SERVICE_NAME or SERVER_ID
                            systemd_command = [
                                "sudo", "systemd-run",
                                "--on-active=5s",
                                "--unit=agent-self-destruct", # Memberi nama agar mudah di-debug
                                "/bin/bash", f"{SCRIPT_DIR}/self-destruct.sh", service_name
                            ]
                            try:
                                # Kita tidak lagi menggunakan Popen, tapi run yang menunggu selesai.
                                subprocess.run(systemd_command, check=True)
                                print("✅ Self-destruct job successfully scheduled with 'systemd-run'.")
                            except subprocess.CalledProcessError as e:
                                print(f"❌ FAILED to schedule self-destruct with 'systemd-run': {e}")
                            print("💀 Agent is shutting down to allow self-destruct job to run...")
                            import sys
                            sys.exit(0)
                    if log_entry.action != "DECOMMISSION_AGENT":
                        await asyncio.to_thread(
                            requests.post, f"{DASHBOARD_API_URL}/agent/action-logs/complete",
                            json={"actionLogId": log_entry.id, "status": execution_result["status"], "message": execution_result["message"], "ovpnFileContent": execution_result["ovpnFileContent"]},
                            headers=headers,
                            timeout=10
                        )
                except Exception as e:
                    print(f"Error processing action log {action_log.get('id', 'N/A')}: {e}")
                    await asyncio.to_thread(
                        requests.post, f"{DASHBOARD_API_URL}/agent/action-logs/complete",
                        json={"actionLogId": action_log.get('id', 'N/A'), "status": "failed", "message": f"Agent internal error: {e}"},
                        headers=headers,
                        timeout=10
                    )
        except requests.exceptions.RequestException as e:
            print(f"Error communicating with dashboard API: {e}")
        except Exception as e:
            print(f"An unexpected error occurred in background task: {e}")
        await asyncio.sleep(METRICS_INTERVAL)

@app.on_event("startup")
async def startup_event():
    asyncio.create_task(background_task_loop())

# --- Agent Endpoints ---
@app.get("/health")
def health(): return {"status": "ok"}

@app.get("/stats")
def get_stats():
    return {"serviceStatus": get_openvpn_service_status()}

@app.get("/profiles")
def list_profiles_agent_side():
    profiles, _ = parse_index_txt()
    return profiles

@app.get("/active-users")
def list_active_users_agent_side():
    return {"activeUsers": get_openvpn_active_users_from_status_log()}

@app.post("/users")
async def create_user_direct(data: CreateUserRequest):
    username = sanitize_username(data.username)
    # Run the manager script with sudo
    result = run(["sudo", SCRIPT_PATH, "create", username], stdout=PIPE, stderr=PIPE, text=True)
    if result.returncode != 0: raise HTTPException(status_code=500, detail=result.stderr)
    return {"username": username, "message": "User created."}

@app.delete("/users/{username}")
def revoke_user_direct(username: str):
    username = sanitize_username(username)
    # Run the manager script with sudo
    result = run(["sudo", SCRIPT_PATH, "revoke", username], stdout=PIPE, stderr=PIPE, text=True)
    if result.returncode != 0: raise HTTPException(status_code=500, detail=result.stderr)
    return {"detail": f"User {username} revoked"}

_PYTHON_SCRIPT_EOF_
    chmod +x "$SCRIPT_DIR/$PYTHON_AGENT_SCRIPT_NAME"
    chown "$SUDO_USER":"$SUDO_USER" "$SCRIPT_DIR/$PYTHON_AGENT_SCRIPT_NAME"
    echo "✅ Python agent script deployed successfully."

    # Save the client manager script (using the best version from original)
    echo "⚙️  Writing client manager script to $SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME..."
    cat << 'CLIENT_MANAGER_EOF' | sudo -u "$SUDO_USER" tee "$SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME" > /dev/null
#!/bin/bash
# shellcheck disable=SC2164,SC2034
# Path to the OpenVPN install script (ensure it's correct)
OPENVPN_INSTALL_SCRIPT="/root/ubuntu-22.04-lts-vpn-server.sh"

create_client() {
    local username=$1
    if [ -z "$username" ]; then
        echo "⛔ Please provide a username. Usage: $0 create <username>"
        exit 1
    fi
    echo "➕ Creating new client: $username"
    # MODIFICATION: Run the OpenVPN installation script with sudo
    printf "1
%s
1
" "$username" | sudo "$OPENVPN_INSTALL_SCRIPT"
    echo "✅ Client '$username' created successfully."
}

revoke_client() {
    local username="$1"
    if [ -z "$username" ]; then
        echo "⛔ Please provide a username. Usage: $0 revoke <username>"
        exit 1
    fi
    echo "🔍 Finding client number for '$username' from index.txt..."
    # Get client number from index.txt (valid clients only, case-insensitive)
    # BUG FIX: Use sudo to read the index.txt file
    local client_number
    client_number=$(sudo tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f2 | nl -w1 -s' ' | \
        awk -v name="$username" 'BEGIN{IGNORECASE=1} $2 == name {print $1; exit}')
    if [ -z "$client_number" ]; then
        echo "⛔ Client '$username' not found. Try listing clients with: ./openvpn-client-manager.sh list"
        exit 1
    fi
    echo "✅ Found it! '$username' is number $client_number"
    echo "⚙️  Sending input to the script to revoke..."
    expect <<EOF
        spawn sudo "$OPENVPN_INSTALL_SCRIPT"
        expect "Select an option*" { send "2\r" }
        expect "Select one client*" { send "$client_number\r" }
        expect eof
EOF
    echo "✅ Client '$username' has been revoked. RIP 🪦"
}

list_clients() {
    echo "📋 Listing active clients from Easy-RSA index.txt..."
    # BUG FIX: Use sudo to read the index.txt file
    if [[ -f /etc/openvpn/easy-rsa/pki/index.txt ]]; then
        sudo grep "^V" /etc/openvpn/easy-rsa/pki/index.txt | \
        cut -d '=' -f2 | \
        grep -v '^server_' # Adjust this line if needed
    else
        echo "⛔ index.txt not found at /etc/openvpn/easy-rsa/pki/"
        exit 1
    fi
}

# Main entrypoint
case "$1" in
    create)
        create_client "$2"
        ;;
    revoke)
        revoke_client "$2"
        ;;
    list)
        list_clients
        ;;
    *)
        echo "Usage: $0 {create|revoke|list} <username>"
        exit 1
        ;;
esac
CLIENT_MANAGER_EOF
    chmod +x "$SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME"
    chown "$SUDO_USER":"$SUDO_USER" "$SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME"
    echo "✅ Client manager script deployed successfully."

    echo "🗑️  Writing self-destruct script..."
    cat << 'SELF_DESTRUCT_EOF' | sudo -u "$SUDO_USER" tee "$SCRIPT_DIR/self-destruct.sh" > /dev/null
# self-destruct.sh
#!/bin/bash
# Skrip ini sekarang dijalankan oleh systemd-run, bukan dari agent langsung.
set -e # Aktifkan kembali 'exit on error' agar lebih tegas.

if [ "$EUID" -ne 0 ]; then
    echo "⛔ This script must be run with sudo/root."
    exit 1
fi

SERVICE_NAME="$1"
# Dapatkan path direktori agent dari lokasi skrip ini
AGENT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

LOG_FILE="/tmp/self-destruct-log-$(date +%s).txt"
echo "🛑 Executing self-destruct for '$SERVICE_NAME' at $(date)" | tee -a "$LOG_FILE"

# 1. Pastikan layanan asli sudah berhenti dan dinonaktifkan
echo "[-] Ensuring service '$SERVICE_NAME' is stopped and disabled..." | tee -a "$LOG_FILE"
systemctl stop "$SERVICE_NAME" || echo "Service was not running."
systemctl disable "$SERVICE_NAME" || echo "Service was not enabled."

# 2. Hapus file layanan systemd untuk mencegahnya kembali
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
if [ -f "$SERVICE_FILE" ]; then
    echo "🗑️ Deleting systemd service file: $SERVICE_FILE" | tee -a "$LOG_FILE"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
fi

# 3. Hapus direktori agent
if [ -d "$AGENT_DIR" ]; then
    echo "🗑️ Deleting agent installation directory: $AGENT_DIR" | tee -a "$LOG_FILE"
    rm -rf "$AGENT_DIR"
fi

echo "✅ Agent self-destruct process complete." | tee -a "$LOG_FILE"
SELF_DESTRUCT_EOF
    chmod +x "$SCRIPT_DIR/self-destruct.sh"
    chown "$SUDO_USER":"$SUDO_USER" "$SCRIPT_DIR/self-destruct.sh"
    echo "✅ Self-destruct script deployed successfully."

    echo ""
    echo "✅ ALL SCRIPTS DEPLOYED SUCCESSFULLY"
}

# --- Function: Setup OpenVPN Logrotate ---
setup_openvpn_logrotate() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🔄 CONFIGURING LOG ROTATION FOR OPENVPN"
    echo "═══════════════════════════════════════════════"
    echo ""

    local log_file="/var/log/openvpn/openvpn.log"
    local rotate_conf_dir="/etc/logrotate.d"
    local new_conf_file="$rotate_conf_dir/openvpn-log"

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
        if [ -f /run/openvpn/server.pid ]; then
            /bin/systemctl restart openvpn@server > /dev/null 2>&1 || true
        fi
    endscript
}
EOF
        echo "✅ Logrotate configuration created successfully."
    else
        echo "⏩ Skipping logrotate setup."
    fi
}

# --- NEW FUNCTION: Setup Agent Logrotate ---
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
        echo "✅ Log rotation for agent logs in $agent_log_path seems to be already configured. Skipping."
        return
    fi
    
    echo "📝 Creating logrotate configuration for agent logs at $new_conf_file..."
    
    # Use a heredoc that expands variables to get the correct SCRIPT_DIR
    cat << EOF | tee "$new_conf_file" > /dev/null
$SCRIPT_DIR/logs/*.log {
    # Rotasi setiap bulan
    monthly

    # Simpan 2 file log lama (2 bulan)
    rotate 2

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
}

# --- NEW FUNCTION: Create Systemd Service File ---
create_systemd_service_file() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "⚙️  CREATING SYSTEMD SERVICE FILE"
    echo "═══════════════════════════════════════════════"
    echo ""

    local service_file_path="/etc/systemd/system/$APP_NAME.service"

    echo "📝 Creating systemd service file at $service_file_path..."

    cat << EOF | tee "$service_file_path" > /dev/null
[Unit]
Description=OpenVPN Agent Service for $SERVER_ID
After=network.target

[Service]
Type=simple
User=$SUDO_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$VENV_PATH/bin/uvicorn main:app --host 0.0.0.0 --port 8080
Restart=always
RestartSec=10
EnvironmentFile=-$SCRIPT_DIR/.env
StandardOutput=append:$SCRIPT_DIR/logs/agent-out.log
StandardError=append:$SCRIPT_DIR/logs/agent-err.log

[Install]
WantedBy=multi-user.target
EOF

    echo "✅ Systemd service file created successfully."
}

# --- NEW FUNCTION: Configure and Start Systemd Service ---
configure_systemd() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🚀 CONFIGURING AND STARTING SYSTEMD SERVICE"
    echo "═══════════════════════════════════════════════"
    echo ""

    local service_name="$APP_NAME"

    echo "🔄 Reloading systemd daemon..."
    systemctl daemon-reload

    echo "🧹 Stopping any existing service instance..."
    systemctl stop "$service_name" >/dev/null 2>&1 || true

    echo "▶️  Starting the application with systemd..."
    if systemctl start "$service_name"; then
        echo "✅ Application started successfully with systemd."
    else
        echo "⛔ Failed to start application with systemd."
        systemctl status "$service_name" --no-pager
        exit 1
    fi

    echo "🔗 Enabling service to start automatically on boot..."
    if systemctl enable "$service_name"; then
        echo "✅ Service enabled for auto-start on boot."
    else
        echo "⚠️  Failed to enable service for auto-start. You may need to run 'sudo systemctl enable $service_name' manually."
    fi

    echo ""
    echo "📊 Service status:"
    systemctl status "$service_name" --no-pager

    echo ""
    echo "✅ SYSTEMD SERVICE CONFIGURED SUCCESSFULLY"
}

# --- Main Execution ---
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║          OPENVPN AGENT DEPLOYMENT             ║"
    echo "║             (SIMPLIFIED - SYSTEMD)            ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""

    check_sudo
    get_user_input
    
    # --- NEW: Call the cleanup function before doing anything else ---
    cleanup_old_pm2_installation

    ## VENV CHANGE: Create the script directory at the beginning
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "📂 PREPARING DIRECTORY"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "📁 Creating agent directory at $SCRIPT_DIR..."
    if mkdir -p "$SCRIPT_DIR"; then
        chown -R "$SUDO_USER":"$SUDO_USER" "$SCRIPT_DIR"
        echo "✅ Directory created and ownership set successfully."
    else
        echo "⛔ Failed to create agent directory."
        exit 1
    fi

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🔍 SYSTEM VALIDATION"
    echo "═══════════════════════════════════════════════"
    echo ""

    if ! find_easy_rsa_path; then
        echo "⛔ Easy-RSA not found. Deployment canceled."
        exit 1
    fi

    if ! check_openvpn_service; then
        if [ ! -f "$OPENVPN_INSTALL_SCRIPT_PATH" ]; then
            echo ""
            echo "⛔ OpenVPN server installation script not found at $OPENVPN_INSTALL_SCRIPT_PATH."
            echo "   Please ensure OpenVPN is already installed and running, or place the installation script"
            echo "   in the correct location."
            exit 1
        fi
        echo ""
        echo "▶️  Running OpenVPN server installation script..."
        if sudo bash "$OPENVPN_INSTALL_SCRIPT_PATH"; then
            echo "✅ OpenVPN installed and configured successfully."
        else
            echo "⛔ Failed to install OpenVPN."
            exit 1
        fi
    fi

    install_dependencies
    create_env_file
    deploy_scripts
    create_systemd_service_file 
    setup_openvpn_logrotate
    setup_agent_logrotate
    configure_systemd          

    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║               DEPLOYMENT COMPLETE             ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    echo "🎉 OpenVPN agent deployment completed successfully!"
    echo ""
    echo "📋 DEPLOYMENT SUMMARY:"
    echo "   • Server ID: $SERVER_ID"
    echo "   • Systemd Service: $APP_NAME"
    echo "   • Dashboard URL: $DASHBOARD_API_URL"
    echo "   • OVPN Directory: $OVPN_DIR"
    if [[ "$CPU_RAM_INTERVAL" == "disabled" ]]; then
        echo "   • CPU/RAM Monitoring: DISABLED"
    else
        echo "   • CPU/RAM Monitoring: ${CPU_RAM_INTERVAL}s"
    fi
    echo ""
    echo "📁 IMPORTANT FILE LOCATIONS:"
    echo "   • Agent Directory: $SCRIPT_DIR"
    echo "   • Configuration File: $SCRIPT_DIR/.env"
    echo "   • Application Logs: $SCRIPT_DIR/logs/"
    echo "   • Systemd Service File: /etc/systemd/system/$APP_NAME.service"
    echo ""
    echo "🔧 USEFUL COMMANDS:"
    echo "   • Check status: sudo systemctl status $APP_NAME"
    echo "   • View logs: journalctl -u $APP_NAME -f"
    echo "   • Restart: sudo systemctl restart $APP_NAME"
    echo "   • Stop: sudo systemctl stop $APP_NAME"
    echo "   • Start: sudo systemctl start $APP_NAME"
    echo ""
    echo "⚠️  DON'T FORGET:"
    echo "   • The service is configured to start automatically on boot."
    echo "   • Ensure the firewall allows port 8080 for the agent."
    echo "⚠️  REMEMBER: If using UFW, run: sudo ufw allow 8080"
    echo ""
    echo "🌐 The agent can be reached at: http://$(hostname -I | awk '{print $1}'):8080/health"
    echo ""
    echo "✅ Deployment successful! The agent is ready to use."
    echo "🧪 Testing agent health endpoint..."
    if curl -f http://localhost:8080/health >/dev/null 2>&1; then
        echo "✅ Agent is responding at http://localhost:8080/health"
    else
        echo "⚠️  Agent health check failed. Check logs with: journalctl -u $APP_NAME -n 50"
    fi
}

# Run the main function
main "$@"
