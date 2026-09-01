#!/usr/bin/env bash

###############################################################################
# NVIDIA / CUDA / DCGM / DKMS / Broadcom bnxt_en Installer
#
# Sistema:
#   Ubuntu 24.04 LTS
#
# Objetivos:
#   - Manter EXATAMENTE o kernel atualmente em execução
#   - Não atualizar o kernel
#   - Instalar headers do kernel atual
#   - Instalar NVIDIA via DKMS
#   - Instalar CUDA Toolkit 13.3
#   - Instalar NVIDIA DCGM 4 para CUDA 13
#   - Validar Broadcom bnxt_en
#   - Recompilar módulos DKMS para o kernel atual
#   - Não executar apt autoremove
#   - Não reiniciar se houver erro crítico
#
###############################################################################

set -Eeuo pipefail

###############################################################################
# CONFIGURAÇÃO
###############################################################################

CUDA_MAJOR="13"
CUDA_VERSION="13-3"

CUDA_TOOLKIT_PACKAGE="cuda-toolkit-${CUDA_VERSION}"
DCGM_PACKAGE="datacenter-gpu-manager-4-cuda${CUDA_MAJOR}"

CUDA_KEYRING_VERSION="1.1-1"
CUDA_KEYRING_PACKAGE="cuda-keyring_${CUDA_KEYRING_VERSION}_all.deb"

CUDA_REPO_BASE="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64"
CUDA_KEYRING_URL="${CUDA_REPO_BASE}/${CUDA_KEYRING_PACKAGE}"

# Reinício automático no final:
#   1 = reboot automático
#   0 = não reiniciar
AUTO_REBOOT=1

# Broadcom:
# Se bnxt-en-dkms estiver instalado/disponível, tenta reconstruí-lo.
ENABLE_BNXT_DKMS=1

# Snap:
INSTALL_NVTOP=1
INSTALL_GPU_BURN=1

# Se Secure Boot estiver habilitado, instalação DKMS não interativa pode
# resultar em módulo que não carrega sem assinatura/MOK.
#
# 0 = abortar se Secure Boot estiver habilitado
# 1 = permitir continuar mesmo com Secure Boot
ALLOW_SECURE_BOOT=0

###############################################################################
# VARIÁVEIS
###############################################################################

CURRENT_KERNEL="$(uname -r)"
ARCH="$(dpkg --print-architecture)"

LOG_FILE="/var/log/gpu-stack-install.log"

APT_OPTIONS=(
    -y
    -o Dpkg::Options::="--force-confdef"
    -o Dpkg::Options::="--force-confold"
)

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

###############################################################################
# LOG
###############################################################################

