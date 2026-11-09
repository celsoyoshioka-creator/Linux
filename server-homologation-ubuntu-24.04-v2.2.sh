#!/usr/bin/env bash
#
# Server Hardware Homologation Suite
# Target: Ubuntu Server 24.04 LTS (Bash 5.x)
# Modules: inventory, disks, RAM, network (Broadcom/Mellanox), NVIDIA GPU/DCGM,
#          PCIe, DKMS, APT holds, reports.
#
# Safety defaults:
#   - No package installation, APT holds, firmware changes, reboot or power-cycle
#     is performed automatically.
#   - Disk performance tests use a temporary file on a mounted filesystem.
#   - Raw-device destructive FIO tests are intentionally not implemented.
#
# Usage:
#   sudo bash server-homologation.sh
#   sudo bash server-homologation.sh --help
#
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.2.3"
readonly TARGET_OS="Ubuntu 24.04 LTS"
readonly LOG_DIR="/var/log/hardware-homologation"
readonly REPORT_DIR="/var/log/hardware-homologation/reports"

RUN_ID="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE=""
REPORT_FILE=""
TEMP_FILES=()

# ---------- Output and logging ------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local level="$1"; shift
    printf '[%s] [%-5s] %s\n' "$(ts)" "$level" "$*" | tee -a "$LOG_FILE"
}

info()  { log INFO "$*"; }
warn()  { log WARN "$*"; }
error() { log ERROR "$*"; }

die() {
    error "$*"
    exit 1
}

cleanup() {
    local f
    for f in "${TEMP_FILES[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f -- "$f"
    done
}
trap cleanup EXIT

on_error() {
    local rc=$?
    local line="${BASH_LINENO[0]:-unknown}"
    error "Unexpected error on line ${line}; exit code ${rc}."
    error "See log: ${LOG_FILE:-not initialized}"
    exit "$rc"
}
trap on_error ERR

pause() {
    read -r -p $'\nPress ENTER to continue...' _ || true
}

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash ${SCRIPT_NAME}"
}

require_interactive_terminal() {
    # Read menu input from the controlling terminal, not from the script's
    # standard input. This supports: curl ... | sudo bash
    if [[ ! -e /dev/tty ]] || ! ( : </dev/tty ) 2>/dev/null; then
        printf '[ERROR] This interactive tool requires a controlling terminal.\n' >&2
        printf '[ERROR] Run it from an SSH/local terminal with a TTY allocated.\n' >&2
        exit 2
    fi
    exec </dev/tty
}

init_logging() {
    install -d -m 0750 "$LOG_DIR" "$REPORT_DIR" ||
        die "Could not create ${LOG_DIR}."
    LOG_FILE="${LOG_DIR}/homologation-${RUN_ID}.log"
    REPORT_FILE="${REPORT_DIR}/report-${RUN_ID}.txt"
    touch "$LOG_FILE" "$REPORT_FILE" || die "Could not create the log/report files."
    chmod 0640 "$LOG_FILE" "$REPORT_FILE"
    info "${SCRIPT_NAME} v${SCRIPT_VERSION} started."
}

report() {
    printf '%s\n' "$*" | tee -a "$REPORT_FILE" | tee -a "$LOG_FILE" >/dev/null
}

section() {
    local title="$1"
    printf '\n============================================================\n'
    printf ' %s\n' "$title"
    printf '============================================================\n'
    info "Starting: ${title}"
    {
        printf '\n============================================================\n'
        printf ' %s\n' "$title"
        printf '============================================================\n'
    } >> "$REPORT_FILE"
}

status_line() {
    local status="$1"; shift
    printf '[%s] %s\n' "$status" "$*"
    report "[$status] $*"
}

confirm_exact() {
    local expected="$1"
    local prompt="$2"
    local answer
    read -r -p "${prompt} Enter '${expected}' to confirm: " answer
    [[ "$answer" == "$expected" ]]
}

