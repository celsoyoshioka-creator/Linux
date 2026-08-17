#!/bin/bash
# ==============================================================================
# Fail-Safe Diagnostic Log Collection Script for GPU / Mellanox / System
# Compatibility: Ubuntu / Debian & Oracle Linux / RHEL / CentOS / Rocky / Alma
# Output: /root/support_$hostname_$date.zip (ready to attach to Zendesk ticket)
# ==============================================================================

set -u

# Visual Formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Starting Fail-Safe GPU / System Log Collection   ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. Root User Privilege Check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[CRITICAL ERROR] This script must be executed as root (sudo).${NC}"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "host")
WORKDIR="/tmp/gpu_logs_${HOSTNAME}_${TIMESTAMP}"
mkdir -p "${WORKDIR}"

echo -e "${YELLOW}[+] Temporary working directory: ${WORKDIR}${NC}"

# ------------------------------------------------------------------------------
# OPERATING SYSTEM DETECT & PACKAGE MANAGER IDENTIFICATION
# ------------------------------------------------------------------------------
PKG_MANAGER=""
OS_TYPE=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
fi

echo -e "${YELLOW}[+] Detected Operating System: ${OS_TYPE:-Unknown} (Package Manager: ${PKG_MANAGER:-Unknown})${NC}"

# ------------------------------------------------------------------------------
# AUTOMATIC DEPENDENCY INSTALLATION (FAIL-SAFE)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[+] Checking and installing required dependencies...${NC}"

install_package() {
    local cmd="$1"
    local pkg_apt="$2"
    local pkg_yum="$3"

    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}  -> Command '$cmd' not found. Installing package...${NC}"
        if [ "$PKG_MANAGER" = "apt" ]; then
            apt-get update -qq -y && apt-get install -y -qq "$pkg_apt"
        elif [ "$PKG_MANAGER" = "dnf" ]; then
            dnf install -y -q "$pkg_yum"
        elif [ "$PKG_MANAGER" = "yum" ]; then
            yum install -y -q "$pkg_yum"
        else
            echo -e "${RED}  [WARNING] Unable to install '$cmd' automatically. Package manager not supported.${NC}"
        fi
    fi
}

# Install core tools
install_package "lspci" "pciutils" "pciutils"
install_package "zip" "zip" "zip"
install_package "unzip" "unzip" "unzip"
install_package "python3" "python3" "python3"
install_package "wget" "wget" "wget"
install_package "curl" "curl" "curl"

# ------------------------------------------------------------------------------
# 1. SYSINFO SNAPSHOT (linux-sysinfo-snapshot)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[1/4] Running Sysinfo Snapshot...${NC}"

SYSINFO_BIN=""

# Search standard binary paths
if command -v sysinfo-snapshot.py &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot.py)
elif command -v sysinfo-snapshot &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot)
elif [ -f "./sysinfo-snapshot.py" ]; then
    SYSINFO_BIN="./sysinfo-snapshot.py"
elif [ -f "./sysinfo-snapshot" ]; then
    SYSINFO_BIN="./sysinfo-snapshot"
fi