log_info() {
    echo -e "\e[34m[INFO]\e[0m $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "\e[32m[SUCESSO]\e[0m $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "\e[33m[AVISO]\e[0m $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "\e[31m[ERRO]\e[0m $*" | tee -a "$LOG_FILE" >&2
}

separator() {
    echo "-------------------------------------------------------------------------------" \
        | tee -a "$LOG_FILE"
}

###############################################################################
# TRATAMENTO DE ERROS
###############################################################################

error_handler() {

    local exit_code=$?
    local line_number=$1

    separator
    log_error "Falha crítica."
    log_error "Linha: $line_number"
    log_error "Código de saída: $exit_code"
    log_error "Kernel preservado: $CURRENT_KERNEL"
    log_error "Log completo: $LOG_FILE"

    separator

    log_info "Estado atual do DKMS:"
    dkms status 2>&1 | tee -a "$LOG_FILE" || true

    separator

    log_info "Pacotes quebrados:"
    dpkg --audit 2>&1 | tee -a "$LOG_FILE" || true

    separator

    log_error "O sistema NÃO será reiniciado automaticamente."

    exit "$exit_code"
}

trap 'error_handler $LINENO' ERR

###############################################################################
# ROOT
###############################################################################

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERRO] Execute este script como root:"
    echo
    echo "sudo $0"
    exit 1
fi

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

separator
log_info "Iniciando instalação GPU."
log_info "Kernel atual : $CURRENT_KERNEL"
log_info "Arquitetura  : $ARCH"
log_info "Log           : $LOG_FILE"
separator

###############################################################################
# FUNÇÃO APT LOCK
###############################################################################

wait_for_apt_locks() {

    local waited=0
    local warning_printed=0

    local locks=(
        /var/lib/dpkg/lock
        /var/lib/dpkg/lock-frontend
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )

    while fuser "${locks[@]}" >/dev/null 2>&1; do

        if [[ "$warning_printed" -eq 0 ]]; then
            log_warn "APT/DPKG está sendo utilizado por outro processo."
            log_info "Aguardando liberação..."
            warning_printed=1
        fi

        echo -ne \
            "\r\e[K[AGUARDANDO] APT ocupado. Tempo decorrido: ${waited}s"

        sleep 2
        waited=$((waited + 2))

    done

    if [[ "$warning_printed" -eq 1 ]]; then
        echo
        log_success "APT liberado após ${waited}s."
    fi
}

###############################################################################
# FUNÇÃO APT INSTALL
###############################################################################

apt_install() {

    wait_for_apt_locks

    log_info "Instalando: $*"

    apt-get install \
        "${APT_OPTIONS[@]}" \
        "$@"
}

###############################################################################
# VERIFICA UBUNTU
###############################################################################

log_info "Validando sistema operacional..."

if [[ ! -r /etc/os-release ]]; then
    log_error "/etc/os-release não encontrado."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    log_error "Sistema detectado: ${ID:-desconhecido}"
    log_error "Este script suporta somente Ubuntu."
    exit 1
fi

if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    log_error "Ubuntu ${VERSION_ID:-desconhecido} detectado."
    log_error "Este script foi preparado especificamente para Ubuntu 24.04."
    exit 1
fi

log_success "Ubuntu 24.04 confirmado."

###############################################################################
# ARQUITETURA
###############################################################################

if [[ "$ARCH" != "amd64" ]]; then
    log_error "Arquitetura detectada: $ARCH"
    log_error "Este script está configurado para NVIDIA CUDA x86_64/amd64."
    exit 1
fi

###############################################################################
# INTERNET
#
# Não usa ping porque ICMP pode estar bloqueado.
###############################################################################

log_info "Verificando acesso HTTPS ao repositório NVIDIA..."

if ! curl \
        --silent \
        --show-error \
        --fail \
        --head \
        --connect-timeout 10 \
        --max-time 20 \
        "$CUDA_REPO_BASE/" \
        >/dev/null; then

    log_error "Não foi possível acessar:"
    log_error "$CUDA_REPO_BASE/"
    exit 1
fi

log_success "Conectividade HTTPS confirmada."

###############################################################################
# VERIFICA ESTADO DO DPKG
###############################################################################

separator
log_info "Verificando integridade inicial do DPKG..."

DPKG_AUDIT="$(dpkg --audit || true)"

if [[ -n "$DPKG_AUDIT" ]]; then

    log_error "DPKG possui pacotes pendentes/quebrados:"
    echo "$DPKG_AUDIT" | tee -a "$LOG_FILE"

    log_error "Corrija os pacotes antes de executar este instalador."
    log_error "Não executarei automaticamente 'apt --fix-broken install',"
    log_error "pois isso poderia instalar um kernel diferente."

    exit 1
fi

log_success "DPKG está consistente."

###############################################################################
# SECURE BOOT
###############################################################################

separator
log_info "Verificando Secure Boot..."

SECURE_BOOT="unknown"

if command -v mokutil >/dev/null 2>&1; then

    if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
        SECURE_BOOT="enabled"
    elif mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot disabled"; then
        SECURE_BOOT="disabled"
    fi

fi

case "$SECURE_BOOT" in

    enabled)

        log_warn "Secure Boot está HABILITADO."

        if [[ "$ALLOW_SECURE_BOOT" -ne 1 ]]; then

            log_error "Este instalador utilizará módulos DKMS."
            log_error "Com Secure Boot habilitado, os módulos podem exigir"
            log_error "assinatura e enrollment de chave MOK."

            log_error "Por segurança, instalação interrompida."

            log_info "Se a política do servidor permitir continuar, altere:"
            log_info "ALLOW_SECURE_BOOT=1"

            exit 1
        fi

        log_warn "ALLOW_SECURE_BOOT=1: continuando."

        ;;

    disabled)

        log_success "Secure Boot desabilitado."

        ;;

    *)

        log_warn "Não foi possível determinar o estado do Secure Boot."

        ;;

