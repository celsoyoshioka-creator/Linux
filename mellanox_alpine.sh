Bash
#!/bin/sh

# ==============================================================================
# BOOTSTRAP SCRIPT (Runs in native Alpine 'sh')
# This ensures Bash is installed before interpreting the rest of the code,
# as Alpine Linux uses 'ash' (BusyBox) by default, which lacks some advanced features.
# ==============================================================================

echo "============================================================"
echo " Initializing Environment (Preparing Bash)..."
echo "============================================================"
# Silently update the package index and install bash
apk update >/dev/null 2>&1
apk add --no-cache bash >/dev/null 2>&1

# Create a secure temporary file to run the advanced Bash code
BASH_SCRIPT="/tmp/setup_mellanox_core.bash"

# Everything between 'EOF_BASH' will be written to the temporary Bash script
cat << 'EOF_BASH' > "$BASH_SCRIPT"
#!/bin/bash

# Abort the script immediately if any command returns a non-zero exit status (unhandled errors)
set -e

# Function to pause execution and clear the input buffer, waiting for user action
pause_for_user() {
    echo ""
    echo "============================================================"
    echo "⏸️  [PAUSED - MANUAL ACTION REQUIRED]"
    echo -e "   $1"
    echo "============================================================"
    printf "Press [ENTER] as soon as you finish to continue..."
    # Read from /dev/tty ensures we get user input even if stdin is redirected
    read -r unused < /dev/tty
    echo ""
}

# Root Privilege Check: Ensures the user running the script has UID 0 (root)
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ This script MUST be run as root."
    exit 1
fi

echo "✅ Bash initialized successfully. Starting process..."
echo "============================================================"
echo " 1. Checking Connectivity and Host IP"
echo "============================================================"

# Attempts to find the primary IP address used to route traffic to the internet (1.1.1.1)
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
# Fallback: if the above fails, try to get the IP from the hostname command
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
fi
echo "Detected host IP: ${HOST_IP}"

echo "============================================================"
echo " 2. Configuring Repositories and Installing Dependencies"
echo "============================================================"

# Overwrite Alpine repositories to force version 3.20 (ensures stable/expected package versions)
cat > /etc/apk/repositories << 'EOF'
http://dl-cdn.alpinelinux.org/alpine/v3.20/main
http://dl-cdn.alpinelinux.org/alpine/v3.20/community
EOF

echo "Updating system and installing build dependencies..."
# Upgrade existing packages
apk update && apk upgrade

# Install required packages for compiling software, networking, and IPMI management
apk add --no-cache \
    ca-certificates wget tar gzip ipmitool \
    alpine-sdk autoconf automake libtool bison flex pkgconfig \
    linux-headers musl-dev gcompat \
    zlib zlib-dev openssl openssl-dev \
    pciutils pciutils-dev libpciaccess libpciaccess-dev \
    rdma-core rdma-core-dev \
    ccache git

# Update local SSL certificates
update-ca-certificates

echo "============================================================"
echo " 3. Compiling MSTFLINT with Patches for Musl libc"
echo "============================================================"
# Move to /root directory and remove any previous mstflint folder to start fresh
cd /root
rm -rf mstflint

# Clone the Mellanox mstflint repository from GitHub (depth 1 saves time/bandwidth)
git clone --depth 1 https://github.com/Mellanox/mstflint.git
cd mstflint

echo "Applying compatibility patches to source code..."
# Alpine uses 'musl libc' instead of 'glibc'. This sed command finds legacy data types 
# (like u_int8_t) and replaces them with standard C99 types (uint8_t) across all source files.
find . -type f \( -name '*.c' -o -name '*.h' -o -name '*.cpp' -o -name '*.hpp' \) -exec sed -i \
    -e 's/u_int8_t/uint8_t/g' \
    -e 's/u_int16_t/uint16_t/g' \
    -e 's/u_int32_t/uint32_t/g' \
    -e 's/u_int64_t/uint64_t/g' {} +

# Add the <stdint.h> library import to a specific header file to fix a known compilation error
sed -i '/#include <sys\/types.h>/a #include <stdint.h>' include/mtcr_ul/mtcr_com_defs.h

# Generate configure scripts, create build directory, and configure with OpenSSL support
./autogen.sh
mkdir build && cd build
../configure --enable-openssl

# Fix for zlib: Sometimes Alpine places libz.so where the configure script can't find it.
# This searches for it and creates a symlink in /usr/lib/ if necessary.
if ! ls /usr/lib/libz.so >/dev/null 2>&1; then
    ZLIB_LIB=$(find /usr/lib /lib -name "libz.so*" 2>/dev/null | head -n 1)
    if [ -n "$ZLIB_LIB" ]; then
        echo "Adjusting libz symlink: $ZLIB_LIB"
        ln -sf "$ZLIB_LIB" /usr/lib/libz.so
    fi
