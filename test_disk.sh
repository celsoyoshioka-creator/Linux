#!/bin/bash

# ==============================================================================
# Linux Disk Homologation Script
# Target OS: Ubuntu
# ==============================================================================

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root. Please use sudo."
  exit 1
fi

echo "=================================================="
echo " Checking and installing dependencies..."
echo "=================================================="
# Update package list and install required tools
apt-get update -qq
apt-get install -y smartmontools fio hdparm util-linux > /dev/null 2>&1
echo "Dependencies (smartmontools, fio, hdparm) installed successfully."
sleep 1

# Function to list all available disks
function list_disks() {
    echo ""
    echo "Available Disks:"
    echo "--------------------------------------------------"
    # Lists disks excluding partitions, showing NAME, SIZE, MODEL, and TYPE
    lsblk -d -o NAME,SIZE,MODEL,TYPE | grep disk
    echo "--------------------------------------------------"
}

# Function to perform a detailed health/SMART test
function test_health() {
    local disk_name="$1"
    local target="/dev/$disk_name"
    
    if [ ! -b "$target" ]; then
        echo "ERROR: Disk $target not found."
        return
    fi

    echo ""
    echo "=================================================="
    echo " Detailed Health & SMART Test for $target"
    echo "=================================================="
    # -x prints all available SMART information
    smartctl -x "$target"
    echo "=================================================="
}

# Function to perform Read/Write performance testing
function rw_test() {
    local disk_name="$1"
    local target="/dev/$disk_name"

    if [ ! -b "$target" ]; then
        echo "ERROR: Disk $target not found."
        return
    fi

    echo ""
    echo "=================================================="
    echo " DANGER: READ/WRITE PERFORMANCE TEST ON $target"
    echo "=================================================="
    echo "WARNING: This test will perform direct block WRITE operations."
    echo "ALL DATA ON '$target' WILL BE PERMANENTLY DESTROYED."
    echo "Do NOT run this on your boot drive or disks with important data."
    echo ""
    read -p "Are you ABSOLUTELY sure you want to proceed? Type 'YES' to continue: " confirm

    if [ "$confirm" == "YES" ]; then
        echo ""
        echo "Starting Performance Tests on $target..."
        
        echo ""
        echo "--- 1. Sequential Read Test (Cache & Buffered Disk Reads) ---"
        hdparm -tT "$target"

        echo ""
        echo "--- 2. Random Read/Write Test (fio - 50% Read / 50% Write) ---"
        echo "Running a 30-second random R/W test with 4k block size..."
        # FIO configuration for rigorous server disk homologation
        fio --name=homologation_test \
            --filename="$target" \
            --rw=randrw \
            --rwmixread=50 \
            --bs=4k \
            --ioengine=libaio \
            --iodepth=64 \
            --numjobs=1 \
            --direct=1 \
            --time_based \
            --runtime=30 \
            --group_reporting
            
        echo "=================================================="
        echo " Read/Write Test Completed for $target."
        echo "=================================================="
    else
        echo "Test aborted by user. No data was written."
    fi
}

# Main Menu Loop
while true; do
    echo ""
    echo "=================================================="
    echo " DISK HOMOLOGATION MENU"
    echo "=================================================="
    echo " 1 - List and test all disks (Health/SMART Check)"
    echo " 2 - List and choose a disk to test (Health/SMART Check)"
    echo " 3 - List and perform a Read/Write performance test (Destructive)"
    echo " 4 - Exit"
    echo "=================================================="
    read -p "Select an option [1-4]: " opt

    case $opt in
        1)
            # Get only the names of the devices of type 'disk'
            disks=$(lsblk -nd -o NAME,TYPE | awk '$2=="disk"{print $1}')
            if [ -z "$disks" ]; then
                echo "No disks found on this system."
            else
                for d in $disks; do
                    test_health "$d"
                done
            fi
            read -p "Press [Enter] to return to the menu..."
            ;;
        2)
            list_disks
            read -p "Enter the disk name to test (e.g., sda, nvme0n1): " selected_disk
            test_health "$selected_disk"
            read -p "Press [Enter] to return to the menu..."
            ;;
        3)
            list_disks
            read -p "Enter the disk name for R/W test (e.g., sda, nvme0n1): " selected_disk
            rw_test "$selected_disk"
            read -p "Press [Enter] to return to the menu..."
            ;;
        4)
            echo "Exiting Disk Homologation Tool. Goodbye!"
            exit 0
            ;;
        *)
            echo "Invalid option. Please choose a number between 1 and 4."
            ;;
    esac
done