esac

###############################################################################
# CONGELA METAPACOTES DO KERNEL ANTES DAS INSTALAÇÕES GERAIS
###############################################################################

separator
log_info "Protegendo metapacotes do kernel..."

KERNEL_META_PACKAGES=(
    linux-generic
    linux-image-generic
    linux-headers-generic
)

for pkg in "${KERNEL_META_PACKAGES[@]}"; do

    if dpkg-query -W \
        -f='${db:Status-Abbrev}' "$pkg" \
        2>/dev/null | grep -q '^ii'; then

        apt-mark hold "$pkg" >/dev/null

        log_success "HOLD aplicado: $pkg"
    else
        log_info "Metapacote não instalado: $pkg"
    fi

done

###############################################################################
# APT UPDATE
###############################################################################

separator
wait_for_apt_locks

log_info "Atualizando índices do APT..."

apt-get update

###############################################################################
# FERRAMENTAS BÁSICAS
###############################################################################

separator
log_info "Instalando ferramentas básicas..."

apt_install \
    build-essential \
    dkms \
    software-properties-common \
    ca-certificates \
    curl \
    wget \
    gnupg \
    pciutils \
    usbutils \
    lsb-release \
    ubuntu-drivers-common \
    mokutil \
    kmod \
    initramfs-tools \
    alsa-utils \
    snapd

###############################################################################
# HEADERS EXATOS DO KERNEL EM EXECUÇÃO
###############################################################################

separator
log_info "Instalando headers EXATAMENTE para:"
log_info "$CURRENT_KERNEL"

if ! apt-cache show \
        "linux-headers-${CURRENT_KERNEL}" \
        >/dev/null 2>&1; then

    log_error "Headers não encontrados:"
    log_error "linux-headers-${CURRENT_KERNEL}"

    log_error "Não vou instalar headers de outro kernel."
    exit 1
fi

apt_install \
    "linux-headers-${CURRENT_KERNEL}"

###############################################################################
# VALIDA BUILD DIRECTORY
###############################################################################

KERNEL_BUILD="/lib/modules/${CURRENT_KERNEL}/build"

if [[ ! -e "$KERNEL_BUILD/Makefile" ]]; then
    log_error "Build tree do kernel não encontrado:"
    log_error "$KERNEL_BUILD"
    exit 1
fi

log_success "Headers do kernel atual disponíveis."

###############################################################################
# HOLD DOS PACOTES EXATOS DO KERNEL
###############################################################################

separator
log_info "Congelando pacotes EXATOS do kernel atual..."

KERNEL_PACKAGES=(
    "linux-image-${CURRENT_KERNEL}"
    "linux-headers-${CURRENT_KERNEL}"
    "linux-modules-${CURRENT_KERNEL}"
    "linux-modules-extra-${CURRENT_KERNEL}"
)

for pkg in "${KERNEL_PACKAGES[@]}"; do

    if dpkg-query -W \
        -f='${db:Status-Abbrev}' "$pkg" \
        2>/dev/null | grep -q '^ii'; then

        apt-mark hold "$pkg" >/dev/null

        log_success "HOLD: $pkg"
    else
        log_info "Não instalado: $pkg"
    fi

done

###############################################################################
# REGISTRA KERNEL ORIGINAL
###############################################################################

ORIGINAL_KERNEL="$CURRENT_KERNEL"

###############################################################################
# CONFIGURA REPOSITÓRIO CUDA
###############################################################################

separator
log_info "Configurando repositório oficial NVIDIA CUDA..."

TMP_KEYRING="/tmp/${CUDA_KEYRING_PACKAGE}"

rm -f "$TMP_KEYRING"

curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 5 \
    --connect-timeout 15 \
    "$CUDA_KEYRING_URL" \
    --output "$TMP_KEYRING"

dpkg \
    --install \
    --force-confdef \
    --force-confold \
    "$TMP_KEYRING"

rm -f "$TMP_KEYRING"

wait_for_apt_locks

apt-get update

log_success "Repositório NVIDIA CUDA configurado."

###############################################################################
# GARANTE QUE CUDA 13.3 EXISTE
###############################################################################

