#!/usr/bin/env bash

# Definição da versão do CUDA para o DCGM
CUDA_VERSION=13

# FORÇA O MODO NÃO INTERATIVO
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Cores para o terminal
log_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
log_success() { echo -e "\e[32m[SUCESSO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[AVISO]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERRO/PERIGO]\e[0m $1"; }

# 1. Garante que o script seja executado como root
if [ "$EUID" -ne 0 ]; then
  log_error "Este script precisa ser executado com sudo."
  exit 1
fi

# ==============================================================================
# CAMADA INTELIGENTE DO SCREEN (EXECUÇÃO PERSISTENTE)
# ==============================================================================
dentro_do_screen=false
if [ -n "$STY" ] || [[ "$TERM" == *"screen"* ]]; then
  dentro_do_screen=true
fi

if [ "$dentro_do_screen" = false ]; then
  log_info "Detectado que o script não está rodando dentro de uma sessão screen."
  
  if ! command -v screen &> /dev/null; then
    log_warn "O pacote 'screen' não foi encontrado. Instalando dependência..."
    apt-get update -y && apt-get install -y screen
  fi

  NOME_SESSAO="setup_teste_gpu"
  log_info "Criando uma nova sessão screen chamada: '$NOME_SESSAO'..."
  
  SCRIPT_PATH=$(realpath "$0")
  ARGUMENTOS="$@"

  sleep 1.5

  exec sudo screen -S "$NOME_SESSAO" bash -c "sudo -E $SCRIPT_PATH $ARGUMENTOS; echo -e '\nPressione qualquer tecla para fechar esta screen...'; read -n 1"
fi
# ==============================================================================

# Função para aguardar bloqueios físicos reais do APT
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

# ==============================================================================
# FASE 1: SETUP E INSTALAÇÃO DOS DRIVERS/FERRAMENTAS
# ==============================================================================
log_info "=== INICIANDO FASE 1: SETUP ==="

# Sai imediatamente se qualquer comando de setup falhar
set -e

# Verifica a conexão com a internet
log_info "Verificando a conexão com a internet..."
if ! ping -q -c 1 -W 5 google.com >/dev/null 2>&1; then
  log_error "Nenhuma conexão com a internet detectada."
  exit 1
fi

CURRENT_KERNEL=$(uname -r)
KERNEL_BASE=$(echo "$CURRENT_KERNEL" | cut -d'-' -f1,2)

# Congela estritamente o Kernel ativo e metapacotes
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

# PROTEÇÃO DAS NICs BROADCOM
# Evita que o DKMS tente compilar o módulo bnxt_en e quebre a instalação do APT
log_info "Aplicando proteção para ignorar as NICs Broadcom (evitando falhas do DKMS no bnxt_en)..."
if command -v dkms &> /dev/null; then
  dkms remove -m bnxt_en -v 1.10.3.237.1.137.0 --all 2>/dev/null || true
fi

if ls /usr/src/bnxt_en-* &> /dev/null; then
  sed -i 's/^AUTOINSTALL=.*/AUTOINSTALL="no"/' /usr/src/bnxt_en-*/dkms.conf 2>/dev/null || true
fi

# LIMPEZA DE PACOTES CONFLITANTES E INSTALAÇÕES ANTIGAS
wait_for_apt_locks
log_info "Removendo pacotes conflitantes e resíduos de drivers NVIDIA/CUDA antigos..."
apt-get purge -y "*nvidia*" "*cuda*" "*cublas*" "*cufft*" "*cufile*" "*curand*" "*cusolver*" "*cusparse*" "*gds-tools*" "*npp*" "*nvjpeg*" "nsight*" "datacenter-gpu-manager*" 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Atualização do repositório e instalação das dependências básicas
wait_for_apt_locks
log_info "Atualizando os repositórios de pacotes do sistema..."
apt-get update -y

log_info "Instalando ferramentas básicas de compilação, DKMS e utilitários..."
apt-get install -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  build-essential dkms software-properties-common ca-certificates curl wget gnupg ubuntu-drivers-common alsa-utils snapd

# Garantia da presença dos cabeçalhos do Kernel ativo
wait_for_apt_locks
log_info "Garantindo cabeçalhos para a versão ativa ($KERNEL_BASE / $CURRENT_KERNEL)..."
apt-get install -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  linux-headers-"$KERNEL_BASE" linux-headers-"$CURRENT_KERNEL"

# LIMPEZA DO DKMS DA NVIDIA
log_info "Limpando módulos antigos da NVIDIA no DKMS para evitar erros de sobreposição..."
if command -v dkms &> /dev/null; then
  dkms status | grep -i nvidia | while read -r line; do
    NOME_MOD=$(echo "$line" | awk -F', ' '{print $1}')
    VERSAO_MOD=$(echo "$line" | awk -F', ' '{print $2}' | awk -F': ' '{print $1}')
    dkms remove -m "$NOME_MOD" -v "$VERSAO_MOD" --all 2>/dev/null || true
  done