fi

# Compile using all available CPU cores (-j nproc) and install the binaries
make -j"$(nproc)"
make install

# Verify if the installation was successful by checking if 'mstflint' command exists
if ! command -v mstflint >/dev/null 2>&1; then
    echo "❌ Critical Error: mstflint compilation failed!"
    exit 1
fi
echo "✅ mstflint compiled successfully! Version: $(mstflint -v | head -n 1)"

echo "============================================================"
echo " 4. Obtaining and Selecting Firmware File (.bin)"
echo "============================================================"

echo "Please provide the name or path of the firmware file."
printf "Name/Path to the .bin file [/root/cx5fw.bin]: "
read -r FW_FILE < /dev/tty

# Set default path if user presses Enter without typing anything
if [ -z "$FW_FILE" ]; then
    FW_FILE="/root/cx5fw.bin"
fi

# If the file does not exist, pause and show instructions on how to upload it via SCP
if [ ! -f "$FW_FILE" ]; then
    echo ""
    echo "❌ The file '$FW_FILE' was not found on this server."
    
    SCP_INSTRUCTIONS="The firmware file (.bin) needs to be sent from your computer to this Alpine server.\n"
    SCP_INSTRUCTIONS+="   Follow these detailed steps on WINDOWS:\n\n"
    SCP_INSTRUCTIONS+="   1. Open the Windows Start menu, type 'PowerShell', and press Enter.\n"
    SCP_INSTRUCTIONS+="   2. Copy the command below, but replace the path 'C:\\path\\to\\your_file.bin'\n"
    SCP_INSTRUCTIONS+="      with the exact location where the firmware is saved on your PC (e.g., Downloads).\n\n"
    SCP_INSTRUCTIONS+="      Command to run in PowerShell:\n"
    SCP_INSTRUCTIONS+="      scp \"C:\\path\\to\\your_file.bin\" root@${HOST_IP}:${FW_FILE}\n\n"
    SCP_INSTRUCTIONS+="   3. Press Enter in PowerShell. If asked 'Are you sure you want to continue connecting (yes/no)?', type 'yes' and press Enter.\n"
    SCP_INSTRUCTIONS+="   4. Type the root password for this Alpine server.\n"
    SCP_INSTRUCTIONS+="   5. Wait for the upload to reach 100% before returning to this screen."

    pause_for_user "$SCP_INSTRUCTIONS"
fi

# Ensure the file exists and is not empty (0 bytes) after the pause
if [ ! -s "$FW_FILE" ]; then
    echo "❌ The file $FW_FILE does not exist or is empty (0 bytes)!"
    echo "Make sure the SCP transfer completed successfully and run the script again."
    exit 1
fi

# Query the firmware file using mstflint to extract its metadata
FILE_QUERY=$(mstflint -i "$FW_FILE" q 2>/dev/null || true)

# If the query returns empty, the file is not a valid Mellanox firmware
if [ -z "$FILE_QUERY" ]; then
    echo "❌ The file $FW_FILE is an invalid or corrupted firmware!"
    exit 1
fi

# Extract the Parameter Set ID (PSID) and Firmware Version using grep and awk
FILE_PSID=$(echo "$FILE_QUERY" | grep -i "PSID:" | awk '{print $2}')
FILE_FW_VER=$(echo "$FILE_QUERY" | grep -i "FW Version:" | awk '{print $3}')

echo ""
echo "✅ Firmware file read successfully!"
echo "   - File: $FW_FILE"
echo "   - Firmware PSID: $FILE_PSID"
echo "   - Firmware Version in File: $FILE_FW_VER"

echo "============================================================"
echo " 5. Filtering Eligible Cards for Update"
echo "============================================================"

# Find all PCI devices manufactured by Mellanox (Vendor ID: 15b3)
PCI_DEVS=$(lspci -d 15b3: | awk '{print $1}')

if [ -z "$PCI_DEVS" ]; then
    echo "❌ No Mellanox cards (PCI ID 15b3) were found on the bus!"
    exit 1
fi

# Using native Bash Arrays for safe mapping of eligible devices and their current firmwares
ELIGIBLE_DEVS=()
ELIGIBLE_FWS=()

