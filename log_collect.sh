#!/bin/bash
# ==============================================================================
# Fail-Safe Auto-Install Diagnostic Log Collection Script for GPU / Mellanox
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
echo -e "${GREEN}   Starting Full Auto-Install GPU / System Log Collect ${NC}"
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
# AUTOMATIC DEPENDENCY INSTALLATION
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[+] Checking and installing base OS dependencies...${NC}"

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
        fi
    fi
}

# Install core system utilities
install_package "lspci" "pciutils" "pciutils"
install_package "zip" "zip" "zip"
install_package "unzip" "unzip" "unzip"
install_package "python3" "python3" "python3"
install_package "wget" "wget" "wget"
install_package "curl" "curl" "curl"
install_package "git" "git" "git"

# ------------------------------------------------------------------------------
# AUTO-INSTALL MELLANOX SOFTWARE TOOLS (mstdump) IF MISSING
# ------------------------------------------------------------------------------
if ! command -v mstdump &> /dev/null && ! command -v mst &> /dev/null; then
    echo -e "
${YELLOW}[+] Mellanox tools missing. Attempting automatic installation...${NC}"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y -qq mstflint || true
    elif [ "$PKG_MANAGER" = "dnf" ]; then
        dnf install -y -q mstflint || dnf install -y -q mft || true
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install -y -q mstflint || yum install -y -q mft || true
    fi
fi

# ------------------------------------------------------------------------------
# 1. SYSINFO SNAPSHOT (linux-sysinfo-snapshot) - AUTO DOWNLOAD & RUN
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[1/4] Setting up and running Sysinfo Snapshot...${NC}"

SYSINFO_BIN=""

# Check local PATH first
if command -v sysinfo-snapshot.py &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot.py)
elif command -v sysinfo-snapshot &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot)
elif [ -f "./sysinfo-snapshot.py" ]; then
    SYSINFO_BIN="./sysinfo-snapshot.py"
fi

# If not present, download directly from GitHub
if [ -z "$SYSINFO_BIN" ]; then
    echo "Downloading sysinfo-snapshot automatically from GitHub..."
    mkdir -p /tmp/sysinfo_download
    
    # Download zip or clone repo
    if wget -q https://github.com/Mellanox/linux-sysinfo-snapshot/archive/refs/heads/master.zip -O /tmp/sysinfo_download/sysinfo.zip 2>/dev/null; then
        unzip -q -o /tmp/sysinfo_download/sysinfo.zip -d /tmp/sysinfo_download/
        SYSINFO_BIN=$(find /tmp/sysinfo_download -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    elif git clone --depth 1 https://github.com/Mellanox/linux-sysinfo-snapshot.p.git /tmp/sysinfo_download/repo 2>/dev/null; then
        SYSINFO_BIN=$(find /tmp/sysinfo_download/repo -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    fi
fi

if [ -n "$SYSINFO_BIN" ] && [ -f "$SYSINFO_BIN" ]; then
    echo "Executing: python3 $SYSINFO_BIN --gpu"
    python3 "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || true
    
    # Collect output files
    find /tmp . -maxdepth 2 -name "sysinfo-snapshot*" -not -path "${WORKDIR}/*" -exec mv {} "${WORKDIR}/" \; 2>/dev/null || true
    echo -e "${GREEN}[OK] Sysinfo snapshot completed.${NC}"
else
    echo -e "${RED}[WARNING] Could not auto-download sysinfo-snapshot. Skipping...${NC}"
    echo "Sysinfo snapshot tool download failed. Ensure outbound internet access." > "${WORKDIR}/SYSINFO_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 2. CX8 MST DUMP (Mellanox Software Tools)
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[2/4] Running CX8 MST Dumps...${NC}"

# Start MST service if present
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

# Support both official 'mstdump' and open-source fallback 'mstflint'
DUMP_CMD=""
if command -v mstdump &> /dev/null; then
    DUMP_CMD="mstdump"
elif command -v mstflint &> /dev/null; then
    DUMP_CMD="mstflint -d"
fi

if [ -n "$DUMP_CMD" ]; then
    for dev in "${DEVICES[@]}"; do
        dev_name=$(basename "$dev")
        if [ -e "$dev" ]; then
            MST_EXECUTED=true
            echo "Starting dump for $dev using '$DUMP_CMD' (3 readings with 15-second intervals)..."
            
            $DUMP_CMD "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log1.log" 2>&1
            sleep 15
            $DUMP_CMD "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log2.log" 2>&1
            sleep 15
            $DUMP_CMD "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log3.log" 2>&1
            
            echo -e "${GREEN}[OK] Device dump for $dev_name completed.${NC}"
        else
            echo -e "${RED}[WARNING] Device $dev not found on system.${NC}"
        fi
    done
else
    echo -e "${RED}[WARNING] Neither 'mstdump' nor 'mstflint' are available on this system.${NC}"
fi

if [ "$MST_EXECUTED" = false ]; then
    echo "No MST dumps were collected. Devices $DEVICES were not present or driver missing." > "${WORKDIR}/MSTDUMP_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 3. PCI DIAGNOSTICS, KERNEL & DCGM
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[3/4] Collecting lspci, dmesg, and system diagnostics...${NC}"

# iv. lspci -tv
if command -v lspci &> /dev/null; then
    lspci -tv > "${WORKDIR}/lspcitv.log" 2>&1 || true
    # v. lspci -vvvxxxx
    lspci -vvvxxxx > "${WORKDIR}/lspcivvvxxxx.log" 2>&1 || true
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

# Item 4: NVIDIA DCGM Diagnostic
if command -v dcgmi &> /dev/null; then
    echo "Running NVIDIA DCGM Diagnostic (dcgmi diag -r 3)..."
    dcgmi diag -r 3 > "${WORKDIR}/dcgmi_diag.log" 2>&1 || true
fi

echo -e "${GREEN}[OK] System diagnostics collected.${NC}"

# ------------------------------------------------------------------------------
# 4. COMPRESS LOG FILES (SAVED TO /root/support_$hostname_$date.zip)
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[4/4] Generating compressed archive in /root...${NC}"

ZIP_FILENAME="support_${HOSTNAME}_${TIMESTAMP}.zip"
FINAL_OUTPUT="/root/${ZIP_FILENAME}"

cd "${WORKDIR}"

if command -v zip &> /dev/null; then
    zip -q -r "${FINAL_OUTPUT}" ./*
else
    FINAL_OUTPUT="/root/support_${HOSTNAME}_${TIMESTAMP}.tar.gz"
    tar -czf "${FINAL_OUTPUT}" ./*
fi

# Cleanup temporary download and build areas
rm -rf "${WORKDIR}" /tmp/sysinfo_download 2>/dev/null || true

echo -e "
${GREEN}====================================================${NC}"
echo -e "${GREEN}   LOG COLLECTION COMPLETED SUCCESSFULLY!           ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Final output archive: ${YELLOW}${FINAL_OUTPUT}${NC}"
if [ -f "${FINAL_OUTPUT}" ]; then
    echo -e "Archive size: $(du -sh "${FINAL_OUTPUT}" | cut -f1)"
fi
echo -e "
Attach the file above directly to your Zendesk ticket."
