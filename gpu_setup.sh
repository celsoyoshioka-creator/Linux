#!/usr/bin/env bash

# Sai imediatamente se qualquer comando falhar
set -e

# Definição da versão do CUDA para o DCGM
CUDA_VERSION=13

# FORÇA O MODO NÃO INTERATIVO (Evita telas azuis de configuração de teclado/grub)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a  # Reinicia serviços automaticamente sem perguntar

# Configura códigos de cores para exibição de logs claros
log_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
log_success() { echo -e "\e[32m[SUCESSO]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERRO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[AVISO]\e[0m $1"; }

# 1. Garante que o script seja executado como root (sudo)
if [ "$EUID" -ne 0 ]; then
  log_error "Este script deve ser executado com sudo. Saindo."
  exit 1
fi

# 2. Função para aguardar apenas bloqueios físicos reais do APT com feedback
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

# 3. Verifica a conexão com a internet antes de iniciar
log_info "Verificando a conexão com a internet..."
if ! ping -q -c 1 -W 5 google.com >/dev/null 2>&1; then
  log_error "Nenhuma conexão com a internet detectada. Verifique sua rede e tente novamente."
  exit 1
fi

# 4. Bloqueia a atualização de pacotes relacionados ao Kernel
wait_for_apt_locks
CURRENT_KERNEL=$(uname -r)
log_info "Bloqueando atualizações do kernel atual ($CURRENT_KERNEL) e metapacotes de kernel..."
apt-mark hold \
  linux-image-generic \
  linux-headers-generic \
  linux-generic \
  "linux-image-$CURRENT_KERNEL" \
  "linux-headers-$CURRENT_KERNEL" \
  "linux-modules-$CURRENT_KERNEL" \
  "linux-modules-extra-$CURRENT_KERNEL" >/dev/null 2>&1 || true

# 5. Limpeza inicial de pacotes conflitantes do Data Center GPU Manager
wait_for_apt_locks
log_info "Removendo pacotes potencialmente conflitantes do datacenter-gpu-manager..."
if dpkg-query -W -f='${Status}' datacenter-gpu-manager 2>/dev/null | grep -q "ok installed"; then
  apt-get purge --yes -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" datacenter-gpu-manager || log_warn "Falha ao expurgar o datacenter-gpu-manager, prosseguindo de qualquer forma."
fi
if dpkg-query -W -f='${Status}' datacenter-gpu-manager-config 2>/dev/null | grep -q "ok installed"; then
  apt-get purge --yes -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" datacenter-gpu-manager-config || log_warn "Falha ao expurgar o datacenter-gpu-manager-config, prosseguindo de qualquer forma."
fi

# 6. Instala todas as dependências básicas e ferramentas de compilação
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

# 7. Trata os cabeçalhos do kernel (kernel headers) estritamente para a versão ativa
wait_for_apt_locks
log_info "Instalando cabeçalhos do kernel apenas para a versão ativa: $CURRENT_KERNEL..."
if ! apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" linux-headers-"$CURRENT_KERNEL"; then
  log_warn "Não foi possível encontrar linux-headers-$CURRENT_KERNEL. O DKMS tentará usar os arquivos existentes sem atualizar o kernel."
fi

# 8. Instala os drivers de GPU recomendados
wait_for_apt_locks
log_info "Executando a instalação automática de drivers do Ubuntu..."
ubuntu-drivers autoinstall

# 9. Baixa e registra a chave do repositório oficial da NVIDIA CUDA
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

# 10. Atualiza os repositórios novamente para buscar os metadados do CUDA
wait_for_apt_locks
log_info "Atualizando a lista de pacotes com os repositórios da NVIDIA inclusos..."
apt-get update -y

# 11. Instala o CUDA Toolkit 13.3
log_info "Instalando o CUDA Toolkit 13.3..."
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" cuda-toolkit-13-3

# 12. Instalação do Datacenter GPU Manager compatível com CUDA 13
wait_for_apt_locks
log_info "Instalando o Datacenter GPU Manager para CUDA $CUDA_VERSION..."
apt-get install --yes \
                --install-recommends \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                datacenter-gpu-manager-4-cuda${CUDA_VERSION}

# 13. Instala o monitor nvtop via Snap
log_info "Instalando o nvtop e gpu-burn via Snap..."
snap wait system seed
snap install nvtop
snap install gpu-burn

# 14. LIMPEZA PÓS-INSTALAÇÃO
wait_for_apt_locks
log_info "Realizando a limpeza pós-instalação de pacotes órfãos..."
apt-get autoremove -y

log_success "Todos os drivers, dependências, CUDA 13.3 e o DCGM para CUDA $CUDA_VERSION foram instalados com sucesso!"
log_warn "O sistema será reiniciado em 10 segundos. Pressione Ctrl+C agora para cancelar."
sleep 10
reboot