# Auto-extract local zip if tool not found in PATH
if [ -z "$SYSINFO_BIN" ]; then
    if [ -f "./linux-sysinfo-snapshot-master.zip" ]; then
        echo "Extracting linux-sysinfo-snapshot-master.zip..."
        unzip -q -o ./linux-sysinfo-snapshot-master.zip -d /tmp/sysinfo_extracted
        SYSINFO_BIN=$(find /tmp/sysinfo_extracted -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    fi
fi

if [ -n "$SYSINFO_BIN" ] && ([ -x "$SYSINFO_BIN" ] || [ -f "$SYSINFO_BIN" ]); then
    echo "Executing: $SYSINFO_BIN --gpu"
    python3 "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || true
    
    # Collect generated snapshot files from /tmp or current directory
    find /tmp . -maxdepth 2 -name "sysinfo-snapshot*" -not -path "${WORKDIR}/*" -exec mv {} "${WORKDIR}/" \; 2>/dev/null || true
    echo -e "${GREEN}[OK] Sysinfo snapshot completed.${NC}"
else
    echo -e "${RED}[WARNING] sysinfo-snapshot tool not found in the environment.${NC}"
    echo "Sysinfo snapshot was not executed. Please ensure linux-sysinfo-snapshot-master.zip is placed in the same directory." > "${WORKDIR}/SYSINFO_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 2. CX8 MST DUMP (Mellanox Software Tools)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/4] Running CX8 MST Dumps...${NC}"

# Attempt to start MST service if installed
if command -v mst &> /dev/null; then
    mst start > /dev/null 2>&1 || true
elif [ -f "/etc/init.d/mst" ]; then
    /etc/init.d/mst start > /dev/null 2>&1 || true
fi

DEVICES=(
    "/dev/mst/mt4131_pciconf0"
    "/dev/mst/mt4131_pciconf1"
    "/dev/mst/mt4131_pciconf2"
    "/dev/mst/mt4131_pciconf3"
)

MST_EXECUTED=false

if command -v mstdump &> /dev/null; then
    for dev in "${DEVICES[@]}"; do
        dev_name=$(basename "$dev")
        if [ -e "$dev" ]; then
            MST_EXECUTED=true
            echo "Starting mstdump for $dev (3 readings with 15-second intervals)..."
            
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log1.log" 2>&1
            sleep 15
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log2.log" 2>&1
            sleep 15
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log3.log" 2>&1
            
            echo -e "${GREEN}[OK] Device dump for $dev_name completed.${NC}"
        else
            echo -e "${RED}[WARNING] Device $dev not found on system.${NC}"
        fi
    done
else
    echo -e "${RED}[WARNING] Tool 'mstdump' (Mellanox MST) is not installed or available in PATH.${NC}"
fi

if [ "$MST_EXECUTED" = false ]; then
    echo "No MST dumps were collected. Please ensure MST/MFT package is installed and MST devices are loaded." > "${WORKDIR}/MSTDUMP_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 3. PCI DIAGNOSTICS, KERNEL & DCGM
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/4] Collecting lspci, dmesg, and system diagnostics...${NC}"

# iv. lspci -tv
if command -v lspci &> /dev/null; then
    lspci -tv > "${WORKDIR}/lspcitv.log" 2>&1 || true
    # v. lspci -vvvxxxx
    lspci -vvvxxxx > "${WORKDIR}/lspcivvvxxxx.log" 2>&1 || true
else
    echo -e "${RED}[WARNING] lspci not available.${NC}"
fi

# vi. dmesg
if command -v dmesg &> /dev/null; then
    dmesg -T > "${WORKDIR}/dmesg.log" 2>&1 || dmesg > "${WORKDIR}/dmesg.log" 2>&1 || true
fi

# vii. BMC Onekeylog / Ipmitool (if available)
if command -v ipmitool &> /dev/null; then
    echo "Collecting BMC logs via ipmitool..."
    ipmitool sel list > "${WORKDIR}/bmc_sel.log" 2>&1 || true
    ipmitool mc info > "${WORKDIR}/bmc_info.log" 2>&1 || true
fi

# Image Item 4: NVIDIA DCGM Diagnostic
if command -v dcgmi &> /dev/null; then
    echo "Running NVIDIA DCGM Diagnostic (dcgmi diag -r 3)..."
    dcgmi diag -r 3 > "${WORKDIR}/dcgmi_diag.log" 2>&1 || true
fi

echo -e "${GREEN}[OK] System diagnostics collected.${NC}"

# ------------------------------------------------------------------------------
# 4. COMPRESS LOG FILES (SAVED TO /root/support_$hostname_$date.zip)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/4] Generating compressed archive in /root...${NC}"

ZIP_FILENAME="support_${HOSTNAME}_${TIMESTAMP}.zip"
FINAL_OUTPUT="/root/${ZIP_FILENAME}"

cd "${WORKDIR}"

if command -v zip &> /dev/null; then
    zip -q -r "${FINAL_OUTPUT}" ./*
else
    # Fallback if zip utility fails completely
    FINAL_OUTPUT="/root/support_${HOSTNAME}_${TIMESTAMP}.tar.gz"
    tar -czf "${FINAL_OUTPUT}" ./*
fi

# Clean up temporary working directory
rm -rf "${WORKDIR}" /tmp/sysinfo_extracted 2>/dev/null || true

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}   LOG COLLECTION COMPLETED SUCCESSFULLY!           ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Final output archive: ${YELLOW}${FINAL_OUTPUT}${NC}"
if [ -f "${FINAL_OUTPUT}" ]; then
    echo -e "Archive size: $(du -sh "${FINAL_OUTPUT}" | cut -f1)"
fi
echo -e "\nAttach the file above directly to your Zendesk ticket."
