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
readonly SCRIPT_VERSION="2.1.0"
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
    error "Falha inesperada na linha ${line}; código de saída ${rc}."
    error "Consulte o log: ${LOG_FILE:-não inicializado}"
    exit "$rc"
}
trap on_error ERR

pause() {
    read -r -p $'\nPressione ENTER para continuar...' _ || true
}

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Execute como root: sudo bash ${SCRIPT_NAME}"
}

init_logging() {
    install -d -m 0750 "$LOG_DIR" "$REPORT_DIR" ||
        die "Não foi possível criar ${LOG_DIR}."
    LOG_FILE="${LOG_DIR}/homologation-${RUN_ID}.log"
    REPORT_FILE="${REPORT_DIR}/report-${RUN_ID}.txt"
    touch "$LOG_FILE" "$REPORT_FILE" || die "Não foi possível criar os arquivos de log/relatório."
    chmod 0640 "$LOG_FILE" "$REPORT_FILE"
    info "${SCRIPT_NAME} v${SCRIPT_VERSION} iniciado."
}

report() {
    printf '%s\n' "$*" | tee -a "$REPORT_FILE" | tee -a "$LOG_FILE" >/dev/null
}

section() {
    local title="$1"
    printf '\n============================================================\n'
    printf ' %s\n' "$title"
    printf '============================================================\n'
    info "Iniciando: ${title}"
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
    read -r -p "${prompt} Digite '${expected}' para confirmar: " answer
    [[ "$answer" == "$expected" ]]
}

