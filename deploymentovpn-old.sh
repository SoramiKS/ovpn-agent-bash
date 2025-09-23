#!/bin/bash
#
# deploymentovpn.sh (Unified Version with SNMP)
#
# This script automates the deployment of the OpenVPN Agent on a new server.
# It will install dependencies, configure SNMP, create a Python virtual environment (venv),
# deploy the agent and client manager scripts, and configure them to
# run with PM2 from within the venv.
#
# Usage: sudo ./deploymentovpn.sh
#
# Exit immediately if a command exits with a non-zero status.
set -e

# --- Default Configuration ---
PYTHON_AGENT_SCRIPT_NAME="main.py"
CLIENT_MANAGER_SCRIPT_NAME="openvpn-client-manager.sh"
OPENVPN_INSTALL_SCRIPT_PATH="/root/ubuntu-22.04-lts-vpn-server.sh"
NODE_VERSION="v22.19"
NODE_DIR="node-$NODE_VERSION-linux-x64"
NODE_URL="https://nodejs.org/dist/$NODE_VERSION/$NODE_DIR.tar.gz"

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
APP_NAME=""
DASHBOARD_API_URL=""
SERVER_ID=""
OVPN_DIR=""
# Variables for SNMP
CONFIGURE_SNMP="N"
SNMP_COMMUNITY_STRING=""
DASHBOARD_MONITORING_IP=""

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
        read -p "🏷️ Enter the Application Name for PM2 (e.g., vpn-agent): " APP_NAME
        if [ -z "$APP_NAME" ]; then
            echo "⛔ Application name cannot be empty."
        fi
    done

    echo ""
    while [ -z "$AGENT_API_KEY" ]; do
        read -p "🔑 Enter the AGENT_API_KEY (ensure it matches the one on the dashboard): " AGENT_API_KEY
        if [ -z "$AGENT_API_KEY" ]; then
            echo "⛔ API Key cannot be empty."
        fi
    done

    local url_type_valid=0
    local DASHBOARD_HOST_RAW="" # Raw input from user
    local PROTOCOL=""
    local BASE_URL="" # Will store protocol://host[:port]

    while [ $url_type_valid -eq 0 ]; do
        echo ""
        echo "Select the Dashboard API address type:"
        echo "1) IP Address (e.g., 192.168.1.42)"
        echo "2) Domain Name (e.g., dashboard.example.com)"
        read -p "Your choice [Default 2]: " URL_CHOICE
        URL_CHOICE=${URL_CHOICE:-2}

        case "$URL_CHOICE" in
            1)
                local ip_valid=0
                while [ $ip_valid -eq 0 ]; do
                    read -p "🌐 Enter the Dashboard API IP Address: " DASHBOARD_HOST_RAW
                    if [[ $DASHBOARD_HOST_RAW =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                        echo "🔎 Pinging $DASHBOARD_HOST_RAW..."
                        if ping -c 1 -W 1 "$DASHBOARD_HOST_RAW" > /dev/null 2>&1; then
                            echo "✅ Dashboard API IP ($DASHBOARD_HOST_RAW) is reachable."
                            PROTOCOL="https://" # Default to HTTPS for IP
                            BASE_URL="${PROTOCOL}${DASHBOARD_HOST_RAW}"
                            DASHBOARD_MONITORING_IP=$DASHBOARD_HOST_RAW # Save IP for SNMP
                            ip_valid=1
                        else
                            echo "⛔ Failed to ping $DASHBOARD_HOST_RAW. Ensure the IP is correct and the server is up."
                        fi
                    else
                        echo "⛔ Invalid IP format. Please enter a correct IP format."
                    fi
                done
                url_type_valid=1
                ;;
            2)
                local domain_valid=0
                while [ $domain_valid -eq 0 ]; do
                    read -p "🌐 Enter the Dashboard API Domain Name (Default: vpn.clouddonut.net): " DASHBOARD_HOST_RAW
                    DASHBOARD_HOST_RAW=${DASHBOARD_HOST_RAW:-vpn.clouddonut.net}
                    if [[ -z "$DASHBOARD_HOST_RAW" ]]; then
                        echo "⛔ Domain name cannot be empty."
                    else
                        # Check for existing protocol
                        if [[ "$DASHBOARD_HOST_RAW" =~ ^(http|https):// ]]; then
                            PROTOCOL=$(echo "$DASHBOARD_HOST_RAW" | grep -oE '^(http|https)://')
                            # Remove protocol for further validation and handling
                            DASHBOARD_HOST_CLEAN=${DASHBOARD_HOST_RAW#*//}
                        else
                            PROTOCOL="https://" # Default to HTTPS if no protocol is given
                            DASHBOARD_HOST_CLEAN=$DASHBOARD_HOST_RAW
                        fi

                        # Basic domain validation (can be made more robust if needed)
                        # Remove port or '/api' if present for pure domain validation
                        local temp_host_for_validation=${DASHBOARD_HOST_CLEAN}
                        temp_host_for_validation=${temp_host_for_validation%:*} # Remove port if present
                        temp_host_for_validation=${temp_host_for_validation%/api*} # Remove /api if present

                        if [[ "$temp_host_for_validation" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,6}$ ]]; then
                            echo "✅ Domain Name ($DASHBOARD_HOST_CLEAN) accepted."
                            BASE_URL="${PROTOCOL}${DASHBOARD_HOST_CLEAN}" # Build BASE_URL with the correct protocol
                            domain_valid=1
                        else
                            echo "⛔ Invalid domain format. Please enter a correct domain format."
                        fi
                    fi
                done
                url_type_valid=1
                ;;
            *)
                echo "⛔ Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done

    # Ask about a custom port (applies to both IP and Domain)
    read -p "Does the Dashboard API use a custom port (e.g., 3000)? (Default: N) [y/N]: " USE_CUSTOM_PORT
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
                echo "⛔ Invalid port. Please enter a number between 1 and 65535."
            fi
        done
    fi

    # Build the final DASHBOARD_API_URL
    # Ensure no double '/api' if the user already entered it
    local TEMP_DASHBOARD_API_URL="${BASE_URL}${FINAL_PORT_PART}"
    if [[ "$TEMP_DASHBOARD_API_URL" != */api ]]; then
        DASHBOARD_API_URL="${TEMP_DASHBOARD_API_URL}/api"
    else
        DASHBOARD_API_URL="${TEMP_DASHBOARD_API_URL}"
    fi

    echo "✅ Dashboard API URL will be set to: $DASHBOARD_API_URL"

    echo ""
    while [ -z "$SERVER_ID" ]; do
        read -p "🏷️ Enter the Server ID (e.g., SERVER-01): " SERVER_ID
        if [ -z "$SERVER_ID" ]; then
            echo "⛔ Server ID cannot be empty."
        fi
    done

    echo ""
    read -p "📁 Enter the directory for OVPN files (Default: /root): " OVPN_DIR_INPUT
    OVPN_DIR=${OVPN_DIR_INPUT:-/root}
    echo "✅ OVPN directory: $OVPN_DIR"
}

# --- NEW FUNCTION: SNMP Input ---
get_snmp_input() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🛡️  SNMP MONITORING CONFIGURATION"
    echo "═══════════════════════════════════════════════"
    echo ""
    read -p "🔧 Do you want to configure SNMP for monitoring? (Default: N) [y/N]: " CONFIGURE_SNMP
    CONFIGURE_SNMP=${CONFIGURE_SNMP:-N}

    if [[ "$CONFIGURE_SNMP" =~ ^[yY]$ ]]; then
        echo ""
        echo "ℹ️  SNMP allows the dashboard to monitor CPU, RAM, and other system metrics."
        echo ""
        
        while [ -z "$SNMP_COMMUNITY_STRING" ]; do
            read -p "🔒 Enter the SNMP Community String (like a password, e.g., public_vpn): " SNMP_COMMUNITY_STRING
            if [ -z "$SNMP_COMMUNITY_STRING" ]; then
                echo "⛔ Community string cannot be empty."
            fi
        done
        
        # If the dashboard uses a domain, we need its IP for SNMP
        if [ -z "$DASHBOARD_MONITORING_IP" ]; then
            echo ""
            echo "⚠️  For SNMP security, we need to allow access from a specific IP only."
            while [ -z "$DASHBOARD_MONITORING_IP" ]; do
                read -p "🌍 Enter the IP Address of the Dashboard server to allow monitoring from: " DASHBOARD_MONITORING_IP
                if [[ ! $DASHBOARD_MONITORING_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    echo "⛔ Invalid IP format. Please enter a correct IP format."
                    DASHBOARD_MONITORING_IP=""
                fi
            done
        fi
        
        echo ""
        echo "✅ SNMP will be configured with:"
        echo "   • Community String: $SNMP_COMMUNITY_STRING"
        echo "   • Allowed IP: $DASHBOARD_MONITORING_IP"
        echo ""
    else
        echo "ℹ️  Skipping SNMP configuration."
        echo ""
    fi
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

# Install system dependencies, Node.js, and Python
# Install system dependencies, Node.js, and Python
install_dependencies() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "⚙️  INSTALLING SYSTEM DEPENDENCIES (FOR ROOT)"
    echo "═══════════════════════════════════════════════"
    echo ""
    
    echo "📦 Updating package lists..."
    apt-get update -qq

    echo "📦 Installing system dependencies..."
    apt-get install -y openvpn python3 python3-pip python3-venv expect curl dos2unix at snmpd

    dos2unix "$0" >/dev/null 2>&1

    echo ""
    echo "⚙️  Installing Node.js via NVM for root..."
    
    echo "--> Installing NVM..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash

    export NVM_DIR="$HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # Muat NVM ke sesi skrip saat ini
        source "$NVM_DIR/nvm.sh"
    else
        echo "⛔ Failed to source NVM script. Aborting."
        exit 1
    fi
    
    echo "--> Installing Node.js version $NODE_VERSION..."
    nvm install "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    nvm use default

    echo "✅ Verifying Node.js installation..."
    node -v
    echo "✅ Node.js and NVM installed successfully for root."

    echo ""
    echo "⚙️  Installing PM2..."
    if ! command -v pm2 &> /dev/null; then
        echo "   PM2 not found, installing globally..."
        npm install -g pm2
        echo "✅ PM2 installed globally."
    else
        echo "☑️  PM2 is already installed. Skipping."
    fi

    # === BAGIAN PERBAIKAN PENTING DIMULAI DI SINI ===
    echo ""
    echo "🔗 Creating system-wide symbolic links..."

    # Cari path Node dan PM2 yang diinstal NVM
    NODE_PATH=$(which node)
    PM2_PATH=$(which pm2)

    if [ -n "$NODE_PATH" ]; then
        ln -sf "$NODE_PATH" /usr/local/bin/node
        echo "✅ Node symlink created at /usr/local/bin/node"
    else
        echo "⛔ Could not find Node path. Deployment might fail."
        exit 1
    fi

    if [ -n "$PM2_PATH" ]; then
        ln -sf "$PM2_PATH" /usr/local/bin/pm2
        echo "✅ PM2 symlink created at /usr/local/bin/pm2"
    else
        echo "⛔ Could not find PM2 path. Deployment might fail."
        exit 1
    fi
    # === BAGIAN PERBAIKAN SELESAI ===

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🐍 CONFIGURING PYTHON VIRTUAL ENVIRONMENT"
    echo "═══════════════════════════════════════════════"
    echo ""
    
    echo "🏗️  Creating Python virtual environment at $VENV_PATH..."
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

# --- NEW FUNCTION: SNMP Configuration ---
configure_snmp() {
    if [[ "$CONFIGURE_SNMP" =~ ^[yY]$ ]]; then
        echo ""
        echo "═══════════════════════════════════════════════"
        echo "🛡️  CONFIGURING SNMP DAEMON"
        echo "═══════════════════════════════════════════════"
        echo ""
        
        echo "📝 Creating SNMP configuration..."
        # Create a backup of the old configuration if it exists
        if [ -f /etc/snmp/snmpd.conf ]; then
            cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.backup.$(date +%Y%m%d_%H%M%S)
            echo "   Backup of old configuration created."
        fi
        
        # Create a secure configuration file
        cat << EOF | tee /etc/snmp/snmpd.conf > /dev/null
#
# SNMP Configuration for OpenVPN Agent Monitoring
# Generated by deploymentovpn.sh
#

# Allow read-only access from the dashboard IP
rocommunity $SNMP_COMMUNITY_STRING $DASHBOARD_MONITORING_IP

# System information
sysLocation    "OpenVPN Server - Managed by VPN Agent"
sysContact     "OpenVPN Agent <agent@vpnserver.local>"
sysName        "$SERVER_ID"

# Disable default public community for security
com2sec notConfigUser  default       public

# Group access configuration
group   notConfigGroup v1           notConfigUser
group   notConfigGroup v2c          notConfigUser

# Restricted view
view    systemview    included   .1.3.6.1.2.1.1
view    systemview    included   .1.3.6.1.2.1.25.1.1

# Limited access
access  notConfigGroup ""      any       noauth    exact  systemview none none

# Disable unnecessary access logging
dontLogTCPWrappersConnects yes
EOF

        echo "🔄 Restarting and enabling SNMP service..."
        if systemctl restart snmpd && systemctl enable snmpd; then
            echo "✅ SNMP daemon configured and enabled successfully."
            echo ""
            echo "📊 SNMP Information:"
            echo "   • Community String: $SNMP_COMMUNITY_STRING"
            echo "   • Allowed IP: $DASHBOARD_MONITORING_IP"
            echo "   • Port: 161 (UDP)"
            echo ""
            
            # Test SNMP locally
            echo "🧪 Testing SNMP locally..."
            if command -v snmpget &> /dev/null; then
                if snmpget -v2c -c "$SNMP_COMMUNITY_STRING" localhost 1.3.6.1.2.1.1.1.0 >/dev/null 2>&1; then
                    echo "✅ SNMP test successful."
                else
                    echo "⚠️  SNMP test failed, but the configuration has been created."
                fi
            else
                echo "ℹ️  snmp-utils is not installed, cannot perform local test."
            fi
        else
            echo "⛔ Failed to configure SNMP daemon."
            exit 1
        fi
        
        echo "✅ SNMP CONFIGURATION COMPLETE"
    else
        echo ""
        echo "ℹ️  Skipping SNMP configuration."
    fi
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

# PM2 Configuration
PM2_APP_NAME="$APP_NAME"
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
PM2_APP_NAME = os.getenv("PM2_APP_NAME")

if not AGENT_API_KEY:
    raise RuntimeError("Missing AGENT_API_KEY in .env")
if not SERVER_ID:
    raise RuntimeError("Missing SERVER_ID in .env")
if not DASHBOARD_API_URL:
    raise RuntimeError("Missing DASHBOARD_API_URL in .env")
# BUG FIX: No need to check for the file here, as it will be accessed with sudo
# if not os.path.exists(EASY_RSA_INDEX_PATH):
#     raise RuntimeError(f"Easy-RSA index.txt not found at {EASY_RSA_INDEX_PATH}")

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
def get_cpu_usage() -> float:
    """Returns the system-wide CPU utilization as a percentage."""
    try:
        # interval=1 means it will block for 1 second to compare usage
        return psutil.cpu_percent(interval=1)
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
                # BUG FIX: Run as root, so no sudo needed
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

            log_entry = {
                "timestamp": timestamp,
                "action": parts[1],
                "username": parts[2] if len(parts) > 2 and parts[2] else None,
                "publicIp": parts[3] if len(parts) > 3 and parts[3] else None,
                "vpnIp": parts[4] if len(parts) > 4 and parts[4] else None,
                "bytesReceived": int(parts[5]) if len(parts) > 5 and parts[1] == "DISCONNECT" else None,
                "bytesSent": int(parts[6]) if len(parts) > 6 and parts[1] == "DISCONNECT" else None,
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

            # 1. Report Node Metrics (service status only, CPU/RAM via SNMP)
            service_status = get_openvpn_service_status()
            active_users = get_openvpn_active_users_from_status_log()
            cpu_usage = await asyncio.to_thread(get_cpu_usage)
            ram_usage = await asyncio.to_thread(get_ram_usage)
            node_metrics_payload = {
                "serverId": SERVER_ID,
                "serviceStatus": service_status,
                "activeUsers": active_users,
                "cpuUsage": cpu_usage,
                "ramUsage": ram_usage
            }
            await asyncio.to_thread(
                requests.post, f"{DASHBOARD_API_URL}/agent/report-status", json=node_metrics_payload, headers=headers, timeout=10
            )
            print(f"Sent status report for server {SERVER_ID} (CPU: {cpu_usage}%, RAM: {ram_usage}%)")

            # 2. Sync VPN Profiles (on change)
            current_profiles, current_profiles_checksum = parse_index_txt()
            if current_profiles_checksum != last_vpn_profiles_checksum:
                vpn_profiles_payload = {"serverId": SERVER_ID, "vpnProfiles": current_profiles}
                await asyncio.to_thread(
                    requests.post, f"{DASHBOARD_API_URL}/agent/sync-profiles", json=vpn_profiles_payload, headers=headers, timeout=10
                )
                print(f"Sent VPN profiles sync for server {SERVER_ID} (checksum changed).")
                last_vpn_profiles_checksum = current_profiles_checksum
            else:
                print(f"VPN profiles checksum unchanged for server {SERVER_ID}. Skipping sync.")

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
                print(f"Sent user activity logs for server {SERVER_ID} (checksum changed).")
                last_activity_log_checksum = current_activity_checksum
            else:
                print(f"User activity log checksum unchanged for server {SERVER_ID}. Skipping sync.")

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
                            requests.post(
                                f"{DASHBOARD_API_URL}/agent/decommission-complete",
                                json={"serverId": SERVER_ID},
                                headers=headers,
                                timeout=5
                            )
                            print("Decommission signal sent.")
                        
                        except Exception as e:
                            print(f"Could not send decommission signal: {e}")

                        finally:
                            print("Scheduling self-destruct script...")
                            app_name = PM2_APP_NAME or SERVER_ID
                            script = f"sleep 10 && sudo /bin/bash {SCRIPT_DIR}/self-destruct.sh {app_name}"

                            # Let the shell handle redirection and backgrounding
                            subprocess.Popen(
                                f"nohup sh -c \"{script}\" >/dev/null 2>&1 &",
                                shell=True
                            )

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

        await asyncio.sleep(60)

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
    printf "1\n%s\n1\n" "$username" | sudo "$OPENVPN_INSTALL_SCRIPT"
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
#!/bin/bash
# self-destruct.sh (Final & Robust Version)
set -e

if [ "$EUID" -ne 0 ]; then
    echo "⛔ This script must be run with sudo."
    exit 1
fi

PM2_APP_NAME="$1"
AGENT_DIR=$(dirname "$(readlink -f "$0")")

echo "🛑 Receiving self-destruct command for '$PM2_APP_NAME'..."

echo "[-] Stopping and deleting PM2 process: $PM2_APP_NAME"
# BUG FIX: Run PM2 as root
pm2 stop "$PM2_APP_NAME" || true
pm2 delete "$PM2_APP_NAME" || true
pm2 save --force

echo "🗑️ Deleting agent installation directory: $AGENT_DIR"
# BUG FIX: Use rm -rf to delete files and directories
rm -rf "$AGENT_DIR"

echo "✅ Agent self-destruct process complete."
SELF_DESTRUCT_EOF

    chmod +x "$SCRIPT_DIR/self-destruct.sh"
    chown "$SUDO_USER":"$SUDO_USER" "$SCRIPT_DIR/self-destruct.sh"
    echo "✅ Self-destruct script deployed successfully."
    
    echo ""
    echo "✅ ALL SCRIPTS DEPLOYED SUCCESSFULLY"
}

# Create the PM2 ecosystem configuration file based on user input
create_pm2_ecosystem_file() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🚀 CREATING PM2 CONFIGURATION"
    echo "═══════════════════════════════════════════════"
    echo ""
    
    echo "📝 Creating ecosystem.config.js file..."
    # Use tee to create the file with root permissions
    cat << EOF | tee "$SCRIPT_DIR/ecosystem.config.js" > /dev/null
module.exports = {
  apps: [{
    name: "$APP_NAME",
    script: "$VENV_PATH/bin/python",
    args: "-m uvicorn main:app --host 0.0.0.0 --port 8080",
    cwd: "$SCRIPT_DIR",
    exec_mode: "fork",
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: "1G",
    env: {
      NODE_ENV: "production",
      AGENT_API_KEY: "$AGENT_API_KEY",
      SERVER_ID: "$SERVER_ID",
      PM2_APP_NAME: "$APP_NAME",
      DASHBOARD_API_URL: "$DASHBOARD_API_URL",
      SCRIPT_PATH: "$SCRIPT_DIR/$CLIENT_MANAGER_SCRIPT_NAME",
      OVPN_DIR: "$OVPN_DIR",
      EASY_RSA_INDEX_PATH: "$EASY_RSA_INDEX_PATH",
      EASY_RSA_SERVER_NAME_PATH: "$EASY_RSA_SERVER_NAME_PATH",
      OVPN_ACTIVITY_LOG_PATH: "/var/log/openvpn/user_activity.log"
    },
    output: "$SCRIPT_DIR/logs/agent-out.log",
    error: "$SCRIPT_DIR/logs/agent-err.log",
    log_date_format: "YYYY-MM-DD HH:mm:ss",
  }]
};
EOF
    chown "$SUDO_USER":"$SUDO_USER" "$SCRIPT_DIR/ecosystem.config.js"
    echo "✅ ecosystem.config.js file created successfully."
}

# Configure PM2 to run the Python agent
configure_pm2() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "🚀 CONFIGURING AND RUNNING PM2"
    echo "═══════════════════════════════════════════════"
    echo ""
    
    echo "📂 Changing to the script directory..."
    cd "$SCRIPT_DIR" || exit
    
    echo "🧹 Cleaning up any existing PM2 application..."
    # BUG FIX: Run PM2 as root
    pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
    
    echo "▶️  Starting the application with PM2..."
    # BUG FIX: Run PM2 as root
    if pm2 start ecosystem.config.js; then
        echo "✅ Application started successfully with PM2."
    else
        echo "⛔ Failed to start application with PM2."
        exit 1
    fi
    
    echo "💾 Saving PM2 configuration..."
    # BUG FIX: Run PM2 as root
    pm2 save
    
    echo ""
    echo "🔗 To enable PM2 to start automatically on boot, run this command with sudo:"
    # BUG FIX: Run PM2 startup as root
    local pm2_startup_cmd=$(pm2 startup systemd | tail -1)
    echo "   $pm2_startup_cmd"
    echo ""
    
    # Display application status
    echo "📊 PM2 application status:"
    # BUG FIX: Run PM2 as root
    pm2 status "$APP_NAME"
    
    echo ""
    echo "✅ PM2 CONFIGURED SUCCESSFULLY"
}

# --- Main Execution ---
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║          OPENVPN AGENT DEPLOYMENT             ║"
    echo "║              WITH SNMP MONITORING             ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    
    check_sudo
    get_user_input
    get_snmp_input

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

    # Execute main functions
    install_dependencies
    configure_snmp
    create_env_file
    deploy_scripts
    create_pm2_ecosystem_file
    configure_pm2

    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║               DEPLOYMENT COMPLETE             ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    echo "🎉 OpenVPN agent deployment with SNMP monitoring completed successfully!"
    echo ""
    echo "📋 DEPLOYMENT SUMMARY:"
    echo "   • Server ID: $SERVER_ID"
    echo "   • PM2 Application: $APP_NAME"
    echo "   • Dashboard URL: $DASHBOARD_API_URL"
    echo "   • OVPN Directory: $OVPN_DIR"
    if [[ "$CONFIGURE_SNMP" =~ ^[yY]$ ]]; then
        echo "   • SNMP: Active (Community: $SNMP_COMMUNITY_STRING)"
    else
        echo "   • SNMP: Not configured"
    fi
    echo ""
    echo "📁 IMPORTANT FILE LOCATIONS:"
    echo "   • Agent Directory: $SCRIPT_DIR"
    echo "   • Configuration File: $SCRIPT_DIR/.env"
    echo "   • Application Logs: $SCRIPT_DIR/logs/"
    echo ""
    echo "🔧 USEFUL COMMANDS:"
    echo "   • Check status: pm2 status $APP_NAME"
    echo "   • View logs: pm2 logs $APP_NAME"
    echo "   • Restart: pm2 restart $APP_NAME"
    echo "   • Stop: pm2 stop $APP_NAME"
    echo ""
    echo "⚠️  DON'T FORGET:"
    echo "   • Run the PM2 startup command shown above to enable auto-start on boot."
    echo "   • Ensure the firewall allows port 8080 for the agent."
    if [[ "$CONFIGURE_SNMP" =~ ^[yY]$ ]]; then
        echo "   • Ensure the firewall allows port 161 (UDP) from the dashboard's IP for SNMP."
    fi
    echo ""
    echo "🌐 The agent can be reached at: http://$(hostname -I | awk '{print $1}'):8080/health"
    echo ""
    echo "✅ Deployment successful! The agent is ready to use."
}

# Run the main function
main "$@"