separator
log_info "Verificando pacote $CUDA_TOOLKIT_PACKAGE..."

if ! apt-cache show "$CUDA_TOOLKIT_PACKAGE" >/dev/null 2>&1; then
    log_error "$CUDA_TOOLKIT_PACKAGE não está disponível."
    exit 1
fi

log_success "$CUDA_TOOLKIT_PACKAGE disponível."

###############################################################################
# DETECTA GPU NVIDIA
###############################################################################

separator
log_info "Detectando dispositivos NVIDIA..."

if ! lspci -nn | grep -qi NVIDIA; then
    log_error "Nenhuma GPU NVIDIA foi detectada pelo PCI."
    exit 1
fi

lspci -nn \
    | grep -i NVIDIA \
    | tee -a "$LOG_FILE"

log_success "GPU NVIDIA detectada."

###############################################################################
# IDENTIFICA DRIVER RECOMENDADO
###############################################################################

separator
log_info "Identificando driver NVIDIA recomendado pelo Ubuntu..."

UBUNTU_DRIVERS_OUTPUT="$(ubuntu-drivers devices 2>&1 || true)"

echo "$UBUNTU_DRIVERS_OUTPUT" >> "$LOG_FILE"

NVIDIA_DRIVER_PACKAGE="$(
    echo "$UBUNTU_DRIVERS_OUTPUT" \
        | awk '/driver/ && /recommended/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^nvidia-driver-/) {
                    print $i
                    exit
                }
            }
        }'
)"

if [[ -z "$NVIDIA_DRIVER_PACKAGE" ]]; then

    log_error "Não foi possível identificar automaticamente"
    log_error "o driver NVIDIA recomendado."

    log_info "Resultado do ubuntu-drivers:"
    echo "$UBUNTU_DRIVERS_OUTPUT" | tee -a "$LOG_FILE"

    exit 1
fi

log_success "Driver recomendado:"
log_success "$NVIDIA_DRIVER_PACKAGE"

###############################################################################
# CONVERTE DRIVER PARA PACOTE DKMS
#
# Exemplos:
#
# nvidia-driver-580
#       -> nvidia-dkms-580
#
# nvidia-driver-580-open
#       -> nvidia-dkms-580-open
#
# nvidia-driver-580-server
#       -> nvidia-dkms-580-server
#
# nvidia-driver-580-server-open
#       -> nvidia-dkms-580-server-open
###############################################################################

NVIDIA_FLAVOR="${NVIDIA_DRIVER_PACKAGE#nvidia-driver-}"

NVIDIA_DKMS_PACKAGE="nvidia-dkms-${NVIDIA_FLAVOR}"

log_info "Pacote DKMS correspondente:"
log_info "$NVIDIA_DKMS_PACKAGE"

###############################################################################
# VALIDA DKMS PACKAGE
###############################################################################

if ! apt-cache show "$NVIDIA_DKMS_PACKAGE" >/dev/null 2>&1; then

    log_error "Pacote DKMS correspondente não encontrado:"
    log_error "$NVIDIA_DKMS_PACKAGE"

    exit 1
fi

###############################################################################
# SIMULA INSTALAÇÃO
#
# Fundamental: detecta previamente se APT pretende instalar outro kernel.
###############################################################################

separator
log_info "Simulando instalação NVIDIA antes de alterar o sistema..."

SIMULATION="$(
    apt-get \
        -s \
        install \
        "$NVIDIA_DKMS_PACKAGE" \
        "$NVIDIA_DRIVER_PACKAGE" \
        2>&1
)"

echo "$SIMULATION" >> "$LOG_FILE"

###############################################################################
# BLOQUEIA TENTATIVA DE INSTALAR OUTRO KERNEL
###############################################################################

if echo "$SIMULATION" \
    | grep '^Inst ' \
    | grep -E \
      'linux-(image|headers|modules|modules-extra)-[0-9]' \
    | grep -v -- "$CURRENT_KERNEL" \
    >/dev/null; then

    log_error "APT tentou introduzir outro kernel durante a instalação NVIDIA."

    log_error "Operação recusada para preservar:"
    log_error "$CURRENT_KERNEL"

    log_info "Pacotes que provocaram o bloqueio:"

    echo "$SIMULATION" \
        | grep '^Inst ' \
        | grep -E \
          'linux-(image|headers|modules|modules-extra)-[0-9]' \
        | grep -v -- "$CURRENT_KERNEL" \
        | tee -a "$LOG_FILE"

    exit 1