# ---------- Pre-flight and platform ------------------------------------------
check_platform() {
    section "PRE-FLIGHT / OPERATING SYSTEM"
    [[ -r /etc/os-release ]] || die "Could not identify the operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    printf 'System: %s\nVersion: %s\nKernel: %s\nArchitecture: %s\n' \
        "${PRETTY_NAME:-unknown}" "${VERSION_ID:-unknown}" "$(uname -r)" "$(uname -m)"
    report "System: ${PRETTY_NAME:-unknown}"
    report "Version: ${VERSION_ID:-unknown}"
    report "Kernel: $(uname -r)"
    report "Architecture: $(uname -m)"

    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "System not identified as Ubuntu. This script was designed for ${TARGET_OS}."
        status_line WARNING "Operating system is outside the recommended target."
    elif [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Ubuntu ${VERSION_ID:-unknown}; recommended target: 24.04 LTS."
        status_line WARNING "Ubuntu version differs from 24.04."
    else
        status_line PASS "Ubuntu 24.04 detected."
    fi

    for cmd in awk grep sed date tee install; do
        have "$cmd" || die "Required command is missing: $cmd"
    done
}

# ---------- Package helpers ---------------------------------------------------
package_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

installed_packages_matching() {
    local regex="$1"
    dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
        grep -E "$regex" || true
}

ensure_dependencies() {
    section "DEPENDENCIES"
    local commands=(lsblk findmnt smartctl fio hdparm lspci lshw ethtool iperf3
                    ipmitool memtester dmidecode dkms)
    local missing=()
    local cmd
    for cmd in "${commands[@]}"; do
        have "$cmd" || missing+=("$cmd")
    done

    if ((${#missing[@]} == 0)); then
        status_line PASS "All main optional commands are available."
        return
    fi

    printf 'Missing commands: %s\n' "${missing[*]}"
    status_line WARNING "Missing optional dependencies: ${missing[*]}"
    echo
    echo "The script does not install packages automatically."
    if confirm_exact INSTALL "Install the corresponding Ubuntu packages now?"; then
        have apt-get || die "apt-get not found."
        apt-get update
        apt-get install -y smartmontools fio hdparm util-linux pciutils lshw \
            ethtool iperf3 ipmitool memtester dmidecode dkms
        status_line PASS "Requested installation completed."
    else
        info "Dependency installation skipped by the operator."
    fi
}

# ---------- Inventory ---------------------------------------------------------
system_inventory() {
    section "SERVER INVENTORY"
    local cmd
    for cmd in hostnamectl lscpu free lsblk lspci; do
        if have "$cmd"; then
            printf '\n--- %s ---\n' "$cmd"
            case "$cmd" in
                hostnamectl) hostnamectl ;;
                lscpu) lscpu ;;
                free) free -h ;;
                lsblk) lsblk -e 7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,ROTA,TRAN,FSTYPE,MOUNTPOINTS ;;
                lspci) lspci -nn ;;
            esac
        fi
    done
    if have dmidecode; then
        printf '\n--- Manufacturer / model / BIOS ---\n'
        dmidecode -t system -t bios 2>/dev/null |
            grep -E 'Manufacturer:|Product Name:|Version:|Release Date:' || true
        printf '\n--- Physical memory (DIMMs) ---\n'
        dmidecode -t memory 2>/dev/null |
            grep -E 'Locator:|Bank Locator:|Size:|Manufacturer:|Part Number:|Speed:|Configured Memory Speed:' || true
    else
        warn "dmidecode is unavailable; SMBIOS inventory skipped."
    fi
}

# ---------- Disk module -------------------------------------------------------
list_disks() {
    section "PHYSICAL DISKS"
    lsblk -d -e 7 -o NAME,PATH,SIZE,MODEL,SERIAL,ROTA,TRAN,TYPE
}