fi

# Instala os drivers de GPU recomendados
wait_for_apt_locks
log_info "Executando a instalação automática de drivers do Ubuntu..."
ubuntu-drivers autoinstall

# Baixa e registra a chave do repositório oficial da NVIDIA CUDA
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

# Atualiza repositórios com CUDA
wait_for_apt_locks
log_info "Atualizando a lista de pacotes com repositórios da NVIDIA..."
apt-get update -y

# Instala o CUDA Toolkit
log_info "Instalando o CUDA Toolkit 13.3..."
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" cuda-toolkit-13-3

# Instalação do Datacenter GPU Manager
wait_for_apt_locks
log_info "Instalando o Datacenter GPU Manager para CUDA $CUDA_VERSION..."
apt-get install --yes \
                --install-recommends \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                datacenter-gpu-manager-4-cuda${CUDA_VERSION}

# Instala utilitários adicionais via Snap
log_info "Instalando o nvtop e gpu-burn via Snap..."
snap wait system seed
snap install nvtop || true
snap install gpu-burn || true

# Limpeza pós-instalação
wait_for_apt_locks
log_info "Realizando a limpeza pós-instalação..."
apt-get autoremove -y

log_success "Setup concluído! Drivers e dependências instalados (Kernel $CURRENT_KERNEL)."

# Desativa a interrupção imediata por erro para permitir os tratamentos manuais do script de teste
set +e


# ==============================================================================
# FASE 2: TESTE DE ESTRESSE DO DCGM
# ==============================================================================
echo -e "\n\n"
log_info "=== INICIANDO FASE 2: TESTE DE STRESS (DCGM) ==="

# Verifica se as ferramentas de GPU estão disponíveis
if ! nvidia-smi &> /dev/null; then
  log_error "O comando 'nvidia-smi' falhou. O driver da NVIDIA não está rodando."
  exit 1
fi

if ! command -v dcgmi &> /dev/null; then
  log_error "O utilitário 'dcgmi' não foi encontrado."
  exit 1
fi

# Configurações gerais do monitoramento
INTERVALO_CHECAGEM=1
TESTE_CMD="dcgmi diag -r 4"
LOG_ERRO_DCGM="/tmp/dcgm_teste_erro.log"
LOG_SAIDA_FINAL="/var/log/dcgm_test_output.log"

echo -e "\e[36m============================================================\e[0m"
echo -e " \e[1mINSTRUÇÕES DE RECONEXÃO E AUDITORIA DE TESTES:\e[0m"
echo -e " Se você se desconectar da sessão screen (\e[33mCtrl+A e depois D\e[0m):"
echo -e " 1. Para voltar ao terminal em tempo real e ver o teste rodando:"
echo -e "    \e[32msudo screen -r setup_teste_gpu\e[0m"
echo -e " 2. Para auditar os logs salvos (mesmo se o teste já tiver acabado):"
echo -e "    \e[32msudo cat $LOG_SAIDA_FINAL\e[0m"
echo -e "\e[36m============================================================\e[0m"

# Lógica de detecção de parâmetro ou menu interativo
if [ -z "$1" ]; then
  log_info "Nenhum parâmetro foi fornecido na inicialização."
  echo -e "\e[36m==================================================\e[0m"
  echo -e "   Selecione o modelo de GPU para o teste:"
  echo -e "   1) NVIDIA H100 (Limite Seguro: 85°C)"
  echo -e "   2) NVIDIA RTX 6000 (Limite Seguro: 95°C)"
  echo -e "   3) Cancelar e Sair"
  echo -e "\e[36m==================================================\e[0m"
  
  read -p "Digite o número correspondente (1, 2 ou 3): " escolha_menu
  echo ""

  case "$escolha_menu" in
    1) OPCAO_GPU="h100"; LIMITE_TEMP=85; NOME_PERFIL="NVIDIA H100 (Enterprise)" ;;
    2) OPCAO_GPU="rtx"; LIMITE_TEMP=95; NOME_PERFIL="NVIDIA RTX 6000 (Workstation)" ;;
    *) log_warn "Operação cancelada ou opção inválida. Encerrando."; exit 0 ;;
  esac
else
  OPCAO_GPU=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  if [ "$OPCAO_GPU" = "h100" ]; then
    LIMITE_TEMP=85; NOME_PERFIL="NVIDIA H100 (Enterprise)"
  elif [ "$OPCAO_GPU" = "rtx" ]; then
    LIMITE_TEMP=95; NOME_PERFIL="NVIDIA RTX 6000 (Workstation)"
  else
    log_error "Opção de parâmetro inválida: '$1'"
    echo -e "Opções válidas: h100 ou rtx"
    exit 1
  fi
fi