fi

log_success "Simulação aprovada. Nenhum novo kernel será instalado."

###############################################################################
# INSTALA NVIDIA DKMS PRIMEIRO
###############################################################################

separator
log_info "Instalando módulo NVIDIA DKMS..."

apt_install \
    "$NVIDIA_DKMS_PACKAGE"

###############################################################################
# INSTALA USERSPACE DO DRIVER
###############################################################################

separator
log_info "Instalando driver NVIDIA..."

apt_install \
    "$NVIDIA_DRIVER_PACKAGE"

###############################################################################
# DKMS AUTOINSTALL SOMENTE PARA KERNEL ATUAL
###############################################################################

separator
log_info "Executando DKMS para kernel:"
log_info "$CURRENT_KERNEL"

dkms autoinstall \
    -k "$CURRENT_KERNEL"

###############################################################################
# STATUS DKMS
###############################################################################

separator
log_info "Status DKMS:"

DKMS_STATUS="$(dkms status || true)"

echo "$DKMS_STATUS" \
    | tee -a "$LOG_FILE"

###############################################################################
# VALIDA NVIDIA DKMS
###############################################################################

if ! echo "$DKMS_STATUS" \
    | grep -i nvidia \
    | grep -F "$CURRENT_KERNEL" \
    | grep -Eq 'installed|built'; then

    log_warn "Não foi encontrada entrada NVIDIA DKMS claramente válida"
    log_warn "para $CURRENT_KERNEL."

    log_info "Verificando módulo diretamente..."

    if ! modinfo \
        -k "$CURRENT_KERNEL" \
        nvidia \
        >/dev/null 2>&1; then

        log_error "Módulo NVIDIA não está disponível para $CURRENT_KERNEL."
        exit 1
    fi
fi

log_success "Módulo NVIDIA disponível para $CURRENT_KERNEL."

###############################################################################
# BROADCOM BNXT_EN
###############################################################################

separator
log_info "Verificando Broadcom bnxt_en..."

if lspci -nn \
    | grep -Eqi 'Broadcom.*Ethernet|Ethernet.*Broadcom'; then

    log_success "Adaptador Ethernet Broadcom detectado."

    lspci -nnk \
        | grep -A4 -Bi2 Broadcom \
        | tee -a "$LOG_FILE" \
        || true

else

    log_warn "Nenhum Ethernet Broadcom detectado via lspci."

fi

###############################################################################
# VERIFICA MÓDULO BNXT_EN DO KERNEL
###############################################################################

if modinfo \
    -k "$CURRENT_KERNEL" \
    bnxt_en \
    >/dev/null 2>&1; then

    log_success "bnxt_en disponível para $CURRENT_KERNEL."

    modinfo \
        -k "$CURRENT_KERNEL" \
        bnxt_en \
        | grep -E \
          '^(filename|version|srcversion|vermagic|description):' \
        | tee -a "$LOG_FILE" \
        || true

else

    log_error "bnxt_en não foi encontrado para $CURRENT_KERNEL."
    exit 1

fi

###############################################################################
# BNXT-EN-DKMS
###############################################################################

if [[ "$ENABLE_BNXT_DKMS" -eq 1 ]]; then

    separator
    log_info "Verificando pacote Broadcom bnxt-en-dkms..."

    if dpkg-query \
        -W \
        -f='${Status}' \
        bnxt-en-dkms \
        2>/dev/null \
        | grep -q "install ok installed"; then

        log_success "bnxt-en-dkms já está instalado."

        BNXT_VERSION="$(
            dpkg-query \
                -W \
                -f='${Version}' \
                bnxt-en-dkms
        )"

        log_info "Versão do pacote:"
        log_info "$BNXT_VERSION"

        #######################################################################
        # Reinstala para registrar/reconstruir o DKMS caso esteja quebrado.
        #######################################################################

        log_info "Reinstalando bnxt-en-dkms..."

        apt-get install \
            "${APT_OPTIONS[@]}" \
            --reinstall \
            bnxt-en-dkms

        log_info "Executando DKMS novamente para $CURRENT_KERNEL..."

        dkms autoinstall \
            -k "$CURRENT_KERNEL"

    elif apt-cache show bnxt-en-dkms >/dev/null 2>&1; then

        log_info "bnxt-en-dkms disponível no APT."

        apt_install \
            bnxt-en-dkms

        dkms autoinstall \
            -k "$CURRENT_KERNEL"

    else

        log_warn "bnxt-en-dkms não está instalado nem disponível"
        log_warn "nos repositórios configurados."

        log_warn "Será utilizado o bnxt_en presente no kernel atual."

    fi

