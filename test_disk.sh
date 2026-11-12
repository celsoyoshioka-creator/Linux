
#!/usr/bin/env bash

# ==============================================================================
# Linux Disk Homologation Tool
# Version : 2.0
# OS      : Ubuntu Server 22.04 / 24.04 LTS
# Arch    : x86_64
# Purpose : Enterprise Disk Homologation
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="2.0"

LOG_BASE="/var/log/disk-homologation"
RUN_DIR=""
LOG_FILE=""
SUMMARY_FILE=""

FILE_SIZE="1G"
QUICK_TIME=10
EXTENDED_TIME=60
STRESS_TIME=180

SELECTED_DISK=""

# ==============================================================================
# COLORS
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==============================================================================
# LOGGING
# ==============================================================================

log() {
    local level="$1"
    shift

    local message="$*"
    local timestamp

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    printf '[%s] [%-5s] %s\n' \
        "$timestamp" "$level" "$message"
}

info() {
    log INFO "$@"
}

success() {
    log PASS "$@"
}

warning() {
    log WARN "$@"
}

error() {
    log ERROR "$@" >&2
}

fatal_error() {
    error "$@"
    exit 1
}

trap 'error "Unexpected failure at line $LINENO: $BASH_COMMAND"' ERR

pause_menu() {
    echo
    read -r -p "Press ENTER to continue..."
}

# ==============================================================================
# INITIALIZATION
# ==============================================================================

check_environment() {

    if [[ "$EUID" -ne 0 ]]; then
        echo "ERROR: Run this script as root."
        echo "Usage: sudo bash $0"
        exit 1
    fi

    if [[ ! -f /etc/os-release ]]; then
        fatal_error "Cannot identify operating system."
    fi

    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        fatal_error "This version supports Ubuntu only."
    fi

    case "${VERSION_ID:-}" in
        22.04|24.04)
            ;;
        *)
            fatal_error "Unsupported Ubuntu version: ${VERSION_ID:-unknown}"
            ;;
    esac

    if [[ "$(uname -m)" != "x86_64" ]]; then
        warning "This script was designed for x86_64."
    fi

    mkdir -p "$LOG_BASE"

    RUN_DIR="$LOG_BASE/$(date '+%Y%m%d_%H%M%S')_$$"

    mkdir -p "$RUN_DIR"

    LOG_FILE="$RUN_DIR/execution.log"
    SUMMARY_FILE="$RUN_DIR/summary.txt"

    touch "$LOG_FILE" "$SUMMARY_FILE"

    exec > >(tee -a "$LOG_FILE") 2>&1

    info "Linux Disk Homologation Tool v$VERSION"
    info "Operating system: Ubuntu $VERSION_ID"
    info "Kernel: $(uname -r)"
    info "Architecture: $(uname -m)"
    info "Results directory: $RUN_DIR"

    {
        echo "LINUX DISK HOMOLOGATION REPORT"
        echo "=========================================="
        echo "Version: $VERSION"
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "OS: Ubuntu $VERSION_ID"
        echo "Kernel: $(uname -r)"
        echo "Architecture: $(uname -m)"
        echo
    } >> "$SUMMARY_FILE"

    install_dependencies
}

# ==============================================================================
# DEPENDENCIES
# ==============================================================================

install_dependencies() {

    local packages=(
        smartmontools
        fio
        hdparm
        util-linux
        nvme-cli
        lsscsi
        sg3-utils
        mdadm
        lvm2
        jq
        pciutils
    )

    info "Updating APT package database..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    info "Installing dependencies..."

    apt-get install -y "${packages[@]}"

    local cmd

    for cmd in lsblk smartctl fio hdparm blockdev \
               nvme jq lsscsi mdadm pvs lvs; do

        if ! command -v "$cmd" >/dev/null 2>&1; then
            warning "Command unavailable: $cmd"
        fi

    done

    success "Dependency installation completed."
}