# Detecção de GPUs e Ativação do Persistence Mode
log_info "Detectando GPUs instaladas no sistema..."
QTD_GPUS=$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | wc -l)

if [ "$QTD_GPUS" -eq 0 ]; then
  log_error "Nenhuma GPU NVIDIA foi detectada pelo driver."
  exit 1
fi

log_success "Total de GPUs encontradas: $QTD_GPUS"
log_info "Habilitando Persistence Mode para todas as GPUs..."

for (( i=0; i<QTD_GPUS; i++ )); do
  if nvidia-smi -i "$i" -pm 1 &>/dev/null; then
    log_success "GPU $i: Persistence Mode ativado com sucesso!"
  else
    log_warn "GPU $i: Não foi possível ativar o Persistence Mode. Continuando..."
  fi
done

rm -f "$LOG_ERRO_DCGM"

# Inicia o teste do DCGM
log_info "Perfil selecionado: \e[1m$NOME_PERFIL\e[0m"
log_info "Iniciando o teste de estresse do DCGM: '$TESTE_CMD'..."
$TESTE_CMD > "$LOG_SAIDA_FINAL" 2>&1 &
PID_TESTE=$!

ln -sf "$LOG_SAIDA_FINAL" "$LOG_ERRO_DCGM"

log_success "Teste iniciado com sucesso! PID do processo: $PID_TESTE"
log_info "Para se desconectar com segurança sem parar o teste, aperte: Ctrl+A e depois D"
log_info "Monitorando temperaturas... Limite seguro definido em: \e[1;31m${LIMITE_TEMP}°C\e[0m"

FOI_INTERROMPIDO_POR_TEMP=false

# Loop de monitoramento em tempo real com validação estrita
while kill -0 "$PID_TESTE" 2>/dev/null; do
  if ! TEMPERATURAS=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null); then
    echo ""
    log_error "FALHA CRÍTICA: Perda de comunicação com o driver NVIDIA." | tee -a "$LOG_SAIDA_FINAL"
    kill -9 "$PID_TESTE" 2>/dev/null
    exit 1
  fi
  
  GPU_ID=0
  STATUS_LINE=""
  
  for TEMP in $TEMPERATURAS; do
    if ! [[ "$TEMP" =~ ^[0-9]+$ ]]; then
      echo ""
      log_error "FALHA CRÍTICA: Resposta inválida ao ler temperatura ($TEMP)." | tee -a "$LOG_SAIDA_FINAL"
      kill -9 "$PID_TESTE" 2>/dev/null
      exit 1
    fi

    if [ -z "$STATUS_LINE" ]; then
      STATUS_LINE="GPU $GPU_ID: ${TEMP}°C"
    else
      STATUS_LINE="$STATUS_LINE | GPU $GPU_ID: ${TEMP}°C"
    fi

    if [ "$TEMP" -ge "$LIMITE_TEMP" ]; then
      echo ""
      log_error "ALERTA TÉRMICO! GPU $GPU_ID atingiu ${TEMP}°C (Limite: ${LIMITE_TEMP}°C)!" | tee -a "$LOG_SAIDA_FINAL"
      log_warn "Interrompendo o teste do DCGM imediatamente para proteger o hardware..." | tee -a "$LOG_SAIDA_FINAL"
      
      FOI_INTERROMPIDO_POR_TEMP=true
      kill -9 "$PID_TESTE" 2>/dev/null
      wait "$PID_TESTE" 2>/dev/null
      
      log_success "Teste interrompido com segurança. Aguardando resfriamento das placas." | tee -a "$LOG_SAIDA_FINAL"
      rm -f "$LOG_ERRO_DCGM"
      exit 1
    fi
    GPU_ID=$((GPU_ID + 1))
  done
  
  echo -ne "\r\e[K[MONITOR] $STATUS_LINE"
  sleep "$INTERVALO_CHECAGEM"
done

wait "$PID_TESTE"
STATUS_FINAL=$?

echo ""

if [ $STATUS_FINAL -eq 0 ]; then
  log_success "O teste do DCGM foi concluído com sucesso e todas as GPUs operaram em temperaturas seguras!" | tee -a "$LOG_SAIDA_FINAL"
  log_info "A saída completa do diagnóstico foi arquivada em: $LOG_SAIDA_FINAL"
  rm -f "$LOG_ERRO_DCGM"
else
  if [ "$FOI_INTERROMPIDO_POR_TEMP" = false ]; then
    log_error "O teste do DCGM falhou por conta própria com o código de saída: $STATUS_FINAL" | tee -a "$LOG_SAIDA_FINAL"
    echo -e "\e[31m------------------ SAÍDA DE ERRO DO DCGM ------------------\e[0m"
    cat "$LOG_SAIDA_FINAL"
    echo -e "\e[31m-----------------------------------------------------------\e[0m"
    rm -f "$LOG_ERRO_DCGM"
  fi
fi