disk_device_valid() {
    local dev="$1"
    [[ "$dev" == /dev/* && -b "$dev" ]]
}

disk_health() {
    local dev="$1"
    disk_device_valid "$dev" || { error "Invalid block device: $dev"; return 1; }
    section "SMART / DISK HEALTH: $dev"
    if ! have smartctl; then
        status_line WARNING "smartctl is not installed."
        return 0
    fi
    smartctl -H "$dev" || status_line WARNING "SMART returned a non-zero exit code for $dev."
    smartctl -x "$dev" || status_line WARNING "Could not retrieve all SMART data for $dev."
}

disk_is_busy() {
    local dev="$1"
    local base
    base="$(basename "$dev")"

    # Mounted partitions, swap, holders (mdraid, device-mapper/LVM), and root filesystem.
    if lsblk -nrpo MOUNTPOINT "$dev" | grep -q '[^[:space:]]'; then
        return 0
    fi
    if lsblk -nrpo NAME "$dev" | while read -r node; do
        [[ -n "$node" ]] && swapon --noheadings --raw --show=NAME 2>/dev/null |
            grep -Fxq "$node" && exit 0
    done; then
        return 0
    fi
    if [[ -d "/sys/class/block/${base}/holders" ]] &&
       compgen -G "/sys/class/block/${base}/holders/*" >/dev/null; then
        return 0
    fi

    local root_source
    root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ "$root_source" == "$dev" ]] && return 0

    # Do not allow a parent device of a root filesystem mounted on device-mapper/RAID.
    if lsblk -s -nrpo NAME "$root_source" 2>/dev/null | grep -Fxq "$dev"; then
        return 0
    fi
    return 1
}

disk_file_test() {
    local dev="$1"
    disk_device_valid "$dev" || { error "Invalid device: $dev"; return 1; }
    have fio || { error "fio is not installed."; return 1; }

    section "NON-DESTRUCTIVE FIO (FILE-BASED)"
    echo "The test writes to a temporary file inside a mounted filesystem."
    echo "It does not write directly to /dev, but it generates real I/O and consumes disk space."
    echo "For representative results, use a dedicated data volume."
    echo
    lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS "$dev"

    local mountpoint
    mountpoint="$(lsblk -nrpo MOUNTPOINT "$dev" | awk 'NF {print; exit}')"
    if [[ -z "$mountpoint" ]]; then
        warn "No mount point found for this device. Test cancelled."
        status_line NOT_TESTED "FIO not run: device has no mounted filesystem."
        return 1
    fi
    if [[ "$mountpoint" == "/" ]]; then
        warn "Testing on the root filesystem may affect the system and services."
        if ! confirm_exact ROOTFS "Confirm running the test on the root filesystem?"; then
            status_line NOT_TESTED "FIO cancelled by the operator."
            return 0
        fi
    fi

    local available_kb available_mb reserve_mb max_mb profile test_size_mb runtime rw_mode
    available_kb="$(df -Pk "$mountpoint" | awk 'NR==2 {print $4}')"
    [[ "$available_kb" =~ ^[0-9]+$ ]] || { error "Could not determine available free space."; return 1; }
    available_mb=$((available_kb / 1024))

    # Preserve at least 20% of free space. The limit also prevents test files
    # from becoming excessively large; the operator can choose a smaller size.
    reserve_mb=$((available_mb / 5))
    max_mb=$((available_mb - reserve_mb))
    (( max_mb > 102400 )) && max_mb=102400  # operational cap of 100 GiB
    if (( max_mb < 1024 )); then
        warn "Insufficient space: at least 1 GiB of test headroom is required."
        status_line NOT_TESTED "FIO cancelled: insufficient free space."
        return 1
    fi

    echo
    echo "Available space: ${available_mb} MiB"
    echo "Maximum allowed test size: ${max_mb} MiB (preserves at least 20% of free space; 100 GiB cap)."
    echo
    echo "Profiles:"
    echo "1 - Quick:       1 GiB, 30 seconds, randrw 4k 50/50"
    echo "2 - Estendido:   10 GiB, 120 seconds, randrw 4k 50/50"
    echo "3 - Stress:      50 GiB, 600 seconds, randrw 4k 50/50"
    echo "4 - Custom: specify size and duration"
    echo "5 - Cancel"
    read -r -p "Select profile: " profile

    case "$profile" in
        1) test_size_mb=1024; runtime=30; rw_mode=randrw ;;
        2) test_size_mb=10240; runtime=120; rw_mode=randrw ;;
        3) test_size_mb=51200; runtime=600; rw_mode=randrw ;;
        4)
            read -r -p "Test file size in MiB: " test_size_mb
            read -r -p "Duration in seconds (30 to 3600): " runtime
            [[ "$test_size_mb" =~ ^[1-9][0-9]*$ ]] ||
                { error "Invalid size."; return 1; }
            [[ "$runtime" =~ ^[0-9]+$ ]] && (( runtime >= 30 && runtime <= 3600 )) ||
                { error "Invalid duration (30 to 3600 seconds)."; return 1; }
            rw_mode=randrw
            ;;
        5) info "Test cancelled."; return 0 ;;
        *) error "Invalid profile."; return 1 ;;
    esac

    (( test_size_mb <= max_mb )) || {
        error "Profile/size exceeds the safe limit of ${max_mb} MiB for this filesystem."
        return 1
    }

    echo
    echo "Test summary:"
    echo "  Specified device: $dev"
    echo "  Mount point:     $mountpoint"
    echo "  Temporary file:            ${test_size_mb} MiB"
    echo "  Duration:               ${runtime} seconds"
    echo "  Pattern:                randrw 4k / 50% read and 50% write"
    echo
    echo "WARNING: although this is not a raw/destructive test, it writes data,"
    echo "consumes disk space, creates load, and may affect applications."
    if ! confirm_exact START-FIO "Enter START-FIO to start"; then
        status_line NOT_TESTED "FIO cancelled by the operator."
        return 0
    fi

    local test_file
    test_file="$(mktemp "${mountpoint%/}/.homologation-fio.XXXXXX")"
    TEMP_FILES+=("$test_file")
    info "Temporary file: $test_file"
    fio --name=homologation-randrw --filename="$test_file" \
        --size="${test_size_mb}M" --rw="$rw_mode" --rwmixread=50 --bs=4k \
        --ioengine=libaio --iodepth=32 --numjobs=1 --direct=1 \
        --time_based --runtime="$runtime" --group_reporting
    rm -f -- "$test_file"
    status_line PASS "FIO completed: ${test_size_mb} MiB / ${runtime}s on $mountpoint."
    info "Note: file-based testing evaluates the filesystem/storage path. For complete qualification, correlate results with vendor tests, RAID/HBA checks, and device metrics."
}

menu_disks() {
    while true; do
        echo
        echo "=== DISKS ==="
        echo "1 - List disks"
        echo "2 - SMART / disk health"
        echo "3 - File-based FIO (quick / extended / stress)"
        echo "4 - Back"
        read -r -p "Option: " opt
        case "$opt" in
            1) list_disks; pause ;;
            2)
                list_disks
                read -r -p "Device (e.g. /dev/sda or /dev/nvme0n1): " dev || {
                    warn "No input received. Returning to the disk menu."
                    continue
                }
                if [[ -z "${dev//[[:space:]]/}" ]]; then
                    warn "No device specified. Enter a device path such as /dev/nvme1n1."
                elif ! disk_health "$dev"; then
                    warn "SMART check could not be completed for: $dev"
                fi
                pause
                ;;
            3)
                list_disks
                read -r -p "Device containing the filesystem to test: " dev || {
                    warn "No input received. Returning to the disk menu."
                    continue
                }
                if [[ -z "${dev//[[:space:]]/}" ]]; then
                    warn "No device specified. Enter a device path such as /dev/nvme1n1."
                elif ! disk_file_test "$dev"; then
                    warn "File-based FIO could not be started for: $dev"
                fi
                pause
                ;;
            4) break ;;
            *) warn "Invalid option."; pause ;;
        esac
    done
}

# ---------- RAM module --------------------------------------------------------
ram_test() {
    section "RAM MEMORY TEST"
    have memtester || { error "memtester is not installed."; return 1; }
    free -h
    local available_kb max_mb requested loops reserve_mb
    available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    [[ "$available_kb" =~ ^[0-9]+$ ]] || { error "MemAvailable is unavailable."; return 1; }
    max_mb=$(( available_kb / 1024 ))
    reserve_mb=1024
    (( max_mb > reserve_mb )) && max_mb=$((max_mb - reserve_mb)) || max_mb=0

    echo "Approximate available memory: ${available_kb} KiB."
    echo "Suggested test limit: ${max_mb} MiB (reserva de 1 GiB)."
    read -r -p "Amount to test in MiB: " requested
    read -r -p "Number of passes: " loops
    [[ "$requested" =~ ^[1-9][0-9]*$ && "$loops" =~ ^[1-9][0-9]*$ ]] ||
        { error "Enter positive integers."; return 1; }
    (( requested <= max_mb )) ||
        { error "Requested amount exceeds the calculated limit (${max_mb} MiB)."; return 1; }
    (( loops <= 100 )) || { error "Safety limit: no more than 100 passes."; return 1; }

    if confirm_exact RUN "The test may put pressure on memory and affect services. Continue?"; then
        memtester "${requested}M" "$loops"
        status_line PASS "memtester completed without reporting errors."
    else
        status_line NOT_TESTED "RAM test cancelled."
    fi
}


memtest86_guidance() {
    section "MEMTEST86+ / OFFLINE RAM TEST"
    echo "memtester running inside Ubuntu only tests the memory that the"
    echo "process can allocate and does not replace a boot-time test."
    echo
    echo "For more comprehensive testing:"
    echo "  1. Plan a maintenance window and stop applications."
    echo "  2. Check whether the memtest86+ package is available for your release/architecture."
    echo "  3. Install it only after validating the server's package policy."
    echo "  4. Check the GRUB entries and confirm that the firmware/boot mode"
    echo "     (UEFI or Legacy) provides a Memtest86+ entry."
    echo "  5. Reboot during the approved maintenance window and select Memtest86+ from the boot menu."
    echo "  6. Run multiple complete passes; record the version, duration, and errors."
    echo "  7. Return to Ubuntu and attach the results to the qualification report."
    echo
    echo "Local checks (read-only):"
    if dpkg-query -W -f='${db:Status-Abbrev} ${Version}\n' memtest86+ 2>/dev/null | grep -q '^ii'; then
        dpkg-query -W -f='memtest86+ package: ${Version}\n' memtest86+ 2>/dev/null || true
    else
        echo "memtest86+ package: not installed."
    fi
    if [[ -d /sys/firmware/efi ]]; then
        echo "Current boot mode: UEFI"
    else
        echo "Current boot mode: Legacy BIOS or EFI mode is not exposed by the system."
    fi
    if have grub-reboot; then
        echo "GRUB detected. Check available entries with:"
        echo "  grep -i -E 'memtest|menuentry' /boot/grub/grub.cfg"
    fi
    echo
    status_line WARNING "Memtest86+ requires a reboot and testing outside Ubuntu; this tool does not schedule or perform the reboot."
}

menu_memory() {
    while true; do
        echo
        echo "=== RAM MEMORY ==="
        echo "1 - Show memory"
        echo "2 - Show DIMMs (dmidecode)"
        echo "3 - Run memtester (online test)"
        echo "4 - Memtest86+ guidance (boot/offline)"
        echo "5 - Back"
        read -r -p "Option: " opt
        case "$opt" in
            1) free -h; pause ;;
            2) have dmidecode && dmidecode -t memory || warn "dmidecode is unavailable."; pause ;;
            3) ram_test; pause ;;
            4) memtest86_guidance; pause ;;
            5) break ;;
            *) warn "Invalid option."; pause ;;
        esac
    done
}

# ---------- Network module ----------------------------------------------------
detect_network_pci() {
    section "PCI NETWORK CONTROLLERS"
    if ! have lspci; then
        warn "pciutils/lspci is unavailable."
        return 1
    fi
    lspci -nnk | grep -iEA3 'Ethernet controller|Network controller' || true
}

network_interfaces() {
    ip -br link
}

inspect_interface() {
    local iface="$1"
    ip link show dev "$iface" >/dev/null 2>&1 || { error "Interface does not exist: $iface"; return 1; }
    section "INTERFACE DIAGNOSTICS: $iface"
    ip -details link show dev "$iface"
    if have ethtool; then
        echo
        ethtool -i "$iface" || true
        echo
        ethtool "$iface" || true
        echo
        ethtool -k "$iface" || true
        echo
        ethtool -S "$iface" || true
    else
        warn "ethtool is not installed."
    fi

    local pci
    pci="$(basename "$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)")"
    if [[ "$pci" =~ ^[0-9a-fA-F]{4}: ]]; then
        echo
        lspci -vv -s "$pci" 2>/dev/null || true
    fi
}

network_iperf() {
    section "IPERF3 THROUGHPUT TEST"
    have iperf3 || { error "iperf3 is not installed."; return 1; }
    local server duration
    read -r -p "iperf3 server IP/hostname (-s): " server
    [[ -n "$server" ]] || { info "Test cancelled."; return 0; }
    read -r -p "Duration in seconds [10]: " duration
    duration="${duration:-10}"
    [[ "$duration" =~ ^[1-9][0-9]*$ ]] && (( duration <= 300 )) ||
        { error "Invalid duration (1 to 300 seconds)."; return 1; }
    iperf3 -c "$server" -t "$duration" --get-server-output
}

menu_network() {
    while true; do
        echo
        echo "=== NETWORK: BROADCOM / MELLANOX ==="
        echo "1 - Detect PCI network controllers"
        echo "2 - List interfaces"
        echo "3 - Inspect interface (driver, firmware, link, offload, counters, PCIe)"
        echo "4 - Throughput test (iperf3)"
        echo "5 - Back"
        read -r -p "Option: " opt
        case "$opt" in
            1) detect_network_pci; pause ;;
            2) network_interfaces; pause ;;
            3)
                network_interfaces
                read -r -p "Interface name: " iface
                inspect_interface "$iface"; pause ;;
            4) network_iperf; pause ;;
            5) break ;;
            *) warn "Invalid option."; pause ;;
        esac
    done
}

# ---------- NVIDIA / DCGM -----------------------------------------------------
gpu_diagnostics() {
    section "NVIDIA GPU DIAGNOSTICS"
    if ! have nvidia-smi; then
        status_line NOT_TESTED "nvidia-smi not found; the NVIDIA driver may not be installed or loaded."
        lspci -nn | grep -i nvidia || true
        return 1
    fi
    nvidia-smi -L
    echo
    nvidia-smi
    echo
    nvidia-smi -q
    echo
    nvidia-smi topo -m || true

    if have dcgmi; then
        echo
        echo "--- DCGM discovery ---"
        dcgmi discovery -l || status_line WARNING "DCGM discovery retornou erro."
        echo
        echo "--- DCGM diagnostic level 1 ---"
        echo "Diagnostics may run additional checks and consume GPU resources."
        if confirm_exact DCGM "Run dcgmi diag -r 1?"; then
            dcgmi diag -r 1
            status_line PASS "DCGM diagnostic level 1 completed."
        else
            status_line NOT_TESTED "DCGM diagnostics not run."
        fi
    else
        status_line WARNING "dcgmi not found; DCGM diagnostics are unavailable."
    fi
}

menu_gpu() {
    while true; do
        echo
        echo "=== NVIDIA GPU ==="
        echo "1 - Detect NVIDIA GPUs on PCIe"
        echo "2 - nvidia-smi / DCGM diagnostics"
        echo "3 - Back"
        read -r -p "Option: " opt
        case "$opt" in
            1) lspci -nn | grep -iE 'VGA|3D|Display|NVIDIA' || true; pause ;;
            2) gpu_diagnostics; pause ;;
            3) break ;;
            *) warn "Invalid option."; pause ;;
        esac
    done
}

# ---------- PCIe and DKMS -----------------------------------------------------
pcie_inventory() {
    section "PCIe INVENTORY"
    if have lspci; then
        lspci -Dnn
        echo
        echo "Negotiated link speed/width summary (when exposed by the kernel):"
        local d path
        while read -r d; do
            [[ -n "$d" ]] || continue
            path="/sys/bus/pci/devices/$d"
            [[ -r "$path/current_link_speed" ]] || continue
            printf '%s: speed=%s width=%s\n' "$d" \
                "$(cat "$path/current_link_speed" 2>/dev/null || echo unknown)" \
                "$(cat "$path/current_link_width" 2>/dev/null || echo unknown)"
        done < <(lspci -D | awk '{print $1}')
    else
        warn "lspci is unavailable."
    fi
}

dkms_status() {
    section "STATUS DKMS"
    if have dkms; then
        dkms status || status_line WARNING "dkms status retornou erro."
    else
        status_line NOT_TESTED "DKMS is not installed."
    fi
    echo
    echo "Relevant loaded modules:"
    lsmod | grep -E 'bnxt_en|mlx5_core|nvidia|nvidia_uvm|nvidia_drm' || true
    echo
    echo "Related installed packages:"
    dpkg-query -W -f='${binary:Package} ${Version}\n' 2>/dev/null |
        grep -Ei 'bnxt|broadcom|mlx|mellanox|nvidia|cuda|dcgm|linux-(image|headers)' || true
}

# ---------- APT hold management ----------------------------------------------
show_holds() {
    section "APT-HELD PACKAGES"
    apt-mark showhold || true
}

hold_matching_packages() {
    local label="$1" regex="$2"
    local packages
    mapfile -t packages < <(installed_packages_matching "$regex")
    if ((${#packages[@]} == 0)); then
        info "No installed packages found for: $label"
        return 0
    fi
    printf 'Matching packages (%s):\n' "$label"
    printf '  %s\n' "${packages[@]}"
    if confirm_exact HOLD "Apply apt-mark hold to these packages only?"; then
        apt-mark hold "${packages[@]}"
        status_line PASS "Hold applied to group: $label."
    else
        info "Hold cancelled for: $label"
    fi
}

unhold_matching_packages() {
    local label="$1" regex="$2"
    local packages
    mapfile -t packages < <(installed_packages_matching "$regex")
    if ((${#packages[@]} == 0)); then
        info "No installed packages found for: $label"
        return 0
    fi
    printf 'Installed matching packages (%s):\n' "$label"
    printf '  %s\n' "${packages[@]}"
    if confirm_exact UNHOLD "Remove the hold from these packages, if currently held?"; then
        apt-mark unhold "${packages[@]}" || true
        status_line PASS "Unhold request completed for: $label."
    else
        info "Unhold cancelled for: $label"
    fi
}

menu_system() {
    while true; do
        echo
        echo "=== SYSTEM / DRIVERS / KERNEL ==="
        echo "1 - Show held packages"
        echo "2 - Hold installed NVIDIA/CUDA/DCGM packages"
        echo "3 - Hold installed Broadcom/Mellanox packages"
        echo "4 - Hold the current kernel image/headers packages"
        echo "5 - Unhold NVIDIA/CUDA/DCGM packages"
        echo "6 - Unhold Broadcom/Mellanox packages"
        echo "7 - Unhold the current kernel image/headers packages"
        echo "8 - DKMS status and loaded modules"
        echo "9 - Back"
        read -r -p "Option: " opt
        case "$opt" in
            1) show_holds; pause ;;
            2) hold_matching_packages "NVIDIA/CUDA/DCGM" '^(nvidia-|libnvidia-|cuda-|libcuda|datacenter-gpu-manager|dcgm)'; pause ;;
            3) hold_matching_packages "Broadcom/Mellanox" '^(bnxt|firmware-bnx2|firmware-brcm|broadcom-sta|mlnx|mellanox|mstflint|ofed)'; pause ;;
            4)
                local k
                k="$(uname -r)"
                hold_matching_packages "current kernel ${k}" "^linux-(image|headers)(-unsigned)?-${k//./\\.}($|-)"
                pause ;;
            5) unhold_matching_packages "NVIDIA/CUDA/DCGM" '^(nvidia-|libnvidia-|cuda-|libcuda|datacenter-gpu-manager|dcgm)'; pause ;;
            6) unhold_matching_packages "Broadcom/Mellanox" '^(bnxt|firmware-bnx2|firmware-brcm|broadcom-sta|mlnx|mellanox|mstflint|ofed)'; pause ;;
            7)
                local k
                k="$(uname -r)"
                unhold_matching_packages "current kernel ${k}" "^linux-(image|headers)(-unsigned)?-${k//./\\.}($|-)"
                pause ;;
            8) dkms_status; pause ;;
            9) break ;;
            *) warn "Invalid option."; pause ;;
        esac
    done
}

# ---------- Report and summary ------------------------------------------------
generate_summary() {
    section "FINAL SUMMARY"
    {
        echo "Host: $(hostname -f 2>/dev/null || hostname)"
        echo "Date: $(ts)"
        echo "System: ${PRETTY_NAME:-unknown}"
        echo "Kernel: $(uname -r)"
        echo "Script: ${SCRIPT_VERSION}"
        echo
        echo "Files:"
        echo "Log: ${LOG_FILE}"
        echo "Report: ${REPORT_FILE}"
        echo
        echo "Note: modules that were not run must be considered NOT TESTED,"
        echo "not PASS. Qualification depends on vendor and project criteria."
    } | tee -a "$REPORT_FILE"
    info "Report available at: ${REPORT_FILE}"
}

# ---------- Main menu ---------------------------------------------------------
main_menu() {
    while true; do
        echo
        echo "============================================================"
        echo " SERVER HARDWARE HOMOLOGATION SUITE v${SCRIPT_VERSION}"
        echo "============================================================"
        echo " 1 - Full server inventory"
        echo " 2 - Disks (SMART / non-destructive FIO)"
        echo " 3 - RAM (DIMM / memtester)"
        echo " 4 - Network (Broadcom / Mellanox)"
        echo " 5 - GPU (NVIDIA / DCGM)"
        echo " 6 - PCIe inventory"
        echo " 7 - System / Drivers / Kernel / APT Holds / DKMS"
        echo " 8 - View summary and report paths"
        echo " 9 - Check dependencies / install after confirmation"
        echo " 0 - Exit"
        echo "------------------------------------------------------------"
        read -r -p "Select: " opt
        case "$opt" in
            1) system_inventory; pause ;;
            2) menu_disks ;;
            3) menu_memory ;;
            4) menu_network ;;
            5) menu_gpu ;;
            6) pcie_inventory; pause ;;
            7) menu_system ;;
            8) generate_summary; pause ;;
            9) ensure_dependencies; pause ;;
            0) generate_summary; info "Execution ended by the operator."; exit 0 ;;
            *) warn "Invalid option."; pause ;;
        esac
    done
}

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Interactive hardware qualification tool for Ubuntu Server 24.04.

Usage:
  sudo bash ${SCRIPT_NAME}

Logs:
  ${LOG_DIR}

Reports:
  ${REPORT_DIR}

For safety, the script does not perform raw disk writes, firmware changes,
reboots, power cycles, or automatic package installation at startup.

FIO: provides 1, 10, and 50 GiB profiles, limited by reserving 20% of free space
and by a 100 GiB cap. Testing is file-based and does not replace raw-device
validation in a dedicated environment.

RAM: memtester is a user-space test. For comprehensive passes, use Memtest86+
or a bootable diagnostic tool approved for the hardware.
EOF
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi
    require_root
    require_interactive_terminal
    init_logging
    check_platform
    main_menu
}

main "$@"