# Loop through each Mellanox PCI device found
for DEV in $PCI_DEVS; do
    # Query the card hardware directly
    CARD_QUERY=$(mstflint -d "$DEV" q 2>/dev/null || true)
    CARD_PSID=$(echo "$CARD_QUERY" | grep -i "PSID:" | awk '{print $2}' || echo "N/A")
    CARD_FW_VER=$(echo "$CARD_QUERY" | grep -i "FW Version:" | awk '{print $3}' || echo "N/A")

    # A card is only eligible if its PSID matches the file's PSID AND its version is different
    if [ "$CARD_PSID" = "$FILE_PSID" ] && [ "$CARD_FW_VER" != "$FILE_FW_VER" ]; then
        ELIGIBLE_DEVS+=("$DEV")
        ELIGIBLE_FWS+=("$CARD_FW_VER")
    else
        echo " ℹ️ Card $DEV skipped (PSID: $CARD_PSID | Current FW: $CARD_FW_VER) -> Already updated or incompatible."
    fi
done

# Count how many eligible cards were found
COUNT=${#ELIGIBLE_DEVS[@]}

if [ "$COUNT" -eq 0 ]; then
    echo ""
    echo "✅ All cards compatible with PSID $FILE_PSID are already on version $FILE_FW_VER."
    echo "No pending updates!"
    exit 0
fi

echo ""
echo "============================================================"
echo " 6. Select Card to Update"
echo "============================================================"
echo "Select ONE card to apply the update:"
echo ""

# Display a numbered menu with eligible cards
for i in "${!ELIGIBLE_DEVS[@]}"; do
    NUM=$((i + 1))
    echo "  $NUM) PCI Address: ${ELIGIBLE_DEVS[$i]} (Current FW: ${ELIGIBLE_FWS[$i]} ➔ New FW: $FILE_FW_VER)"
done

echo ""
printf "Enter the number of the desired card (1-$COUNT) or '0' to cancel: "
read -r OPTION < /dev/tty

# Handle user input logic
if [ "$OPTION" -eq 0 ] 2>/dev/null; then
    echo "Operation canceled by the user."
    exit 0
fi

# Ensure the selected option is a valid number within range
if [ "$OPTION" -lt 1 ] 2>/dev/null || [ "$OPTION" -gt "$COUNT" ] 2>/dev/null; then
    echo "❌ Invalid option! Exiting."
    exit 1
fi

# Map user choice (1-based index) back to the array (0-based index)
SELECTED_INDEX=$((OPTION - 1))
SELECTED_DEV="${ELIGIBLE_DEVS[$SELECTED_INDEX]}"

PAUSE_MSG_3="Ready to burn the firmware to card $SELECTED_DEV.\n   Writing to hardware is IRREVERSIBLE while executing."

pause_for_user "$PAUSE_MSG_3"

echo "============================================================"
echo " 7. Burning Firmware and Enabling Option ROM"
echo "============================================================"

echo "Executing firmware burn on card $SELECTED_DEV..."
# The actual command that flashes the firmware to the Mellanox card (-y auto-confirms prompts)
mstflint -d "$SELECTED_DEV" -i "$FW_FILE" -y burn

echo "Configuring BIOS Boot support (Option ROM PXE/UEFI)..."
# Enables network booting features (PXE for legacy BIOS and UEFI)
mstconfig -d "$SELECTED_DEV" set EXP_ROM_PXE_ENABLE=1 EXP_ROM_UEFI_x86_ENABLE=1 -y

# Sets both ports to Ethernet mode (LINK_TYPE=2). InfiniBand would be LINK_TYPE=1.
# Suppresses errors if the card is an Ethernet-only (EN) card that doesn't support changing link types.
mstconfig -d "$SELECTED_DEV" set LINK_TYPE_P1=2 LINK_TYPE_P2=2 -y 2>/dev/null || \
    echo "Info: Card is fixed Ethernet (EN). LINK_TYPE parameters successfully ignored."

echo "✅ Card $SELECTED_DEV updated successfully!"

echo "============================================================"
echo " 8. Operation Completed - Power Cycle / Reboot"
echo "============================================================"

printf "Do you want to perform a Power Cycle via IPMI now? (y/N): "
read -r ANSWER < /dev/tty

# Handle IPMI remote reboot logic
case "$ANSWER" in
    [Yy]* )
        printf "BMC/IPMI IP: "
        read -r BMC_IP < /dev/tty
        printf "IPMI User: "
        read -r BMC_USER < /dev/tty
        printf "IPMI Password: "
        stty -echo # Hide password input
        read -r BMC_PASS < /dev/tty
        stty echo  # Restore terminal echo
        echo ""
        echo "Sending Chassis Power Cycle command via IPMI..."
        # Uses ipmitool over LAN to forcefully power cycle the physical chassis
        ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" chassis power cycle
        ;;
    * )
        echo "Run 'reboot' or perform a Power Cycle manually via IPMI so the BIOS loads the new firmware."
        ;;
esac

echo "✅ Process finished successfully!"
EOF_BASH

# ==============================================================================
# Execute the protected Bash script and, upon completion, remove the temporary file
# ==============================================================================
bash "$BASH_SCRIPT"
rm -f "$BASH_SCRIPT"