fi

###############################################################################
# VALIDA BNXT DEPOIS DO DKMS
###############################################################################

separator
log_info "Validando bnxt_en após DKMS..."

if ! modinfo \
    -k "$CURRENT_KERNEL" \
    bnxt_en \
    >/dev/null 2>&1; then

    log_error "bnxt_en desapareceu após processamento DKMS."
    exit 1
fi

BNXT_MODULE_FILE="$(
    modinfo \
        -k "$CURRENT_KERNEL" \
        -F filename \
        bnxt_en
)"

log_success "bnxt_en final:"
log_success "$BNXT_MODULE_FILE"

###############################################################################
# INSTALA CUDA TOOLKIT 13.3
###############################################################################

separator
log_info "Instalando CUDA Toolkit 13.3..."

###############################################################################
# Simulação de segurança novamente.
###############################################################################

CUDA_SIMULATION="$(
    apt-get \
        -s \
        install \
        "$CUDA_TOOLKIT_PACKAGE" \
        2>&1
)"

echo "$CUDA_SIMULATION" >> "$LOG_FILE"

if echo "$CUDA_SIMULATION" \
    | grep '^Inst ' \
    | grep -E \
      'linux-(image|headers|modules|modules-extra)-[0-9]' \
    | grep -v -- "$CURRENT_KERNEL" \
    >/dev/null; then

    log_error "CUDA Toolkit tentou instalar outro kernel."
    exit 1
fi

apt_install \
    "$CUDA_TOOLKIT_PACKAGE"

###############################################################################
# CUDA ENVIRONMENT
###############################################################################

separator
log_info "Configurando PATH do CUDA 13.3..."