# ==============================================================================
# DISK INVENTORY
# ==============================================================================

get_disks() {

    mapfile -t DISKS < <(
        lsblk -dnpo NAME,TYPE |
        awk '$2 == "disk" {print $1}'
    )

}

list_disks() {

    echo
    echo "=============================================================="
    echo " PHYSICAL DISKS"
    echo "=============================================================="

    lsblk -d -e 7,11 \
        -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,ROTA,TYPE

    echo
}

disk_inventory() {

    local output="$RUN_DIR/disk_inventory.txt"

    info "Collecting physical disk inventory..."

    {
        echo "PHYSICAL DISK INVENTORY"
        echo "======================="
        lsblk -e 7,11 \
            -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,ROTA,TYPE,FSTYPE,MOUNTPOINTS

        echo
        echo "BLOCK DEVICE DETAILS"
        echo "===================="
        lsblk -d -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,TRAN,ROTA,TYPE

        echo
        echo "SCSI DEVICES"
        echo "============"
        lsscsi -g 2>&1 || true

        echo
        echo "PCI STORAGE CONTROLLERS"
        echo "======================="
        lspci -nnk | grep -i -A3 -E \
            'SATA|SAS|RAID|Non-Volatile|NVMe|Mass storage' || true

        echo
        echo "NVME DEVICES"
        echo "============"
        nvme list 2>&1 || true

    } | tee "$output"

    success "Inventory saved: $output"
}

# ==============================================================================
# DISK SELECTION
# ==============================================================================

