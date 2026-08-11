#!/bin/bash
#
# Fix NVIDIA DKMS build using GCC 14
# Oracle Linux 9 / UEK
#

set -euo pipefail

NVIDIA_VERSION="610.57.04"
KERNEL_VERSION="6.12.0-204.92.4.4.el9uek.x86_64"

GCC_PATH="/opt/rh/gcc-toolset-14/root/usr/bin/gcc"
DKMS_CONF_DIR="/etc/dkms/framework.conf.d"
DKMS_CONF_FILE="${DKMS_CONF_DIR}/gcc14.conf"


echo "=============================================="
echo " NVIDIA DKMS GCC14 Fix"
echo "=============================================="
echo

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run this script as root"
    exit 1
fi


echo "[1/5] Checking Oracle Linux version..."

if ! grep -qi "Oracle Linux" /etc/os-release; then
    echo "WARNING: This does not appear to be Oracle Linux."
fi


echo
echo "[2/5] Installing GCC Toolset 14..."

dnf install -y \
    gcc-toolset-14-gcc \
    gcc-toolset-14-gcc-c++


if [ ! -x "${GCC_PATH}" ]; then
    echo "ERROR: GCC 14 binary not found:"
    echo "${GCC_PATH}"
    exit 1
fi


echo
echo "GCC version:"
${GCC_PATH} --version | head -1


echo
echo "[3/5] Configuring DKMS to use GCC 14..."

mkdir -p "${DKMS_CONF_DIR}"

cat > "${DKMS_CONF_FILE}" <<EOF
CC=${GCC_PATH}
HOSTCC=${GCC_PATH}
EOF

echo "Created:"
echo "${DKMS_CONF_FILE}"

cat "${DKMS_CONF_FILE}"


echo
echo "[4/5] Removing failed NVIDIA DKMS build..."

if dkms status | grep -q "nvidia/${NVIDIA_VERSION}"; then
    dkms remove "nvidia/${NVIDIA_VERSION}" --all || true
else
    echo "NVIDIA DKMS ${NVIDIA_VERSION} not registered."
fi


echo
echo "[5/5] Rebuilding NVIDIA DKMS module..."

if [ ! -d "/usr/src/kernels/${KERNEL_VERSION}" ]; then
    echo "ERROR: Kernel headers not found:"
    echo "/usr/src/kernels/${KERNEL_VERSION}"
    exit 1
fi


dkms install \
    "nvidia/${NVIDIA_VERSION}" \
    -k "${KERNEL_VERSION}"


echo
echo "=============================================="
echo " DKMS build completed successfully"
echo "=============================================="

echo
echo "DKMS status:"
dkms status


echo
echo "Kernel modules:"
lsmod | grep nvidia || true


echo
echo "NOTE:"
echo "If no NVIDIA GPU is installed, nvidia-smi will still fail."
echo "The DKMS build success only confirms the kernel module compiled."