cat > /etc/profile.d/cuda-13-3.sh <<'EOF'
export PATH=/usr/local/cuda-13.3/bin:${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda-13.3/lib64:${LD_LIBRARY_PATH:-}
EOF

chmod 644 /etc/profile.d/cuda-13-3.sh

###############################################################################
# NVCC
###############################################################################

NVCC="/usr/local/cuda-13.3/bin/nvcc"

if [[ ! -x "$NVCC" ]]; then

    log_error "nvcc não encontrado em:"
    log_error "$NVCC"

    exit 1
fi

log_success "CUDA Toolkit instalado."

"$NVCC" \
    --version \
    | tee -a "$LOG_FILE"

###############################################################################
# DCGM
###############################################################################

separator
log_info "Verificando pacote DCGM..."

if ! apt-cache show "$DCGM_PACKAGE" >/dev/null 2>&1; then

    log_error "Pacote não disponível:"
    log_error "$DCGM_PACKAGE"

    exit 1
fi

log_info "Instalando:"
log_info "$DCGM_PACKAGE"

apt_install \
    --install-recommends \
    "$DCGM_PACKAGE"

###############################################################################
# DCGM SERVICE
###############################################################################

separator
log_info "Configurando serviço DCGM..."

if systemctl list-unit-files \
    | grep -q '^nvidia-dcgm\.service'; then

    systemctl enable nvidia-dcgm.service || true
    systemctl restart nvidia-dcgm.service || true

elif systemctl list-unit-files \
    | grep -q '^dcgm\.service'; then

    systemctl enable dcgm.service || true
    systemctl restart dcgm.service || true

else

    log_warn "Serviço systemd DCGM não identificado."
fi

###############################################################################
# DEPMOD E INITRAMFS
###############################################################################

separator
log_info "Atualizando mapa de módulos..."

depmod \
    -a "$CURRENT_KERNEL"

log_info "Atualizando initramfs SOMENTE do kernel atual..."

update-initramfs \
    -u \
    -k "$CURRENT_KERNEL"

###############################################################################
# GARANTE QUE O KERNEL NÃO MUDOU
###############################################################################

if [[ "$(uname -r)" != "$ORIGINAL_KERNEL" ]]; then

    log_error "Kernel em execução mudou inesperadamente."
    exit 1
fi

###############################################################################
# VERIFICA KERNELS INSTALADOS
###############################################################################

separator
log_info "Kernel em execução:"
uname -r | tee -a "$LOG_FILE"

log_info "Imagens de kernel instaladas:"

dpkg-query \
    -W \
    'linux-image-[0-9]*' \
    2>/dev/null \
    | tee -a "$LOG_FILE" \
    || true

###############################################################################
# VERIFICA HOLDS
###############################################################################

separator
log_info "Pacotes em HOLD:"

apt-mark showhold \
    | tee -a "$LOG_FILE"

###############################################################################
# VALIDA DRIVER NVIDIA
#
# Antes do reboot pode existir um driver antigo carregado.
# Portanto modinfo é obrigatório; nvidia-smi é best effort.
###############################################################################

separator
log_info "Validando módulo NVIDIA para $CURRENT_KERNEL..."

modinfo \
    -k "$CURRENT_KERNEL" \
    nvidia \
    | grep -E \
      '^(filename|version|vermagic):' \
    | tee -a "$LOG_FILE"

###############################################################################
# TENTA CARREGAR DRIVER
###############################################################################

log_info "Tentando carregar módulo NVIDIA..."

if modprobe nvidia 2>>"$LOG_FILE"; then
    log_success "Módulo NVIDIA carregado."
else
    log_warn "Não foi possível carregar NVIDIA antes do reboot."
    log_warn "Isso pode ser normal se uma versão anterior estiver em uso."
fi

###############################################################################
# NVIDIA-SMI
###############################################################################

separator

if command -v nvidia-smi >/dev/null 2>&1; then

    log_info "Executando nvidia-smi..."

    if nvidia-smi | tee -a "$LOG_FILE"; then

        log_success "nvidia-smi funcionando."

    else

        log_warn "nvidia-smi ainda não está funcional."
        log_warn "Nova tentativa deverá ser feita após o reboot."

    fi

else

    log_error "nvidia-smi não foi instalado."
    exit 1

fi

###############################################################################
# DCGM VERSION
###############################################################################

separator

if command -v dcgmi >/dev/null 2>&1; then

    log_info "DCGM:"
    dcgmi --version \
        | tee -a "$LOG_FILE" \
        || true

else

    log_warn "dcgmi não encontrado no PATH."
fi

###############################################################################
# SNAP
###############################################################################

separator
log_info "Ferramentas adicionais..."

if command -v snap >/dev/null 2>&1; then

    systemctl enable --now snapd.socket || true

    snap wait system seed || true

    if [[ "$INSTALL_NVTOP" -eq 1 ]]; then

        log_info "Instalando nvtop via Snap..."

        if snap install nvtop; then
            log_success "nvtop instalado."
        else
            log_warn "Falha ao instalar nvtop."
        fi
    fi

    if [[ "$INSTALL_GPU_BURN" -eq 1 ]]; then

        log_info "Instalando gpu-burn via Snap..."

        if snap install gpu-burn; then
            log_success "gpu-burn instalado."
        else
            log_warn "Falha ao instalar gpu-burn."
        fi
    fi

else

    log_warn "Snap não está disponível."
fi

###############################################################################
# NÃO EXECUTAR AUTOREMOVE
###############################################################################

separator
log_warn "apt autoremove NÃO será executado."

log_info "Isso é proposital para evitar remoção acidental de:"
log_info "- kernel"
log_info "- headers"
log_info "- módulos"
log_info "- DKMS"
log_info "- NVIDIA"
log_info "- Broadcom"

###############################################################################
# RELATÓRIO FINAL DKMS
###############################################################################

separator
log_info "Status final do DKMS:"

dkms status \
    | tee -a "$LOG_FILE" \
    || true

###############################################################################
# RELATÓRIO BNXT
###############################################################################

separator
log_info "Broadcom bnxt_en:"

modinfo \
    -k "$CURRENT_KERNEL" \
    bnxt_en \
    | grep -E \
      '^(filename|version|srcversion|vermagic|description):' \
    | tee -a "$LOG_FILE" \
    || true

###############################################################################
# INTERFACE BROADCOM
###############################################################################

log_info "Drivers Broadcom em uso:"

lspci -nnk \
    | awk '
        /Broadcom/ {
            print
            count=5
            next
        }

        count > 0 {
            print
            count--
        }
    ' \
    | tee -a "$LOG_FILE" \
    || true

###############################################################################
# CUDA
###############################################################################

separator
log_info "CUDA:"

"$NVCC" \
    --version \
    | tee -a "$LOG_FILE"

###############################################################################
# VERIFICAÇÕES CRÍTICAS FINAIS
###############################################################################

separator
log_info "Executando verificações críticas finais..."

FINAL_ERRORS=0

###############################################################################
# 1. Kernel
###############################################################################

if [[ "$(uname -r)" == "$CURRENT_KERNEL" ]]; then
    log_success "Kernel preservado: $CURRENT_KERNEL"
else
    log_error "Kernel inesperado."
    FINAL_ERRORS=$((FINAL_ERRORS + 1))
fi

###############################################################################
# 2. Headers
###############################################################################

if [[ -e "/lib/modules/$CURRENT_KERNEL/build/Makefile" ]]; then
    log_success "Headers OK."
else
    log_error "Headers inválidos."
    FINAL_ERRORS=$((FINAL_ERRORS + 1))
fi

###############################################################################
# 3. NVIDIA
###############################################################################

if modinfo \
    -k "$CURRENT_KERNEL" \
    nvidia \
    >/dev/null 2>&1; then

    log_success "NVIDIA module OK."
else
    log_error "NVIDIA module ausente."
    FINAL_ERRORS=$((FINAL_ERRORS + 1))
fi

###############################################################################
# 4. BNXT
###############################################################################

if modinfo \
    -k "$CURRENT_KERNEL" \
    bnxt_en \
    >/dev/null 2>&1; then

    log_success "bnxt_en module OK."
else
    log_error "bnxt_en module ausente."
    FINAL_ERRORS=$((FINAL_ERRORS + 1))
fi

###############################################################################
# 5. CUDA
###############################################################################

if [[ -x "$NVCC" ]]; then
    log_success "CUDA 13.3 OK."
else
    log_error "CUDA 13.3 inválido."
    FINAL_ERRORS=$((FINAL_ERRORS + 1))
fi

###############################################################################
# 6. DCGM
###############################################################################

if dpkg-query \
    -W \
    -f='${Status}' \
    "$DCGM_PACKAGE" \
    2>/dev/null \
    | grep -q "install ok installed"; then

    log_success "DCGM instalado."
else
    log_error "DCGM não está instalado corretamente."
    FINAL_ERRORS=$((FINAL_ERRORS + 1))
fi

###############################################################################
# RESULTADO
###############################################################################

separator

if [[ "$FINAL_ERRORS" -gt 0 ]]; then

    log_error "Foram encontrados $FINAL_ERRORS erro(s) crítico(s)."
    log_error "O servidor NÃO será reiniciado automaticamente."
    log_error "Verifique:"
    log_error "$LOG_FILE"

    exit 1
fi

log_success "TODAS AS VERIFICAÇÕES CRÍTICAS FORAM APROVADAS."

separator

log_success "Kernel preservado:"
log_success "$CURRENT_KERNEL"

log_success "Driver NVIDIA:"
log_success "$NVIDIA_DRIVER_PACKAGE"

log_success "NVIDIA DKMS:"
log_success "$NVIDIA_DKMS_PACKAGE"

log_success "CUDA:"
log_success "13.3"

log_success "DCGM:"
log_success "$DCGM_PACKAGE"

log_success "Broadcom:"
log_success "bnxt_en disponível"

log_success "Log:"
log_success "$LOG_FILE"

separator

###############################################################################
# REBOOT
###############################################################################

if [[ "$AUTO_REBOOT" -eq 1 ]]; then

    log_warn "O sistema será reiniciado em 10 segundos."
    log_warn "Pressione Ctrl+C para cancelar."

    sleep 10

    sync

    reboot

else

    log_warn "Reboot automático desabilitado."
    log_warn "Reinicie o servidor manualmente antes de validar a GPU."
fi
