#!/usr/bin/env bash

# Cores para o terminal
log_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
log_success() { echo -e "\e[32m[SUCESSO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[AVISO]\e[0m $1"; }
log_error() { echo -e "\e[31m[PERIGO]\e[0m $1"; }

# 1. Garante que o script seja executado como root (necessário para persistência e instalação do screen)
if [ "$EUID" -ne 0 ]; then
  log_error "Este script precisa ser executado com sudo."
  exit 1
fi

# Bloqueia atualizações do Kernel do host antes de qualquer comando do APT
CURRENT_KERNEL=$(uname -r)
log_info "Bloqueando atualizações do kernel atual ($CURRENT_KERNEL) e metapacotes..."
apt-mark hold \
  linux-image-generic \
  linux-headers-generic \
  linux-generic \
  "linux-image-$CURRENT_KERNEL" \
  "linux-headers-$CURRENT_KERNEL" \
  "linux-modules-$CURRENT_KERNEL" \
  "linux-modules-extra-$CURRENT_KERNEL" >/dev/null 2>&1 || true

# Configurações gerais do monitoramento
INTERVALO_CHECAGEM=1    # Intervalo de verificação em segundos
TESTE_CMD="dcgmi diag -r 4" # Comando de estresse completo nível 4 do DCGM
LOG_ERRO_DCGM="/tmp/dcgm_teste_erro.log" # Log temporário interno
LOG_SAIDA_FINAL="/var/log/dcgm_test_output.log" # Log permanente de auditoria do teste

# INSTRUÇÕES DE RECONEXÃO E AUDITORIA AO FINALIZAR COM SUCESSO OU ERRO
echo -e "\n\e[36m============================================================\e[0m"
echo -e " \e[1mINSTRUÇÕES DE RECONEXÃO E AUDITORIA DE TESTES:\e[0m"
echo -e " Se você se desconectar da sessão screen (\e[33mCtrl+A e depois D\e[0m):"
echo -e " 1. Para voltar ao terminal em tempo real e ver o teste rodando:"
echo -e "    \e[32msudo screen -r teste_gpu\e[0m"
echo -e " 2. Para auditar os logs salvos (mesmo se o teste já tiver acabado):"
echo -e "    \e[32msudo cat $LOG_SAIDA_FINAL\e[0m"
echo -e "\e[36m============================================================\e[0m"

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
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y screen
  fi

  NOME_SESSAO="teste_gpu"
  log_info "Criando uma nova sessão screen chamada: '$NOME_SESSAO'..."
  
  SCRIPT_PATH=$(realpath "$0")
  ARGUMENTOS="$@"

  sleep 1.5

  exec sudo screen -S "$NOME_SESSAO" bash -c "sudo -E $SCRIPT_PATH $ARGUMENTOS; echo -e '\nPressione qualquer tecla para fechar esta screen...'; read -n 1"
fi
# ==============================================================================

# 2. Verifica se as ferramentas de GPU estão disponíveis
if ! nvidia-smi &> /dev/null; then
  log_error "O comando 'nvidia-smi' falhou. O driver da NVIDIA não está rodando ou precisa ser recarregado."
  exit 1
fi

if ! command -v dcgmi &> /dev/null; then
  log_error "O utilitário 'dcgmi' não foi encontrado. Certifique-se de instalar o datacenter-gpu-manager."
  exit 1
fi

# 3. Lógica de detecção de parâmetro ou menu interativo
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
    1)
      OPCAO_GPU="h100"
      LIMITE_TEMP=85
      NOME_PERFIL="NVIDIA H100 (Enterprise)"
      ;;
    2)
      OPCAO_GPU="rtx"
      LIMITE_TEMP=95
      NOME_PERFIL="NVIDIA RTX 6000 (Workstation)"
      ;;
    *)
      log_warn "Operação cancelada ou opção inválida. Encerrando."
      exit 0
      ;;
  esac
else
  OPCAO_GPU=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  if [ "$OPCAO_GPU" = "h100" ]; then
    LIMITE_TEMP=85
    NOME_PERFIL="NVIDIA H100 (Enterprise)"
  elif [ "$OPCAO_GPU" = "rtx" ]; then
    LIMITE_TEMP=95
    NOME_PERFIL="NVIDIA RTX 6000 (Workstation)"
  else
    log_error "Opção de parâmetro inválida: '$1'"
    echo -e "Opções válidas disponíveis via linha de comando: h100 ou rtx"
    echo -e "Exemplo: sudo bash $0 h100"
    exit 1
  fi
fi

# 4. Detecção de GPUs e Ativação do Persistence Mode
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

# 5. Inicia o teste do DCGM
log_info "Perfil selecionado: \e[1m$NOME_PERFIL\e[0m"
log_info "Iniciando o teste de estresse do DCGM: '$TESTE_CMD'..."
$TESTE_CMD > "$LOG_SAIDA_FINAL" 2>&1 &
PID_TESTE=$!

ln -sf "$LOG_SAIDA_FINAL" "$LOG_ERRO_DCGM"

log_success "Teste iniciado com sucesso! PID do processo: $PID_TESTE"
log_info "Para se desconectar com segurança sem parar o teste, aperte: Ctrl+A e depois D"
log_info "Monitorando temperaturas... Limite seguro definido em: \e[1;31m${LIMITE_TEMP}°C\e[0m"

FOI_INTERROMPIDO_POR_TEMP=false

# 6. Loop de monitoramento em tempo real com validação estrita
while kill -0 "$PID_TESTE" 2>/dev/null; do
  # Captura as temperaturas tratando falha de execução do comando
  if ! TEMPERATURAS=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null); then
    echo ""
    log_error "FALHA CRÍTICA: Perda de comunicação com o driver NVIDIA (nvidia-smi parou de responder)." | tee -a "$LOG_SAIDA_FINAL"
    kill -9 "$PID_TESTE" 2>/dev/null
    exit 1
  fi
  
  GPU_ID=0
  STATUS_LINE=""
  
  for TEMP in $TEMPERATURAS; do
    # Valida se o valor retornado é realmente um número inteiro
    if ! [[ "$TEMP" =~ ^[0-9]+$ ]]; then
      echo ""
      log_error "FALHA CRÍTICA: Resposta inválida ao ler temperatura ($TEMP). O driver da GPU falhou." | tee -a "$LOG_SAIDA_FINAL"
      kill -9 "$PID_TESTE" 2>/dev/null
      exit 1
    fi

    if [ -z "$STATUS_LINE" ]; then
      STATUS_LINE="GPU $GPU_ID: ${TEMP}°C"
    else
      STATUS_LINE="$STATUS_LINE | GPU $GPU_ID: ${TEMP}°C"
    fi

    # Disparo de segurança térmica
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