# ---------- Pre-flight and platform ------------------------------------------
check_platform() {
    section "PRE-FLIGHT / SISTEMA OPERACIONAL"
    [[ -r /etc/os-release ]] || die "Não foi possível identificar o sistema operacional."
    # shellcheck disable=SC1091
    source /etc/os-release
    printf 'Sistema: %s\nVersão: %s\nKernel: %s\nArquitetura: %s\n' \
        "${PRETTY_NAME:-unknown}" "${VERSION_ID:-unknown}" "$(uname -r)" "$(uname -m)"
    report "Sistema: ${PRETTY_NAME:-unknown}"
    report "Versão: ${VERSION_ID:-unknown}"
    report "Kernel: $(uname -r)"
    report "Arquitetura: $(uname -m)"

    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "Sistema não identificado como Ubuntu. O script foi projetado para ${TARGET_OS}."
        status_line WARNING "Sistema operacional fora do alvo recomendado."
    elif [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Ubuntu ${VERSION_ID:-desconhecido}; alvo recomendado: 24.04 LTS."
        status_line WARNING "Versão Ubuntu diferente de 24.04."
    else
        status_line PASS "Ubuntu 24.04 detectado."
    fi

    for cmd in awk grep sed date tee install; do
        have "$cmd" || die "Comando essencial ausente: $cmd"
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
    section "DEPENDÊNCIAS"
    local commands=(lsblk findmnt smartctl fio hdparm lspci lshw ethtool iperf3
                    ipmitool memtester dmidecode dkms)
    local missing=()
    local cmd
    for cmd in "${commands[@]}"; do
        have "$cmd" || missing+=("$cmd")
    done

    if ((${#missing[@]} == 0)); then
        status_line PASS "Todos os comandos opcionais principais estão disponíveis."
        return
    fi

    printf 'Comandos ausentes: %s\n' "${missing[*]}"
    status_line WARNING "Dependências opcionais ausentes: ${missing[*]}"
    echo
    echo "O script não instala pacotes automaticamente."
    if confirm_exact INSTALL "Deseja instalar os pacotes Ubuntu correspondentes agora?"; then
        have apt-get || die "apt-get não encontrado."
        apt-get update
        apt-get install -y smartmontools fio hdparm util-linux pciutils lshw \
            ethtool iperf3 ipmitool memtester dmidecode dkms
        status_line PASS "Instalação solicitada concluída."
    else
        info "Instalação de dependências ignorada pelo operador."
    fi
}

# ---------- Inventory ---------------------------------------------------------
system_inventory() {
    section "INVENTÁRIO DO SERVIDOR"
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
        printf '\n--- Fabricante / modelo / BIOS ---\n'
        dmidecode -t system -t bios 2>/dev/null |
            grep -E 'Manufacturer:|Product Name:|Version:|Release Date:' || true
        printf '\n--- Memória física (DIMMs) ---\n'
        dmidecode -t memory 2>/dev/null |
            grep -E 'Locator:|Bank Locator:|Size:|Manufacturer:|Part Number:|Speed:|Configured Memory Speed:' || true
    else
        warn "dmidecode não disponível; inventário SMBIOS omitido."
    fi
}

# ---------- Disk module -------------------------------------------------------
list_disks() {
    section "DISCOS FÍSICOS"
    lsblk -d -e 7 -o NAME,PATH,SIZE,MODEL,SERIAL,ROTA,TRAN,TYPE
}

disk_device_valid() {
    local dev="$1"
    [[ "$dev" == /dev/* && -b "$dev" ]]
}

disk_health() {
    local dev="$1"
    disk_device_valid "$dev" || { error "Dispositivo de bloco inválido: $dev"; return 1; }
    section "SMART / SAÚDE DO DISCO: $dev"
    if ! have smartctl; then
        status_line WARNING "smartctl não instalado."
        return 1
    fi
    smartctl -H "$dev" || status_line WARNING "SMART retornou código diferente de zero para $dev."
    smartctl -x "$dev" || status_line WARNING "Não foi possível obter todos os dados SMART de $dev."
}

disk_is_busy() {
    local dev="$1"
    local base
    base="$(basename "$dev")"

    # Partições montadas, swap, holders (mdraid, device-mapper/LVM) e root filesystem.
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

    # Não permitir dispositivo pai de uma raiz montada em device-mapper/RAID.
    if lsblk -s -nrpo NAME "$root_source" 2>/dev/null | grep -Fxq "$dev"; then
        return 0
    fi
    return 1
}

disk_file_test() {
    local dev="$1"
    disk_device_valid "$dev" || { error "Dispositivo inválido: $dev"; return 1; }
    have fio || { error "fio não instalado."; return 1; }

    section "FIO NÃO DESTRUTIVO (ARQUIVO)"
    echo "O teste grava em um arquivo temporário dentro de um filesystem montado."
    echo "Não grava diretamente em /dev, mas gera I/O real e consome espaço."
    echo "Para resultados representativos, prefira um volume de dados dedicado."
    echo
    lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS "$dev"

    local mountpoint
    mountpoint="$(lsblk -nrpo MOUNTPOINT "$dev" | awk 'NF {print; exit}')"
    if [[ -z "$mountpoint" ]]; then
        warn "Nenhum ponto de montagem encontrado no dispositivo. Teste cancelado."
        status_line NOT_TESTED "FIO não executado: dispositivo sem filesystem montado."
        return 1
    fi
    if [[ "$mountpoint" == "/" ]]; then
        warn "O teste no filesystem raiz pode afetar o sistema e serviços."
        if ! confirm_exact ROOTFS "Confirma executar o teste no filesystem raiz?"; then
            status_line NOT_TESTED "FIO cancelado pelo operador."
            return 0
        fi
    fi

    local available_kb available_mb reserve_mb max_mb profile test_size_mb runtime rw_mode
    available_kb="$(df -Pk "$mountpoint" | awk 'NR==2 {print $4}')"
    [[ "$available_kb" =~ ^[0-9]+$ ]] || { error "Não foi possível obter espaço livre."; return 1; }
    available_mb=$((available_kb / 1024))

    # Preserva pelo menos 20% do espaço livre. O limite também evita arquivos
    # descontroladamente grandes; o operador pode escolher um tamanho menor.
    reserve_mb=$((available_mb / 5))
    max_mb=$((available_mb - reserve_mb))
    (( max_mb > 102400 )) && max_mb=102400  # teto operacional de 100 GiB
    if (( max_mb < 1024 )); then
        warn "Espaço insuficiente: são necessários pelo menos 1 GiB de margem de teste."
        status_line NOT_TESTED "FIO cancelado: espaço livre insuficiente."
        return 1
    fi

    echo
    echo "Espaço livre: ${available_mb} MiB"
    echo "Tamanho máximo permitido: ${max_mb} MiB (preserva ao menos 20% do espaço livre; teto 100 GiB)."
    echo
    echo "Perfis:"
    echo "1 - Rápido:       1 GiB, 30 segundos, randrw 4k 50/50"
    echo "2 - Estendido:   10 GiB, 120 segundos, randrw 4k 50/50"
    echo "3 - Stress:      50 GiB, 600 segundos, randrw 4k 50/50"
    echo "4 - Personalizado: informar tamanho e duração"
    echo "5 - Cancelar"
    read -r -p "Selecione o perfil: " profile

    case "$profile" in
        1) test_size_mb=1024; runtime=30; rw_mode=randrw ;;
        2) test_size_mb=10240; runtime=120; rw_mode=randrw ;;
        3) test_size_mb=51200; runtime=600; rw_mode=randrw ;;
        4)
            read -r -p "Tamanho do arquivo de teste em MiB: " test_size_mb
            read -r -p "Duração em segundos (30 a 3600): " runtime
            [[ "$test_size_mb" =~ ^[1-9][0-9]*$ ]] ||
                { error "Tamanho inválido."; return 1; }
            [[ "$runtime" =~ ^[0-9]+$ ]] && (( runtime >= 30 && runtime <= 3600 )) ||
                { error "Duração inválida (30 a 3600 segundos)."; return 1; }
            rw_mode=randrw
            ;;
        5) info "Teste cancelado."; return 0 ;;
        *) error "Perfil inválido."; return 1 ;;
    esac

    (( test_size_mb <= max_mb )) || {
        error "Perfil/tamanho excede o limite seguro de ${max_mb} MiB para este filesystem."
        return 1
    }

    echo
    echo "Resumo do teste:"
    echo "  Dispositivo informado: $dev"
    echo "  Ponto de montagem:     $mountpoint"
    echo "  Arquivo temporário:    ${test_size_mb} MiB"
    echo "  Duração:               ${runtime} segundos"
    echo "  Padrão:                randrw 4k / 50% leitura e 50% gravação"
    echo
    echo "ATENÇÃO: apesar de não ser raw/destrutivo, o teste grava dados,"
    echo "consome espaço, gera carga e pode impactar aplicações."
    if ! confirm_exact START-FIO "Digite START-FIO para iniciar"; then
        status_line NOT_TESTED "FIO cancelado pelo operador."
        return 0
    fi

    local test_file
    test_file="$(mktemp "${mountpoint%/}/.homologation-fio.XXXXXX")"
    TEMP_FILES+=("$test_file")
    info "Arquivo temporário: $test_file"
    fio --name=homologation-randrw --filename="$test_file" \
        --size="${test_size_mb}M" --rw="$rw_mode" --rwmixread=50 --bs=4k \
        --ioengine=libaio --iodepth=32 --numjobs=1 --direct=1 \
        --time_based --runtime="$runtime" --group_reporting
    rm -f -- "$test_file"
    status_line PASS "FIO concluído: ${test_size_mb} MiB / ${runtime}s em $mountpoint."
    info "Nota: teste por arquivo avalia o caminho filesystem/storage; para homologação completa, correlacione com testes do fabricante, RAID/HBA e métricas do dispositivo."
}

menu_disks() {
    while true; do
        echo
        echo "=== DISCOS ==="
        echo "1 - Listar discos"
        echo "2 - SMART / saúde de um disco"
        echo "3 - FIO por arquivo (rápido / estendido / stress)"
        echo "4 - Voltar"
        read -r -p "Opção: " opt
        case "$opt" in
            1) list_disks; pause ;;
            2)
                list_disks
                read -r -p "Dispositivo (ex.: /dev/sda ou /dev/nvme0n1): " dev
                disk_health "$dev"; pause ;;
            3)
                list_disks
                read -r -p "Dispositivo que contém o filesystem a testar: " dev
                disk_file_test "$dev"; pause ;;
            4) break ;;
            *) warn "Opção inválida." ;;
        esac
    done
}

# ---------- RAM module --------------------------------------------------------
ram_test() {
    section "TESTE DE MEMÓRIA RAM"
    have memtester || { error "memtester não instalado."; return 1; }
    free -h
    local available_kb max_mb requested loops reserve_mb
    available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    [[ "$available_kb" =~ ^[0-9]+$ ]] || { error "MemAvailable indisponível."; return 1; }
    max_mb=$(( available_kb / 1024 ))
    reserve_mb=1024
    (( max_mb > reserve_mb )) && max_mb=$((max_mb - reserve_mb)) || max_mb=0

    echo "Memória disponível aproximada: ${available_kb} KiB."
    echo "Limite sugerido para o teste: ${max_mb} MiB (reserva de 1 GiB)."
    read -r -p "Quantidade em MiB para testar: " requested
    read -r -p "Número de ciclos: " loops
    [[ "$requested" =~ ^[1-9][0-9]*$ && "$loops" =~ ^[1-9][0-9]*$ ]] ||
        { error "Informe números inteiros positivos."; return 1; }
    (( requested <= max_mb )) ||
        { error "Quantidade excede o limite calculado (${max_mb} MiB)."; return 1; }
    (( loops <= 100 )) || { error "Limite de segurança: no máximo 100 ciclos."; return 1; }

    if confirm_exact RUN "O teste pode pressionar a memória e afetar serviços. Deseja continuar?"; then
        memtester "${requested}M" "$loops"
        status_line PASS "memtester terminou sem reportar erro."
    else
        status_line NOT_TESTED "Teste de RAM cancelado."
    fi
}


memtest86_guidance() {
    section "MEMTEST86+ / TESTE DE RAM FORA DO SISTEMA OPERACIONAL"
    echo "O memtester executado dentro do Ubuntu testa somente a memória que o"
    echo "processo consegue alocar e não substitui um teste de boot."
    echo
    echo "Para um teste mais abrangente:"
    echo "  1. Planeje uma janela de manutenção e encerre as aplicações."
    echo "  2. Verifique se o pacote memtest86+ está disponível para sua versão/arquitetura."
    echo "  3. Instale-o somente após validar a política de pacotes do servidor."
    echo "  4. Verifique as entradas do GRUB e confirme que o firmware/boot mode"
    echo "     (UEFI ou Legacy) oferece uma entrada Memtest86+."
    echo "  5. Reinicie em janela autorizada e selecione Memtest86+ no menu de boot."
    echo "  6. Execute múltiplos passes completos; registre versão, duração e erros."
    echo "  7. Retorne ao Ubuntu e anexe o resultado ao relatório de homologação."
    echo
    echo "Verificações locais (somente leitura):"
    if dpkg-query -W -f='${db:Status-Abbrev} ${Version}\n' memtest86+ 2>/dev/null | grep -q '^ii'; then
        dpkg-query -W -f='Pacote memtest86+: ${Version}\n' memtest86+ 2>/dev/null || true
    else
        echo "Pacote memtest86+: não instalado."
    fi
    if [[ -d /sys/firmware/efi ]]; then
        echo "Modo de boot atual: UEFI"
    else
        echo "Modo de boot atual: Legacy BIOS ou EFI não exposto pelo sistema."
    fi
    if have grub-reboot; then
        echo "GRUB detectado. Verifique as entradas disponíveis com:"
        echo "  grep -i -E 'memtest|menuentry' /boot/grub/grub.cfg"
    fi
    echo
    status_line WARNING "Memtest86+ exige reinicialização e teste fora do Ubuntu; esta ferramenta não agenda nem executa o reboot."
}

menu_memory() {
    while true; do
        echo
        echo "=== MEMÓRIA RAM ==="
        echo "1 - Exibir memória"
        echo "2 - Exibir DIMMs (dmidecode)"
        echo "3 - Executar memtester (teste em operação)"
        echo "4 - Orientações para Memtest86+ (boot/offline)"
        echo "5 - Voltar"
        read -r -p "Opção: " opt
        case "$opt" in
            1) free -h; pause ;;
            2) have dmidecode && dmidecode -t memory || warn "dmidecode indisponível."; pause ;;
            3) ram_test; pause ;;
            4) memtest86_guidance; pause ;;
            5) break ;;
            *) warn "Opção inválida." ;;
        esac
    done
}

# ---------- Network module ----------------------------------------------------
detect_network_pci() {
    section "CONTROLADORAS DE REDE PCI"
    if ! have lspci; then
        warn "pciutils/lspci indisponível."
        return 1
    fi
    lspci -nnk | grep -iEA3 'Ethernet controller|Network controller' || true
}

network_interfaces() {
    ip -br link
}

inspect_interface() {
    local iface="$1"
    ip link show dev "$iface" >/dev/null 2>&1 || { error "Interface inexistente: $iface"; return 1; }
    section "DIAGNÓSTICO DE INTERFACE: $iface"
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
        warn "ethtool não instalado."
    fi

    local pci
    pci="$(basename "$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)")"
    if [[ "$pci" =~ ^[0-9a-fA-F]{4}: ]]; then
        echo
        lspci -vv -s "$pci" 2>/dev/null || true
    fi
}

network_iperf() {
    section "TESTE DE THROUGHPUT IPERF3"
    have iperf3 || { error "iperf3 não instalado."; return 1; }
    local server duration
    read -r -p "IP/hostname do servidor iperf3 (-s): " server
    [[ -n "$server" ]] || { info "Teste cancelado."; return 0; }
    read -r -p "Duração em segundos [10]: " duration
    duration="${duration:-10}"
    [[ "$duration" =~ ^[1-9][0-9]*$ ]] && (( duration <= 300 )) ||
        { error "Duração inválida (1 a 300 segundos)."; return 1; }
    iperf3 -c "$server" -t "$duration" --get-server-output
}

menu_network() {
    while true; do
        echo
        echo "=== REDE: BROADCOM / MELLANOX ==="
        echo "1 - Detectar controladoras PCI"
        echo "2 - Listar interfaces"
        echo "3 - Inspecionar interface (driver, firmware, link, offload, counters, PCIe)"
        echo "4 - Teste de throughput (iperf3)"
        echo "5 - Voltar"
        read -r -p "Opção: " opt
        case "$opt" in
            1) detect_network_pci; pause ;;
            2) network_interfaces; pause ;;
            3)
                network_interfaces
                read -r -p "Nome da interface: " iface
                inspect_interface "$iface"; pause ;;
            4) network_iperf; pause ;;
            5) break ;;
            *) warn "Opção inválida." ;;
        esac
    done
}

# ---------- NVIDIA / DCGM -----------------------------------------------------
gpu_diagnostics() {
    section "DIAGNÓSTICO NVIDIA GPU"
    if ! have nvidia-smi; then
        status_line NOT_TESTED "nvidia-smi não encontrado; driver NVIDIA pode não estar instalado/carregado."
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
        echo "O diagnóstico pode executar verificações adicionais e consumir recursos da GPU."
        if confirm_exact DCGM "Deseja executar dcgmi diag -r 1?"; then
            dcgmi diag -r 1
            status_line PASS "DCGM diagnostic level 1 concluído."
        else
            status_line NOT_TESTED "Diagnóstico DCGM não executado."
        fi
    else
        status_line WARNING "dcgmi não encontrado; diagnóstico DCGM não disponível."
    fi
}

menu_gpu() {
    while true; do
        echo
        echo "=== NVIDIA GPU ==="
        echo "1 - Detectar GPUs NVIDIA no PCIe"
        echo "2 - Diagnóstico nvidia-smi / DCGM"
        echo "3 - Voltar"
        read -r -p "Opção: " opt
        case "$opt" in
            1) lspci -nn | grep -iE 'VGA|3D|Display|NVIDIA' || true; pause ;;
            2) gpu_diagnostics; pause ;;
            3) break ;;
            *) warn "Opção inválida." ;;
        esac
    done
}

# ---------- PCIe and DKMS -----------------------------------------------------
pcie_inventory() {
    section "INVENTÁRIO PCIe"
    if have lspci; then
        lspci -Dnn
        echo
        echo "Resumo de velocidade/largura negociadas (quando expostas pelo kernel):"
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
        warn "lspci indisponível."
    fi
}

dkms_status() {
    section "STATUS DKMS"
    if have dkms; then
        dkms status || status_line WARNING "dkms status retornou erro."
    else
        status_line NOT_TESTED "DKMS não instalado."
    fi
    echo
    echo "Módulos relevantes carregados:"
    lsmod | grep -E 'bnxt_en|mlx5_core|nvidia|nvidia_uvm|nvidia_drm' || true
    echo
    echo "Pacotes relacionados instalados:"
    dpkg-query -W -f='${binary:Package} ${Version}\n' 2>/dev/null |
        grep -Ei 'bnxt|broadcom|mlx|mellanox|nvidia|cuda|dcgm|linux-(image|headers)' || true
}

# ---------- APT hold management ----------------------------------------------
show_holds() {
    section "PACOTES APT EM HOLD"
    apt-mark showhold || true
}

hold_matching_packages() {
    local label="$1" regex="$2"
    local packages
    mapfile -t packages < <(installed_packages_matching "$regex")
    if ((${#packages[@]} == 0)); then
        info "Nenhum pacote instalado encontrado para: $label"
        return 0
    fi
    printf 'Pacotes encontrados (%s):\n' "$label"
    printf '  %s\n' "${packages[@]}"
    if confirm_exact HOLD "Aplicar apt-mark hold somente a estes pacotes?"; then
        apt-mark hold "${packages[@]}"
        status_line PASS "Hold aplicado ao grupo: $label."
    else
        info "Hold cancelado para: $label"
    fi
}

unhold_matching_packages() {
    local label="$1" regex="$2"
    local packages
    mapfile -t packages < <(installed_packages_matching "$regex")
    if ((${#packages[@]} == 0)); then
        info "Nenhum pacote instalado encontrado para: $label"
        return 0
    fi
    printf 'Pacotes instalados encontrados (%s):\n' "$label"
    printf '  %s\n' "${packages[@]}"
    if confirm_exact UNHOLD "Remover hold destes pacotes, se estiverem bloqueados?"; then
        apt-mark unhold "${packages[@]}" || true
        status_line PASS "Solicitação de unhold concluída para: $label."
    else
        info "Unhold cancelado para: $label"
    fi
}

menu_system() {
    while true; do
        echo
        echo "=== SISTEMA / DRIVERS / KERNEL ==="
        echo "1 - Mostrar pacotes em hold"
        echo "2 - Aplicar hold a pacotes NVIDIA/CUDA/DCGM instalados"
        echo "3 - Aplicar hold a pacotes Broadcom/Mellanox instalados"
        echo "4 - Aplicar hold ao pacote de imagem/headers do kernel atual"
        echo "5 - Remover hold de pacotes NVIDIA/CUDA/DCGM"
        echo "6 - Remover hold de pacotes Broadcom/Mellanox"
        echo "7 - Remover hold do pacote de imagem/headers do kernel atual"
        echo "8 - Status DKMS e módulos carregados"
        echo "9 - Voltar"
        read -r -p "Opção: " opt
        case "$opt" in
            1) show_holds; pause ;;
            2) hold_matching_packages "NVIDIA/CUDA/DCGM" '^(nvidia-|libnvidia-|cuda-|libcuda|datacenter-gpu-manager|dcgm)'; pause ;;
            3) hold_matching_packages "Broadcom/Mellanox" '^(bnxt|firmware-bnx2|firmware-brcm|broadcom-sta|mlnx|mellanox|mstflint|ofed)'; pause ;;
            4)
                local k
                k="$(uname -r)"
                hold_matching_packages "kernel atual ${k}" "^linux-(image|headers)(-unsigned)?-${k//./\\.}($|-)"
                pause ;;
            5) unhold_matching_packages "NVIDIA/CUDA/DCGM" '^(nvidia-|libnvidia-|cuda-|libcuda|datacenter-gpu-manager|dcgm)'; pause ;;
            6) unhold_matching_packages "Broadcom/Mellanox" '^(bnxt|firmware-bnx2|firmware-brcm|broadcom-sta|mlnx|mellanox|mstflint|ofed)'; pause ;;
            7)
                local k
                k="$(uname -r)"
                unhold_matching_packages "kernel atual ${k}" "^linux-(image|headers)(-unsigned)?-${k//./\\.}($|-)"
                pause ;;
            8) dkms_status; pause ;;
            9) break ;;
            *) warn "Opção inválida." ;;
        esac
    done
}

# ---------- Report and summary ------------------------------------------------
generate_summary() {
    section "RESUMO FINAL"
    {
        echo "Host: $(hostname -f 2>/dev/null || hostname)"
        echo "Data: $(ts)"
        echo "Sistema: ${PRETTY_NAME:-unknown}"
        echo "Kernel: $(uname -r)"
        echo "Script: ${SCRIPT_VERSION}"
        echo
        echo "Arquivos:"
        echo "Log: ${LOG_FILE}"
        echo "Relatório: ${REPORT_FILE}"
        echo
        echo "Observação: os módulos não executados devem ser considerados NOT TESTED,"
        echo "não como PASS. A homologação depende dos critérios do fabricante e do projeto."
    } | tee -a "$REPORT_FILE"
    info "Relatório disponível em: ${REPORT_FILE}"
}

# ---------- Main menu ---------------------------------------------------------
main_menu() {
    while true; do
        echo
        echo "============================================================"
        echo " SERVER HARDWARE HOMOLOGATION SUITE v${SCRIPT_VERSION}"
        echo "============================================================"
        echo " 1 - Inventário completo do servidor"
        echo " 2 - Discos (SMART / FIO não destrutivo)"
        echo " 3 - Memória RAM (DIMM / memtester)"
        echo " 4 - Rede (Broadcom / Mellanox)"
        echo " 5 - GPU (NVIDIA / DCGM)"
        echo " 6 - PCIe inventory"
        echo " 7 - Sistema / Drivers / Kernel / APT hold / DKMS"
        echo " 8 - Ver resumo e caminhos dos relatórios"
        echo " 9 - Verificar dependências / instalar sob confirmação"
        echo " 0 - Sair"
        echo "------------------------------------------------------------"
        read -r -p "Selecione: " opt
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
            0) generate_summary; info "Execução encerrada pelo operador."; exit 0 ;;
            *) warn "Opção inválida." ;;
        esac
    done
}

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Ferramenta interativa de homologação de hardware para Ubuntu Server 24.04.

Uso:
  sudo bash ${SCRIPT_NAME}

Logs:
  ${LOG_DIR}

Relatórios:
  ${REPORT_DIR}

Por segurança, o script não executa gravação raw em discos, alteração de firmware,
reboot, power-cycle ou instalação automática de pacotes na inicialização.

FIO: oferece perfis de 1, 10 e 50 GiB, limitados a 20% de espaço livre reservado
e a um teto de 100 GiB. O teste é por arquivo e não substitui validação raw do
fabricante em ambiente dedicado.

RAM: memtester é um teste em user-space. Para passes abrangentes, use Memtest86+
ou ferramenta de diagnóstico bootável aprovada para o hardware.
EOF
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi
    require_root
    init_logging
    check_platform
    main_menu
}

main "$@"
