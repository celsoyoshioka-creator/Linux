#!/usr/bin/env bash

# Sai imediatamente se qualquer comando falhar
set -e

# Definição da versão do CUDA para o DCGM
CUDA_VERSION=13

# FORÇA O MODO NÃO INTERATIVO
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
log_success() { echo -e "\e[32m[SUCESSO]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERRO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[AVISO]\e[0m $1"; }

# 1. Garante que o script seja executado como root
if [ "$EUID" -ne 0 ]; then
  log_error "Este script deve ser executado com sudo. Saindo."
  exit 1
fi

# 2. Função para aguardar apenas bloqueios físicos reais do APT
wait_for_apt_locks() {
  local segundos_esperando=0
  local imprimiu_aviso=false

  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    if [ "$imprimiu_aviso" = false ]; then
      log_warn "O gerenciador de pacotes (APT) está bloqueado por outro processo."
      log_info "Aguardando liberação física dos arquivos de trava..."
      imprimiu_aviso=true
    fi
    echo -ne "\r\e[K[AGUARDANDO] Arquivos travados. Tempo decorrido: ${segundos_esperando}s..."
    sleep 2
    segundos_esperando=$((segundos_esperando + 2))
  done

  if [ "$imprimiu_aviso" = true ]; then
    echo ""
    log_success "Gerenciador de pacotes liberado após ${segundos_esperando}s!"
  else
    log_success "Gerenciador de pacotes livre para uso."
  fi
}

# 3. Verifica a conexão com a internet
log_info "Verificando a conexão com a internet..."
if ! ping -q -c 1 -W 5 google.com >/dev/null 2>&1; then
  log_error "Nenhuma conexão com a internet detectada."
  exit 1
fi

CURRENT_KERNEL=$(uname -r)
KERNEL_BASE=$(echo "$CURRENT_KERNEL" | cut -d'-' -f1,2)

# 4. Congela estritamente o Kernel ativo e metapacotes
wait_for_apt_locks
log_info "Bloqueando atualizações do kernel atual ($CURRENT_KERNEL) e metapacotes..."
apt-mark hold \
  linux-image-generic \
  linux-headers-generic \
  linux-generic \
  "linux-headers-$KERNEL_BASE" \
  "linux-headers-$CURRENT_KERNEL" \
  "linux-image-$CURRENT_KERNEL" \
  "linux-modules-$CURRENT_KERNEL" \
  "linux-modules-extra-$CURRENT_KERNEL" >/dev/null 2>&1 || true

# 5. Atualização do repositório e instalação das dependências básicas
wait_for_apt_locks
log_info "Atualizando os repositórios de pacotes do sistema..."
apt-get update -y

log_info "Instalando ferramentas básicas de compilação, DKMS e utilitários..."
apt-get install -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  build-essential \
  dkms \
  software-properties-common \
  ca-certificates \
  curl \
  wget \
  gnupg \
  ubuntu-drivers-common \
  alsa-utils \
  snapd

# 6. Garantia da presença dos cabeçalhos do Kernel ativo
wait_for_apt_locks
log_info "Garantindo cabeçalhos para a versão ativa ($KERNEL_BASE / $CURRENT_KERNEL)..."
apt-get install -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  linux-headers-"$KERNEL_BASE" \
  linux-headers-"$CURRENT_KERNEL"

# 7. Instala os drivers de GPU recomendados
wait_for_apt_locks
log_info "Executando a instalação automática de drivers do Ubuntu..."
ubuntu-drivers autoinstall

# 8. Baixa e registra a chave do repositório oficial da NVIDIA CUDA
wait_for_apt_locks
log_info "Configurando os repositórios oficiais da NVIDIA CUDA..."
KEYRING_DEB="cuda-keyring_1.1-1_all.deb"
KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/$KEYRING_DEB"

if ! curl --retry 3 --retry-delay 5 -L "$KEYRING_URL" -o /tmp/"$KEYRING_DEB"; then
  log_error "Falha ao baixar a chave do CUDA após múltiplas tentativas."
  exit 1
fi

dpkg -i --force-confdef --force-confold /tmp/"$KEYRING_DEB"
rm -f /tmp/"$KEYRING_DEB"

# 9. Atualiza repositórios com CUDA
wait_for_apt_locks
log_info "Atualizando a lista de pacotes com repositórios da NVIDIA..."
apt-get update -y

# 10. Instala o CUDA Toolkit 13.3
log_info "Instalando o CUDA Toolkit 13.3..."
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" cuda-toolkit-13-3

# 11. Instalação do Datacenter GPU Manager
wait_for_apt_locks
log_info "Instalando o Datacenter GPU Manager para CUDA $CUDA_VERSION..."
apt-get install --yes \
                --install-recommends \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                datacenter-gpu-manager-4-cuda${CUDA_VERSION}

# 12. Instala utilitários adicionais via Snap
log_info "Instalando o nvtop e gpu-burn via Snap..."
snap wait system seed
snap install nvtop || true
snap install gpu-burn || true

# 13. Limpeza pós-instalação
wait_for_apt_locks
log_info "Realizando a limpeza pós-instalação..."
apt-get autoremove -y

log_success "Todos os drivers e dependências foram instalados mantendo o kernel $CURRENT_KERNEL!"
log_warn "O sistema será reiniciado em 10 segundos. Pressione Ctrl+C agora para cancelar."
sleep 10
reboot