select_disk() {

    get_disks

    if [[ ${#DISKS[@]} -eq 0 ]]; then
        warning "No physical disks found."
        return 1
    fi

    echo
    echo "=============================================================="
    echo " SELECT PHYSICAL DISK"
    echo "=============================================================="

    local i=1
    local disk

    for disk in "${DISKS[@]}"; do

        printf "%2d - %s | " "$i" "$disk"

        lsblk -dnro SIZE,MODEL,SERIAL "$disk" |
            tr '\n' ' '

        echo

        ((i+=1))

    done

    echo

    local selection

    read -r -p "Select disk number: " selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]]; then
        warning "Invalid selection."
        return 1
    fi

    if (( selection < 1 || selection > ${#DISKS[@]} )); then
        warning "Invalid disk number."
        return 1
    fi

    SELECTED_DISK="${DISKS[$((selection-1))]}"

    info "Selected device: $SELECTED_DISK"

    return 0
}

# ==============================================================================
# DISK IDENTIFICATION
# ==============================================================================

disk_details() {

    local disk="$1"

    echo
    echo "=============================================================="
    echo " DEVICE INFORMATION: $disk"
    echo "=============================================================="

    lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,TRAN,ROTA,TYPE,FSTYPE,MOUNTPOINTS "$disk"

    echo

    echo "Device capacity:"
    blockdev --getsize64 "$disk" | numfmt --to=iec

    echo
    echo "Device properties:"

    udevadm info --query=property --name="$disk" |
        grep -E 'ID_MODEL=|ID_SERIAL=|ID_WWN=|ID_BUS=|ID_ATA|ID_PATH=' ||
        true

    echo
}

# ==============================================================================
# SAFETY CHECKS
# ==============================================================================

disk_is_protected() {

    local disk="$1"
    local node
    local mountpoints
    local swap_device
    local holder
    local node_name
    local swap_real
    local node_real

    while IFS= read -r node; do

        # Check mounted filesystems, including child partitions.

        mountpoints=$(lsblk -nro MOUNTPOINTS "$node" 2>/dev/null || true)

        if [[ -n "${mountpoints//[[:space:]]/}" ]]; then
            warning "Protected: $node has mounted filesystem(s):"
            echo "$mountpoints"
            return 0
        fi

        # Check active swap devices.

        node_real=$(readlink -f "$node")

        while IFS= read -r swap_device; do

            [[ -n "$swap_device" ]] || continue

            swap_real=$(readlink -f "$swap_device" 2>/dev/null || true)

            if [[ -n "$swap_real" && "$swap_real" == "$node_real" ]]; then
                warning "Protected: $node is used as swap."
                return 0
            fi

        done < <(
            swapon --noheadings --raw --output NAME 2>/dev/null || true
        )

        # Check RAID, device mapper and other holders.

        node_name=$(basename "$node")

        for holder in /sys/class/block/"$node_name"/holders/*; do

            if [[ -e "$holder" ]]; then
                warning "Protected: $node has active holder: $(basename "$holder")"
                return 0
            fi

        done

    done < <(lsblk -nrpo NAME "$disk")

    return 1
}

verify_block_device() {

    local disk="$1"

    if [[ ! -b "$disk" ]]; then
        error "Invalid block device: $disk"
        return 1
    fi

    if [[ "$(lsblk -dnro TYPE "$disk")" != "disk" ]]; then
        error "Only physical disk devices are accepted: $disk"
        return 1
    fi

    return 0
}

# ==============================================================================
# SMART DIAGNOSTICS
# ==============================================================================

smart_test() {

    local disk="$1"
    local name
    local output
    local nvme_controller
    local rc=0

    verify_block_device "$disk" || return 1

    name=$(basename "$disk")
    output="$RUN_DIR/smart_${name}.txt"

    info "Starting SMART diagnostics for $disk"

    disk_details "$disk"

    echo
    echo "=============================================================="
    echo " SMART DIAGNOSTICS"
    echo "=============================================================="

    smartctl -x "$disk" > "$output" 2>&1 || rc=$?

    cat "$output"

    if (( rc != 0 )); then
        warning "smartctl returned code $rc. Review the complete output."
        echo "SMART_EXIT_CODE=$rc" >> "$SUMMARY_FILE"
    fi

    # NVMe-specific diagnostics.

    if [[ "$name" =~ ^nvme[0-9]+n[0-9]+$ ]]; then

        nvme_controller=$(echo "$name" | sed -E 's/n[0-9]+$//')

        echo
        echo "=============================================================="
        echo " NVME HEALTH INFORMATION"
        echo "=============================================================="

        nvme smart-log "/dev/$nvme_controller" \
            2>&1 | tee "$RUN_DIR/nvme_${name}_health.txt" || true

        nvme id-ctrl "/dev/$nvme_controller" \
            2>&1 | tee "$RUN_DIR/nvme_${name}_controller.txt" || true

    fi

    echo
    echo "=============================================================="
    echo " SMART SUMMARY"
    echo "=============================================================="

    grep -Ei \
        'overall-health|SMART Health Status|Reallocated_Sector|Current_Pending|Offline_Uncorrectable|UDMA_CRC|Temperature:|Power_On_Hours|Critical Warning|Percentage Used|Available Spare|Media and Data Integrity Errors|Error Information Log Entries' \
        "$output" || true

    {
        echo
        echo "SMART DEVICE: $disk"
        echo "SMART REPORT: $output"
        echo "SMART EXIT CODE: $rc"
    } >> "$SUMMARY_FILE"

    success "SMART diagnostics saved."

}

# ==============================================================================
# FIO EXECUTION
# ==============================================================================

fio_job() {

    local target="$1"
    local tag="$2"
    local rw="$3"
    local bs="$4"
    local depth="$5"
    local runtime="$6"
    local mix="${7:-}"
    local is_raw="${8:-false}"

    local name
    local json
    local -a extra=()

    name=$(basename "$target")
    json="$RUN_DIR/fio_${name}_${tag}.json"

    if [[ -n "$mix" ]]; then
        extra+=(--rwmixread="$mix")
    fi

    info "FIO: $tag | RW=$rw | BS=$bs | QD=$depth | Runtime=${runtime}s"

    local -a command_args=(
        --name="$tag"
        --filename="$target"
        --rw="$rw"
        --bs="$bs"
        --ioengine=libaio
        --iodepth="$depth"
        --numjobs=1
        --direct=1
        --time_based
        --runtime="$runtime"
        --ramp_time=3
        --group_reporting
        --randrepeat=0
        --norandommap=1
        --refill_buffers=1
        --output-format=json
        --output="$json"
    )

    if [[ "$is_raw" == "true" ]]; then
        local bytes
        bytes=$(blockdev --getsize64 "$target")
        command_args+=(--size="$bytes")
    else
        command_args+=(--size="$FILE_SIZE")
    fi

    fio "${command_args[@]}" "${extra[@]}"

    if [[ -s "$json" ]]; then

        echo
        echo "FIO RESULTS: $tag"

        jq -r '
        .jobs[] |
        "READ  : IOPS=\(.read.iops|floor) BW=\(.read.bw_bytes|(. / 1048576)|floor) MB/s",
        "WRITE : IOPS=\(.write.iops|floor) BW=\(.write.bw_bytes|(. / 1048576)|floor) MB/s",
        "READ LATENCY  p99: \((.read.clat_ns.percentile["99.000000"] // 0) / 1000000) ms",
        "WRITE LATENCY p99: \((.write.clat_ns.percentile["99.000000"] // 0) / 1000000) ms"
        ' "$json" || true

    fi

    {
        echo
        echo "FIO TEST: $tag"
        echo "TARGET: $target"
        echo "MODE: $rw"
        echo "BLOCK SIZE: $bs"
        echo "IODEPTH: $depth"
        echo "RUNTIME: $runtime"
        echo "JSON: $json"
    } >> "$SUMMARY_FILE"

    success "FIO test completed: $tag"
}

# ==============================================================================
# NON-DESTRUCTIVE PERFORMANCE TESTS
# ==============================================================================

file_performance_test() {

    local disk_dir
    local test_dir
    local test_file
    local duration
    local mode

    echo
    echo "=============================================================="
    echo " NON-DESTRUCTIVE PERFORMANCE TEST"
    echo "=============================================================="

    echo "Tests use a temporary file in an existing filesystem."
    echo "The physical device and existing partitions are not overwritten."
    echo

    read -r -p "Directory for test file (e.g. /mnt/storage): " disk_dir

    if [[ ! -d "$disk_dir" ]]; then
        error "Directory does not exist."
        return 1
    fi

    if [[ ! -w "$disk_dir" ]]; then
        error "Directory is not writable."
        return 1
    fi

    local available_kb
    available_kb=$(df -Pk "$disk_dir" | awk 'NR==2 {print $4}')

    if [[ ! "$available_kb" =~ ^[0-9]+$ ]] ||
       (( available_kb < 1572864 )); then
        error "At least 1.5 GiB of free space is required."
        return 1
    fi

    echo
    echo "1 - Quick test (10 seconds per workload)"
    echo "2 - Extended test (60 seconds per workload)"
    echo "3 - Stress test (180 seconds)"
    read -r -p "Select profile: " mode

    case "$mode" in
        1) duration=$QUICK_TIME ;;
        2) duration=$EXTENDED_TIME ;;
        3) duration=$STRESS_TIME ;;
        *)
            warning "Invalid profile."
            return 1
            ;;
    esac

    test_dir=$(mktemp -d "$disk_dir/.disk-homologation.XXXXXX")
    test_file="$test_dir/testfile.bin"

    info "Temporary test file: $test_file"
    info "Profile runtime: $duration seconds"

    {
        echo
        echo "NON-DESTRUCTIVE TEST"
        echo "DIRECTORY: $disk_dir"
        echo "DURATION: $duration"
    } >> "$SUMMARY_FILE"

    # Initialize test file with sequential writes.

    fio_job "$test_file" "file_seq_write" write 1M 32 "$duration"

    fio_job "$test_file" "file_seq_read" read 1M 32 "$duration"

    if [[ "$mode" != "3" ]]; then

        fio_job "$test_file" "file_rand_read" randread 4k 64 "$duration"

        fio_job "$test_file" "file_rand_write" randwrite 4k 64 "$duration"

        fio_job "$test_file" "file_mixed_70_30" randrw 4k 64 "$duration" 70

        fio_job "$test_file" "file_latency_qd1" randread 4k 1 "$duration"

    else

        fio_job "$test_file" "file_stress_4k" randrw 4k 32 "$duration" 70

    fi

    rm -rf -- "$test_dir"

    success "Non-destructive performance testing completed."
}

# ==============================================================================
# DESTRUCTIVE TESTS
# ==============================================================================

destructive_test() {

    local disk="$1"
    local serial
    local confirmation
    local duration

    verify_block_device "$disk" || return 1

    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "                 DESTRUCTIVE DISK TEST"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    disk_details "$disk"

    if disk_is_protected "$disk"; then
        error "Operation blocked: device is mounted, active or in use."
        return 1
    fi

    serial=$(lsblk -dnro SERIAL "$disk" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -z "$serial" ]]; then
        error "Cannot obtain serial number. Destructive test refused."
        return 1
    fi

    echo
    echo "WARNING:"
    echo "All data on $disk can be destroyed."
    echo "Partition tables and filesystem metadata may be overwritten."
    echo
    echo "Device: $disk"
    echo "Serial: $serial"
    echo

    read -r -p "Type the EXACT serial number to continue: " confirmation

    if [[ "$confirmation" != "$serial" ]]; then
        warning "Serial confirmation failed. Test aborted."
        return 1
    fi

    # Recheck immediately before destructive operations.

    if disk_is_protected "$disk"; then
        error "Device became protected. Operation aborted."
        return 1
    fi

    echo
    echo "1 - Quick test (30 seconds)"
    echo "2 - Extended test (60 seconds)"

    read -r -p "Select profile: " confirmation

    case "$confirmation" in
        1) duration=30 ;;
        2) duration=60 ;;
        *)
            warning "Invalid selection."
            return 1
            ;;
    esac

    echo
    warning "FINAL CONFIRMATION: ALL DATA WILL BE DESTROYED."

    read -r -p "Type DESTROY to proceed: " confirmation

    if [[ "$confirmation" != "DESTROY" ]]; then
        warning "Test aborted."
        return 1
    fi

    # Final safety check.

    if disk_is_protected "$disk"; then
        error "Device is now protected. Aborting."
        return 1
    fi

    info "Starting destructive tests on $disk"

    {
        echo
        echo "DESTRUCTIVE TEST"
        echo "DEVICE: $disk"
        echo "SERIAL: $serial"
        echo "WARNING: DATA DESTRUCTION AUTHORIZED"
    } >> "$SUMMARY_FILE"

    fio_job "$disk" "raw_seq_write" write 1M 32 "$duration" "" true

    fio_job "$disk" "raw_seq_read" read 1M 32 "$duration" "" true

    fio_job "$disk" "raw_randrw_70_30" randrw 4k 64 "$duration" 70 true

    success "Destructive performance tests completed."
}

# ==============================================================================
# RAID AND LVM DIAGNOSTICS
# ==============================================================================

storage_diagnostics() {

    local output="$RUN_DIR/storage_diagnostics.txt"

    info "Collecting RAID and LVM information..."

    {
        echo "MDADM STATUS"
        echo "============"
        cat /proc/mdstat

        echo
        echo "MDADM ARRAYS"
        echo "============"
        mdadm --detail --scan 2>&1 || true

        echo
        echo "PHYSICAL VOLUMES"
        echo "================"
        pvs 2>&1 || true

        echo
        echo "VOLUME GROUPS"
        echo "============="
        vgs 2>&1 || true

        echo
        echo "LOGICAL VOLUMES"
        echo "==============="
        lvs -a -o +devices 2>&1 || true

        echo
        echo "DEVICE MAPPER"
        echo "============="
        lsblk -e 7,11 -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS

    } | tee "$output"

    success "Storage diagnostics saved."
}

# ==============================================================================
# GENERATE FINAL REPORT
# ==============================================================================

generate_report() {

    local output="$RUN_DIR/final_report.txt"

    {
        echo "=============================================================="
        echo " LINUX DISK HOMOLOGATION - FINAL REPORT"
        echo "=============================================================="

        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo "Ubuntu: $(. /etc/os-release && echo "$VERSION_ID")"

        echo
        echo "PHYSICAL DISKS"
        echo "=============="

        lsblk -d -e 7,11 \
            -o NAME,SIZE,MODEL,SERIAL,TRAN,ROTA

        echo
        echo "SMART STATUS"
        echo "============"

        for file in "$RUN_DIR"/smart_*.txt; do

            [[ -f "$file" ]] || continue

            echo
            echo "FILE: $(basename "$file")"

            grep -Ei \
                'overall-health|SMART Health Status|Critical Warning|Percentage Used|Media and Data Integrity Errors|Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable' \
                "$file" || true

        done

        echo
        echo "FIO RESULTS"
        echo "==========="

        for file in "$RUN_DIR"/fio_*.json; do

            [[ -f "$file" ]] || continue

            echo
            echo "FILE: $(basename "$file")"

            jq -r '
                .jobs[] |
                "READ IOPS: \(.read.iops|floor)",
                "WRITE IOPS: \(.write.iops|floor)",
                "READ BW: \((.read.bw_bytes/1048576)|floor) MB/s",
                "WRITE BW: \((.write.bw_bytes/1048576)|floor) MB/s"
            ' "$file" 2>/dev/null || true

        done

        echo
        echo "GENERATED FILES"
        echo "==============="

        find "$RUN_DIR" -maxdepth 1 -type f -printf '%f\n'

        echo
        echo "=============================================================="
        echo " END OF REPORT"
        echo "=============================================================="

    } | tee "$output"

    success "Final report generated: $output"

    echo
    echo "All results are available in:"
    echo "$RUN_DIR"
}

# ==============================================================================
# MAIN MENU
# ==============================================================================

main_menu() {

    while true; do

        echo
        echo "=============================================================="
        echo "          LINUX DISK HOMOLOGATION TOOL v$VERSION"
        echo "=============================================================="

        echo " 1 - Disk Inventory"
        echo " 2 - SMART & Health Diagnostics"
        echo " 3 - Non-Destructive Performance Tests"
        echo " 4 - Destructive Performance Tests"
        echo " 5 - Disk Stress Test"
        echo " 6 - RAID & LVM Diagnostics"
        echo " 7 - Generate Homologation Report"
        echo " 8 - Exit"

        echo "=============================================================="

        read -r -p "Select an option [1-8]: " option

        case "$option" in

            1)
                disk_inventory
                pause_menu
                ;;

            2)
                list_disks

                if select_disk; then
                    smart_test "$SELECTED_DISK"
                fi

                pause_menu
                ;;

            3)
                file_performance_test
                pause_menu
                ;;

            4)
                list_disks

                if select_disk; then
                    destructive_test "$SELECTED_DISK"
                fi

                pause_menu
                ;;

            5)
                file_performance_test
                pause_menu
                ;;

            6)
                storage_diagnostics
                pause_menu
                ;;

            7)
                generate_report
                pause_menu
                ;;

            8)
                info "Exiting Disk Homologation Tool."
                info "Results: $RUN_DIR"
                exit 0
                ;;

            *)
                warning "Invalid option. Select 1-8."
                ;;

        esac

    done
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {

    check_environment

    disk_inventory

    main_menu

}

main "$@"
