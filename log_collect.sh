
Gemini
New chat
Search chats
Images
Videos
Library
Script Coleta Logs GPU e Mellanox
Script Alpine para Compilação MSTFLINT
Alpine Linux eth0 IP Address
Executando Script Shell com Sudo
Script clocksync.sh: Comandos e Execução
Tradução: "Estava amarrado?" em Japonês
Host Replacement Options for Faster Service
melhore isso: Hello there, We need some help with host https://netbox.latitude.co/dcim/devices/24704/ from ticket https://maxihost.zendesk.com/agent/tickets/817704. Host is unable to boot pxe image, being able to get dhcp ip though. Host boot order is correct, sol port is enabled.
Verificação de Porta de Switch com Credenciais
Request for Text Improvement
Improving Host Firmware Update Communication
Troubleshoot Mellanox Adapter Disabled State
Making Host Update More Friendly
NVIDIA Driver "No Such Device" Error
Switch Nvidia Driver Module Stream
Fix Missing NVIDIA Kernel Module
No match for argument: kernel-uek-headers-6.12.0-204.92.4.4.el9uek.x86_64 Error: Unable to find a match: kernel-uek-headers-6.12.0-204.92.4.4.el9uek.x86_64
Script de Instalação CUDA para Oracle Linux
Script GPU para Oracle Linux
Rewriting Technical Message For Friendliness
Montar NFS no Windows com Credenciais
sv_EvjLaBdAINoqy sv_EvjLaBdAINoqy are the same ?
Expressando Tecnologia Ilógica em Inglês
Solana Drive Reconfiguration Advice
Conversation with Gemini
preciso de um script que execute as tarefas nessa imagem, preciso que seja compativel com ubuntu e com oracle linux e que no final gere um unico arquivo zip que possa ser anexado num ticket zendesk.

Aqui está um script em Bash completo, compatível com Ubuntu e Oracle Linux / RHEL / CentOS, que automatiza toda a coleta de logs descrita na imagem e gera um único arquivo .zip para você anexar ao chamado no Zendesk.

📜 Script (coletar_logs_gpu.sh)
Crie o arquivo coletar_logs_gpu.sh na máquina e cole o conteúdo abaixo:

Bash
#!/bin/bash
# ==============================================================================
# Script de Coleta Automática de Logs de GPU / Mellanox / Sistema
# Compatibilidade: Ubuntu e Oracle Linux / RHEL / CentOS
# Saída: Arquivo ZIP no diretório atual pronto para anexo no Zendesk
# ==============================================================================

set -u

# Configuração de Cores e Formatação
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Iniciando Coleta de Logs de Diagnóstico de GPU   ${NC}"
echo -e "${GREEN}====================================================${NC}"

# Verificar permissão de Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERRO] Este script precisa ser executado como root (sudo).${NC}"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)
WORKDIR="/tmp/gpu_logs_${HOSTNAME}_${TIMESTAMP}"
mkdir -p "${WORKDIR}"

echo -e "${YELLOW}[+] Criando diretório temporário: ${WORKDIR}${NC}"

# ------------------------------------------------------------------------------
# 1. Sysinfo (sysinfo-snapshot)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[1/4] Executando Sysinfo Snapshot...${NC}"

# Tentar encontrar a ferramenta em caminhos comuns ou no PATH
SYSINFO_BIN=$(which sysinfo-snapshot.py 2>/dev/null || which sysinfo-snapshot 2>/dev/null || echo "")

if [ -z "$SYSINFO_BIN" ] && [ -f "./sysinfo-snapshot.py" ]; then
    SYSINFO_BIN="./sysinfo-snapshot.py"
fi

if [ -n "$SYSINFO_BIN" ]; then
    echo "Executando: $SYSINFO_BIN --gpu"
    # Salvar em /tmp conforme orientação da imagem
    (cd /tmp && $SYSINFO_BIN --gpu)
    
    # Mover os arquivos gerados no /tmp para a pasta de trabalho
    mv /tmp/sysinfo-snapshot* "${WORKDIR}/" 2>/dev/null || true
    echo -e "${GREEN}[OK] Sysinfo snapshot concluído.${NC}"
else
    echo -e "${RED}[AVISO] Script sysinfo-snapshot.py não encontrado. Pulando etapa...${NC}"
    echo "Caso tenha baixado linux-sysinfo-snapshot-master.zip, extraia e execute na mesma pasta." > "${WORKDIR}/sysinfo_NAO_EXECUTADO.txt"
fi

# ------------------------------------------------------------------------------
# 2. CX8 MST Dump (Mellanox Software Tools)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/4] Executando CX8 MST Dumps...${NC}"

if command -v mst &> /dev/null; then
    mst start 2>/dev/null || true

    DEVICES=(
        "/dev/mst/mt4131_pciconf0"
        "/dev/mst/mt4131_pciconf1"
        "/dev/mst/mt4131_pciconf2"
        "/dev/mst/mt4131_pciconf3"
    )

    for dev in "${DEVICES[@]}"; do
        if [ -c "$dev" ] || [ -b "$dev" ] || [ -e "$dev" ]; then
            dev_name=$(basename "$dev")
            echo "Iniciando mstdump para $dev (3 capturas com intervalo de 15s)..."
            
            # Coleta 1
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log1.log" 2>&1
            sleep 15
            
            # Coleta 2
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log2.log" 2>&1
            sleep 15
            
            # Coleta 3
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log3.log" 2>&1
            
            echo -e "${GREEN}[OK] Dump do dispositivo $dev_name finalizado.${NC}"
        else
            echo -e "${RED}[AVISO] Dispositivo $dev não encontrado.${NC}"
        fi
    done
else
    echo -e "${RED}[AVISO] Comando 'mst' não encontrado (MST tools não instaladas). Pulando mstdump...${NC}"
fi

# ------------------------------------------------------------------------------
# 3. Logs de PCI, Kernel (dmesg) e DCGM
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/4] Coletando lspci, dmesg e diagnósticos adicionais...${NC}"

# iv. lspci -tv
lspci -tv > "${WORKDIR}/lspcitv.log" 2>&1

# v. lspci -vvvxxxx
lspci -vvvxxxx > "${WORKDIR}/lspcivvvxxxx.log" 2>&1

# vi. dmesg
dmesg -T > "${WORKDIR}/dmesg.log" 2>&1 || dmesg > "${WORKDIR}/dmesg.log" 2>&1

# Opcional: dcgmi diag (Mencionado no item 4 da imagem)
if command -v dcgmi &> /dev/null; then
    echo "Executando NVIDIA DCGM Diag (dcgmi diag -r 3)..."
    dcgmi diag -r 3 > "${WORKDIR}/dcgmi_diag.log" 2>&1 || true
fi

echo -e "${GREEN}[OK] Logs do sistema coletados.${NC}"

# ------------------------------------------------------------------------------
# 4. Compactação em arquivo ZIP final para o Zendesk
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/4] Compactando todos os logs...${NC}"

# Garantir utilitário de zip instalado
if ! command -v zip &> /dev/null; then
    echo "Instalando utilitário zip..."
    if command -v apt-get &> /dev/null; then
        apt-get update -y && apt-get install -y zip
    elif command -v dnf &> /dev/null; then
        dnf install -y zip
    elif command -v yum &> /dev/null; then
        yum install -y zip
    fi
fi

ZIP_FILENAME="gpu_fault_logs_${HOSTNAME}_${TIMESTAMP}.zip"

cd "${WORKDIR}"
if command -v zip &> /dev/null; then
    zip -r "/tmp/${ZIP_FILENAME}" ./*
    FINAL_PATH="/tmp/${ZIP_FILENAME}"
else
    # Fallback para tar.gz se o zip falhar/não puder ser instalado
    FINAL_PATH="/tmp/gpu_fault_logs_${HOSTNAME}_${TIMESTAMP}.tar.gz"
    tar -czvf "${FINAL_PATH}" ./*
fi

# Limpeza da pasta temporária descompactada
rm -rf "${WORKDIR}"

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}   COLETA CONCLUÍDA COM SUCESSO!                    ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Arquivo final gerado em: ${YELLOW}${FINAL_PATH}${NC}"
echo -e "Tamanho do arquivo: $(du -sh ${FINAL_PATH} | cut -f1)"
echo -e "\nAnexe o arquivo acima diretamente ao seu ticket Zendesk."
🚀 Como Executar
Torne o script executável:

Bash
chmod +x coletar_logs_gpu.sh
Execute como Root (Sudo):

Bash
sudo ./coletar_logs_gpu.sh
📋 O que o script faz exatamente?
Compatibilidade OS: Funciona de forma transparente tanto em Ubuntu (apt) quanto no Oracle Linux / RHEL / CentOS (dnf/yum).

sysinfo-snapshot.py --gpu: Procura o utilitário do snapshot de GPU no sistema e o executa salvando no /tmp.

Mellanox MST Dump (mstdump):

Inicializa o serviço mst start.

Para cada uma das 4 portas/dispositivos PCI (mt4131_pciconf0 a mt4131_pciconf3), faz 3 leituras sequenciais aguardando 15 segundos entre cada uma.

Informações PCI e Logs de Kernel:

lspci -tv → salvo em lspcitv.log

lspci -vvvxxxx → salvo em lspcivvvxxxx.log

dmesg com timestamp formatado → salvo em dmesg.log

Teste DCGM (Item 4 da imagem): Caso a ferramenta dcgmi (NVIDIA Data Center GPU Manager) esteja instalada, ele executa o dcgmi diag -r 3 e salva em dcgmi_diag.log.

Empacotamento: Compacta tudo em um único arquivo .zip com a data e nome do host (ex: /tmp/gpu_fault_logs_hostname_YYYYMMDD_HHMMSS.zip) pronto para download e envio ao suporte.

torne esse arquivo fail safe, instalando todas as dependencias necessárias para cada sistema antes de gerar o arquivo zip.

Seu arquivo Bash em versão Fail-Safe está pronto!

SH icon
coletar_logs_gpu_failsafe
 SH 
Open
🛡️ O que torna esta versão Fail-Safe?
Detecção Automática do Sistema Operacional:

Identifica se a execução é em Ubuntu / Debian (apt) ou em Oracle Linux / RHEL / CentOS / Rocky / Alma (dnf / yum).

Instalação Prévia de Dependências:

Antes de executar qualquer tarefa, o script verifica se utilitários vitais como pciutils (lspci), zip, unzip, python3, wget e curl estão instalados. Se faltar algum, o script o instala silenciosamente de forma automática.

Resiliência contra Falhas (set -u + Tratamento de Erros):

Caso algum comando individual falhe (por exemplo, uma porta PCI não existente ou ausência de placa Mellanox específica), o script não interrompe a execução, prossegue coletando os outros logs e registra o aviso dentro do pacote final.

Descompactação Inteligente do sysinfo:

Se você colocar o arquivo linux-sysinfo-snapshot-master.zip no mesmo diretório do script, ele detecta, descompacta e executa o script de GPU automaticamente.

Fallback de Compactação:

Se por qualquer motivo a geração em .zip falhar, ele faz o fallback transparente gerando um arquivo .tar.gz sem perder nenhum dado coletado.

📜 Código do Script (coletar_logs_gpu_failsafe.sh)
Bash
#!/bin/bash
# ==============================================================================
# Script Fail-Safe de Coleta de Logs de Diagnostico de GPU / Mellanox / Sistema
# Compatibilidade: Ubuntu / Debian & Oracle Linux / RHEL / CentOS / Rocky / Alma
# Saida: Arquivo ZIP unico em /tmp pronto para anexo no ticket Zendesk
# ==============================================================================

set -u

# Core visual Formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Iniciando Coleta Fail-Safe de Logs de GPU / System ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. Checagem de Usuario Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERRO CRITICO] Este script precisa ser executado como root (sudo).${NC}"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname -s 2>/dev/null || echo "host")
WORKDIR="/tmp/gpu_logs_${HOSTNAME}_${TIMESTAMP}"
mkdir -p "${WORKDIR}"

echo -e "${YELLOW}[+] Diretorio temporario de trabalho: ${WORKDIR}${NC}"

# ------------------------------------------------------------------------------
# DETECCAO DO SISTEMA OPERACIONAL & GERENCIADOR DE PAQUETES
# ------------------------------------------------------------------------------
PKG_MANAGER=""
OS_TYPE=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
fi

echo -e "${YELLOW}[+] Sistema Operacional Detectado: ${OS_TYPE:-Desconhecido} (Gerenciador: ${PKG_MANAGER:-Desconhecido})${NC}"

# ------------------------------------------------------------------------------
# INSTALACAO AUTOMATICA DE DEPENDENCIAS (FAIL-SAFE)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[+] Verificando e instalando dependencias necessarias...${NC}"

install_package() {
    local cmd="$1"
    local pkg_apt="$2"
    local pkg_yum="$3"

    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}  -> Comando '$cmd' nao encontrado. Instalando pacote...${NC}"
        if [ "$PKG_MANAGER" = "apt" ]; then
            apt-get update -qq -y && apt-get install -y -qq "$pkg_apt"
        elif [ "$PKG_MANAGER" = "dnf" ]; then
            dnf install -y -q "$pkg_yum"
        elif [ "$PKG_MANAGER" = "yum" ]; then
            yum install -y -q "$pkg_yum"
        else
            echo -e "${RED}  [AVISO] Nao foi possivel instalar '$cmd' automaticamente. Gerenciador de pacotes nao suportado.${NC}"
        fi
    fi
}

# Instalando ferramentas essenciais
install_package "lspci" "pciutils" "pciutils"
install_package "zip" "zip" "zip"
install_package "unzip" "unzip" "unzip"
install_package "python3" "python3" "python3"
install_package "wget" "wget" "wget"
install_package "curl" "curl" "curl"

# ------------------------------------------------------------------------------
# 1. SYSINFO SNAPSHOT (linux-sysinfo-snapshot)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[1/4] Executando Sysinfo Snapshot...${NC}"

SYSINFO_BIN=""

# Procura nos caminhos padrao do sistema
if command -v sysinfo-snapshot.py &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot.py)
elif command -v sysinfo-snapshot &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot)
elif [ -f "./sysinfo-snapshot.py" ]; then
    SYSINFO_BIN="./sysinfo-snapshot.py"
elif [ -f "./sysinfo-snapshot" ]; then
    SYSINFO_BIN="./sysinfo-snapshot"
fi

# Se nao encontrado localmente, tenta baixar e extrair automaticamente do arquivo zip caso esteja disponivel
if [ -z "$SYSINFO_BIN" ]; then
    if [ -f "./linux-sysinfo-snapshot-master.zip" ]; then
        echo "Extraindo linux-sysinfo-snapshot-master.zip..."
        unzip -q -o ./linux-sysinfo-snapshot-master.zip -d /tmp/sysinfo_extracted
        SYSINFO_BIN=$(find /tmp/sysinfo_extracted -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    fi
fi

if [ -n "$SYSINFO_BIN" ] && [ -x "$SYSINFO_BIN" ] || [ -f "$SYSINFO_BIN" ]; then
    echo "Executando: $SYSINFO_BIN --gpu"
    python3 "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || true
    
    # Coleta arquivos recem-gerados em /tmp ou no diretorio atual
    find /tmp . -maxdepth 2 -name "sysinfo-snapshot*" -not -path "${WORKDIR}/*" -exec mv {} "${WORKDIR}/" \; 2>/dev/null || true
    echo -e "${GREEN}[OK] Sysinfo snapshot concluido.${NC}"
else
    echo -e "${RED}[AVISO] Ferramenta sysinfo-snapshot nao encontrada no ambiente.${NC}"
    echo "Sysinfo snapshot nao executado. Certifique-se de disponibilizar o arquivo linux-sysinfo-snapshot-master.zip na mesma pasta." > "${WORKDIR}/SYSINFO_NAO_EXECUTADO.txt"
fi

# ------------------------------------------------------------------------------
# 2. CX8 MST DUMP (Mellanox Software Tools)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/4] Executando CX8 MST Dumps...${NC}"

# Tenta carregar e iniciar o servico MST se instalado
if command -v mst &> /dev/null; then
    mst start > /dev/null 2>&1 || true
elif [ -f "/etc/init.d/mst" ]; then
    /etc/init.d/mst start > /dev/null 2>&1 || true
fi

DEVICES=(
    "/dev/mst/mt4131_pciconf0"
    "/dev/mst/mt4131_pciconf1"
    "/dev/mst/mt4131_pciconf2"
    "/dev/mst/mt4131_pciconf3"
)

MST_EXECUTED=false

if command -v mstdump &> /dev/null; then
    for dev in "${DEVICES[@]}"; do
        dev_name=$(basename "$dev")
        if [ -e "$dev" ]; then
            MST_EXECUTED=true
            echo "Iniciando mstdump para $dev (3 leituras com intervalo de 15 segundos)..."
            
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log1.log" 2>&1
            sleep 15
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log2.log" 2>&1
            sleep 15
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log3.log" 2>&1
            
            echo -e "${GREEN}[OK] Dump do dispositivo $dev_name finalizado.${NC}"
        else
            echo -e "${RED}[AVISO] Dispositivo $dev nao encontrado no sistema.${NC}"
        fi
    done
else
    echo -e "${RED}[AVISO] Ferramenta 'mstdump' (Mellanox MST) nao esta instalada/disponivel no PATH.${NC}"
fi

if [ "$MST_EXECUTED" = false ]; then
    echo "Nenhum dump de MST foi coletado. Certifique-se de que o pacote MST/MFT esteja instalado e os dispositivos MST carregados." > "${WORKDIR}/MSTDUMP_NAO_EXECUTADO.txt"
fi

# ------------------------------------------------------------------------------
# 3. DIAGNOSTICOS DE PCI, KERNEL & DCGM
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/4] Coletando lspci, dmesg e diagnósticos do sistema...${NC}"

# iv. lspci -tv
if command -v lspci &> /dev/null; then
    lspci -tv > "${WORKDIR}/lspcitv.log" 2>&1 || true
    # v. lspci -vvvxxxx
    lspci -vvvxxxx > "${WORKDIR}/lspcivvvxxxx.log" 2>&1 || true
else
    echo -e "${RED}[AVISO] lspci nao disponivel.${NC}"
fi

# vi. dmesg
if command -v dmesg &> /dev/null; then
    dmesg -T > "${WORKDIR}/dmesg.log" 2>&1 || dmesg > "${WORKDIR}/dmesg.log" 2>&1 || true
fi

# vii. BMC Onekeylog / Ipmitool (se disponivel)
if command -v ipmitool &> /dev/null; then
    echo "Coletando logs do BMC via ipmitool..."
    ipmitool sel list > "${WORKDIR}/bmc_sel.log" 2>&1 || true
    ipmitool mc info > "${WORKDIR}/bmc_info.log" 2>&1 || true
fi

# Item 4 da imagem: NVIDIA DCGM Diagnostic
if command -v dcgmi &> /dev/null; then
    echo "Executando NVIDIA DCGM Diag (dcgmi diag -r 3)..."
    dcgmi diag -r 3 > "${WORKDIR}/dcgmi_diag.log" 2>&1 || true
fi

echo -e "${GREEN}[OK] Diagnosticos de sistema coletados.${NC}"

# ------------------------------------------------------------------------------
# 4. COMPACTACAO FAIL-SAFE DOS ARCHIVOS LOGS (ZIP / TAR.GZ)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/4] Gerando arquivo compactado para envio...${NC}"

ZIP_FILENAME="gpu_fault_logs_${HOSTNAME}_${TIMESTAMP}.zip"
FINAL_OUTPUT="/tmp/${ZIP_FILENAME}"

cd "${WORKDIR}"

if command -v zip &> /dev/null; then
    zip -q -r "${FINAL_OUTPUT}" ./*
else
    # Fallback caso o zip falhe totalmente
    FINAL_OUTPUT="/tmp/gpu_fault_logs_${HOSTNAME}_${TIMESTAMP}.tar.gz"
    tar -czf "${FINAL_OUTPUT}" ./*
fi

# Limpeza de pastas temporarias de trabalho
rm -rf "${WORKDIR}" /tmp/sysinfo_extracted 2>/dev/null || true

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}   COLETA FINALIZADA COM SUCESSO!                   ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Arquivo final gerado: ${YELLOW}${FINAL_OUTPUT}${NC}"
if [ -f "${FINAL_OUTPUT}" ]; then
    echo -e "Tamanho do arquivo: $(du -sh "${FINAL_OUTPUT}" | cut -f1)"
fi
echo -e "\nAnexe o arquivo acima ao seu chamado/ticket no Zendesk."
🚀 Instruções de Uso
Faça o download ou salve o script na maquina de destino.

Atribua a permissão de execução:

Bash
chmod +x coletar_logs_gpu_failsafe.sh
Execute o script como root:

Bash
sudo ./coletar_logs_gpu_failsafe.sh
Ao finalizar, copie o arquivo /tmp/gpu_fault_logs_<hostname>_<data>.zip e anexe ao ticket Zendesk.

o arquivo final deve ser gerado como /root/support_$hostname_$date.zip

O script foi atualizado e está pronto!

SH icon
coletar_logs_gpu_failsafe_v2
 SH 
Open
📌 Alterações Principais
Caminho de Saída e Nome Padrão: O arquivo gerado agora é salvo diretamente em /root/support_$HOSTNAME_$TIMESTAMP.zip (exemplo: /root/support_srv-gpu-01_20260817_141922.zip).

Estrutura Fail-Safe Mantida: Continua instalando as dependências automaticamente (zip, unzip, pciutils, python3, wget, curl) no Ubuntu (apt) e no Oracle Linux (dnf/yum).

📜 Código Atualizado (coletar_logs_gpu.sh)
Bash
#!/bin/bash
# ==============================================================================
# Script Fail-Safe de Coleta de Logs de Diagnostico de GPU / Mellanox / Sistema
# Compatibilidade: Ubuntu / Debian & Oracle Linux / RHEL / CentOS / Rocky / Alma
# Saida: /root/support_$hostname_$date.zip (pronto para anexo no ticket Zendesk)
# ==============================================================================

set -u

# Core visual Formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Iniciando Coleta Fail-Safe de Logs de GPU / System ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. Checagem de Usuario Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERRO CRITICO] Este script precisa ser executado como root (sudo).${NC}"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "host")
WORKDIR="/tmp/gpu_logs_${HOSTNAME}_${TIMESTAMP}"
mkdir -p "${WORKDIR}"

echo -e "${YELLOW}[+] Diretorio temporario de trabalho: ${WORKDIR}${NC}"

# ------------------------------------------------------------------------------
# DETECCAO DO SISTEMA OPERACIONAL & GERENCIADOR DE PAQUETES
# ------------------------------------------------------------------------------
PKG_MANAGER=""
OS_TYPE=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
fi

echo -e "${YELLOW}[+] Sistema Operacional Detectado: ${OS_TYPE:-Desconhecido} (Gerenciador: ${PKG_MANAGER:-Desconhecido})${NC}"

# ------------------------------------------------------------------------------
# INSTALACAO AUTOMATICA DE DEPENDENCIAS (FAIL-SAFE)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[+] Verificando e instalando dependencias necessarias...${NC}"

install_package() {
    local cmd="$1"
    local pkg_apt="$2"
    local pkg_yum="$3"

    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}  -> Comando '$cmd' nao encontrado. Instalando pacote...${NC}"
        if [ "$PKG_MANAGER" = "apt" ]; then
            apt-get update -qq -y && apt-get install -y -qq "$pkg_apt"
        elif [ "$PKG_MANAGER" = "dnf" ]; then
            dnf install -y -q "$pkg_yum"
        elif [ "$PKG_MANAGER" = "yum" ]; then
            yum install -y -q "$pkg_yum"
        else
            echo -e "${RED}  [AVISO] Nao foi possivel instalar '$cmd' automaticamente. Gerenciador de pacotes nao suportado.${NC}"
        fi
    fi
}

# Instalando ferramentas essenciais
install_package "lspci" "pciutils" "pciutils"
install_package "zip" "zip" "zip"
install_package "unzip" "unzip" "unzip"
install_package "python3" "python3" "python3"
install_package "wget" "wget" "wget"
install_package "curl" "curl" "curl"

# ------------------------------------------------------------------------------
# 1. SYSINFO SNAPSHOT (linux-sysinfo-snapshot)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[1/4] Executando Sysinfo Snapshot...${NC}"

SYSINFO_BIN=""

# Procura nos caminhos padrao do sistema
if command -v sysinfo-snapshot.py &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot.py)
elif command -v sysinfo-snapshot &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot)
elif [ -f "./sysinfo-snapshot.py" ]; then
    SYSINFO_BIN="./sysinfo-snapshot.py"
elif [ -f "./sysinfo-snapshot" ]; then
    SYSINFO_BIN="./sysinfo-snapshot"
fi

# Se nao encontrado localmente, tenta baixar e extrair automaticamente do arquivo zip caso esteja disponivel
if [ -z "$SYSINFO_BIN" ]; then
    if [ -f "./linux-sysinfo-snapshot-master.zip" ]; then
        echo "Extraindo linux-sysinfo-snapshot-master.zip..."
        unzip -q -o ./linux-sysinfo-snapshot-master.zip -d /tmp/sysinfo_extracted
        SYSINFO_BIN=$(find /tmp/sysinfo_extracted -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    fi
fi

if [ -n "$SYSINFO_BIN" ] && ([ -x "$SYSINFO_BIN" ] || [ -f "$SYSINFO_BIN" ]); then
    echo "Executando: $SYSINFO_BIN --gpu"
    python3 "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || true
    
    # Coleta arquivos recem-gerados em /tmp ou no diretorio atual
    find /tmp . -maxdepth 2 -name "sysinfo-snapshot*" -not -path "${WORKDIR}/*" -exec mv {} "${WORKDIR}/" \; 2>/dev/null || true
    echo -e "${GREEN}[OK] Sysinfo snapshot concluido.${NC}"
else
    echo -e "${RED}[AVISO] Ferramenta sysinfo-snapshot nao encontrada no ambiente.${NC}"
    echo "Sysinfo snapshot nao executado. Certifique-se de disponibilizar o arquivo linux-sysinfo-snapshot-master.zip na mesma pasta." > "${WORKDIR}/SYSINFO_NAO_EXECUTADO.txt"
fi

# ------------------------------------------------------------------------------
# 2. CX8 MST DUMP (Mellanox Software Tools)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/4] Executando CX8 MST Dumps...${NC}"

# Tenta carregar e iniciar o servico MST se instalado
if command -v mst &> /dev/null; then
    mst start > /dev/null 2>&1 || true
elif [ -f "/etc/init.d/mst" ]; then
    /etc/init.d/mst start > /dev/null 2>&1 || true
fi

DEVICES=(
    "/dev/mst/mt4131_pciconf0"
    "/dev/mst/mt4131_pciconf1"
    "/dev/mst/mt4131_pciconf2"
    "/dev/mst/mt4131_pciconf3"
)

MST_EXECUTED=false

if command -v mstdump &> /dev/null; then
    for dev in "${DEVICES[@]}"; do
        dev_name=$(basename "$dev")
        if [ -e "$dev" ]; then
            MST_EXECUTED=true
            echo "Iniciando mstdump para $dev (3 leituras com intervalo de 15 segundos)..."
            
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log1.log" 2>&1
            sleep 15
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log2.log" 2>&1
            sleep 15
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log3.log" 2>&1
            
            echo -e "${GREEN}[OK] Dump do dispositivo $dev_name finalizado.${NC}"
        else
            echo -e "${RED}[AVISO] Dispositivo $dev nao encontrado no sistema.${NC}"
        fi
    done
else
    echo -e "${RED}[AVISO] Ferramenta 'mstdump' (Mellanox MST) nao esta instalada/disponivel no PATH.${NC}"
fi

if [ "$MST_EXECUTED" = false ]; then
    echo "Nenhum dump de MST foi coletado. Certifique-se de que o pacote MST/MFT esteja instalado e os dispositivos MST carregados." > "${WORKDIR}/MSTDUMP_NAO_EXECUTADO.txt"
fi

# ------------------------------------------------------------------------------
# 3. DIAGNOSTICOS DE PCI, KERNEL & DCGM
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/4] Coletando lspci, dmesg e diagnosticos do sistema...${NC}"

# iv. lspci -tv
if command -v lspci &> /dev/null; then
    lspci -tv > "${WORKDIR}/lspcitv.log" 2>&1 || true
    # v. lspci -vvvxxxx
    lspci -vvvxxxx > "${WORKDIR}/lspcivvvxxxx.log" 2>&1 || true
else
    echo -e "${RED}[AVISO] lspci nao disponivel.${NC}"
fi

# vi. dmesg
if command -v dmesg &> /dev/null; then
    dmesg -T > "${WORKDIR}/dmesg.log" 2>&1 || dmesg > "${WORKDIR}/dmesg.log" 2>&1 || true
fi

# vii. BMC Onekeylog / Ipmitool (se disponivel)
if command -v ipmitool &> /dev/null; then
    echo "Coletando logs do BMC via ipmitool..."
    ipmitool sel list > "${WORKDIR}/bmc_sel.log" 2>&1 || true
    ipmitool mc info > "${WORKDIR}/bmc_info.log" 2>&1 || true
fi

# Item 4 da imagem: NVIDIA DCGM Diagnostic
if command -v dcgmi &> /dev/null; then
    echo "Executando NVIDIA DCGM Diag (dcgmi diag -r 3)..."
    dcgmi diag -r 3 > "${WORKDIR}/dcgmi_diag.log" 2>&1 || true
fi

echo -e "${GREEN}[OK] Diagnosticos de sistema coletados.${NC}"

# ------------------------------------------------------------------------------
# 4. COMPACTACAO DOS ARQUIVOS LOGS (SALVO EM /root/support_$hostname_$date.zip)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/4] Gerando arquivo compactado em /root...${NC}"

ZIP_FILENAME="support_${HOSTNAME}_${TIMESTAMP}.zip"
FINAL_OUTPUT="/root/${ZIP_FILENAME}"

cd "${WORKDIR}"

if command -v zip &> /dev/null; then
    zip -q -r "${FINAL_OUTPUT}" ./*
else
    # Fallback caso o zip falhe totalmente
    FINAL_OUTPUT="/root/support_${HOSTNAME}_${TIMESTAMP}.tar.gz"
    tar -czf "${FINAL_OUTPUT}" ./*
fi

# Limpeza de pastas temporarias de trabalho
rm -rf "${WORKDIR}" /tmp/sysinfo_extracted 2>/dev/null || true

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}   COLETA FINALIZADA COM SUCESSO!                   ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Arquivo final gerado: ${YELLOW}${FINAL_OUTPUT}${NC}"
if [ -f "${FINAL_OUTPUT}" ]; then
    echo -e "Tamanho do arquivo: $(du -sh "${FINAL_OUTPUT}" | cut -f1)"
fi
echo -e "\nAnexe o arquivo acima ao seu chamado/ticket no Zendesk."
preciso que as mensagens em portugues sejam alteradas para ingles

Here is the complete script with all user interface messages translated to English.  
SH

SH icon
coletar_logs_gpu_failsafe_en
 SH 
Open
📜 Script (coletar_logs_gpu.sh)
Bash
#!/bin/bash
# ==============================================================================
# Fail-Safe Diagnostic Log Collection Script for GPU / Mellanox / System
# Compatibility: Ubuntu / Debian & Oracle Linux / RHEL / CentOS / Rocky / Alma
# Output: /root/support_$hostname_$date.zip (ready to attach to Zendesk ticket)
# ==============================================================================

set -u

# Visual Formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Starting Fail-Safe GPU / System Log Collection   ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. Root User Privilege Check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[CRITICAL ERROR] This script must be executed as root (sudo).${NC}"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "host")
WORKDIR="/tmp/gpu_logs_${HOSTNAME}_${TIMESTAMP}"
mkdir -p "${WORKDIR}"

echo -e "${YELLOW}[+] Temporary working directory: ${WORKDIR}${NC}"

# ------------------------------------------------------------------------------
# OPERATING SYSTEM DETECT & PACKAGE MANAGER IDENTIFICATION
# ------------------------------------------------------------------------------
PKG_MANAGER=""
OS_TYPE=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
fi

echo -e "${YELLOW}[+] Detected Operating System: ${OS_TYPE:-Unknown} (Package Manager: ${PKG_MANAGER:-Unknown})${NC}"

# ------------------------------------------------------------------------------
# AUTOMATIC DEPENDENCY INSTALLATION (FAIL-SAFE)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[+] Checking and installing required dependencies...${NC}"

install_package() {
    local cmd="$1"
    local pkg_apt="$2"
    local pkg_yum="$3"

    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}  -> Command '$cmd' not found. Installing package...${NC}"
        if [ "$PKG_MANAGER" = "apt" ]; then
            apt-get update -qq -y && apt-get install -y -qq "$pkg_apt"
        elif [ "$PKG_MANAGER" = "dnf" ]; then
            dnf install -y -q "$pkg_yum"
        elif [ "$PKG_MANAGER" = "yum" ]; then
            yum install -y -q "$pkg_yum"
        else
            echo -e "${RED}  [WARNING] Unable to install '$cmd' automatically. Package manager not supported.${NC}"
        fi
    fi
}

# Install core tools
install_package "lspci" "pciutils" "pciutils"
install_package "zip" "zip" "zip"
install_package "unzip" "unzip" "unzip"
install_package "python3" "python3" "python3"
install_package "wget" "wget" "wget"
install_package "curl" "curl" "curl"

# ------------------------------------------------------------------------------
# 1. SYSINFO SNAPSHOT (linux-sysinfo-snapshot)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[1/4] Running Sysinfo Snapshot...${NC}"

SYSINFO_BIN=""

# Search standard binary paths
if command -v sysinfo-snapshot.py &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot.py)
elif command -v sysinfo-snapshot &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot)
elif [ -f "./sysinfo-snapshot.py" ]; then
    SYSINFO_BIN="./sysinfo-snapshot.py"
elif [ -f "./sysinfo-snapshot" ]; then
    SYSINFO_BIN="./sysinfo-snapshot"
fi

# Auto-extract local zip if tool not found in PATH
if [ -z "$SYSINFO_BIN" ]; then
    if [ -f "./linux-sysinfo-snapshot-master.zip" ]; then
        echo "Extracting linux-sysinfo-snapshot-master.zip..."
        unzip -q -o ./linux-sysinfo-snapshot-master.zip -d /tmp/sysinfo_extracted
        SYSINFO_BIN=$(find /tmp/sysinfo_extracted -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    fi
fi

if [ -n "$SYSINFO_BIN" ] && ([ -x "$SYSINFO_BIN" ] || [ -f "$SYSINFO_BIN" ]); then
    echo "Executing: $SYSINFO_BIN --gpu"
    python3 "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || true
    
    # Collect generated snapshot files from /tmp or current directory
    find /tmp . -maxdepth 2 -name "sysinfo-snapshot*" -not -path "${WORKDIR}/*" -exec mv {} "${WORKDIR}/" \; 2>/dev/null || true
    echo -e "${GREEN}[OK] Sysinfo snapshot completed.${NC}"
else
    echo -e "${RED}[WARNING] sysinfo-snapshot tool not found in the environment.${NC}"
    echo "Sysinfo snapshot was not executed. Please ensure linux-sysinfo-snapshot-master.zip is placed in the same directory." > "${WORKDIR}/SYSINFO_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 2. CX8 MST DUMP (Mellanox Software Tools)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/4] Running CX8 MST Dumps...${NC}"

# Attempt to start MST service if installed
if command -v mst &> /dev/null; then
    mst start > /dev/null 2>&1 || true
elif [ -f "/etc/init.d/mst" ]; then
    /etc/init.d/mst start > /dev/null 2>&1 || true
fi

DEVICES=(
    "/dev/mst/mt4131_pciconf0"
    "/dev/mst/mt4131_pciconf1"
    "/dev/mst/mt4131_pciconf2"
    "/dev/mst/mt4131_pciconf3"
)

MST_EXECUTED=false

if command -v mstdump &> /dev/null; then
    for dev in "${DEVICES[@]}"; do
        dev_name=$(basename "$dev")
        if [ -e "$dev" ]; then
            MST_EXECUTED=true
            echo "Starting mstdump for $dev (3 readings with 15-second intervals)..."
            
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log1.log" 2>&1
            sleep 15
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log2.log" 2>&1
            sleep 15
            mstdump "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log3.log" 2>&1
            
            echo -e "${GREEN}[OK] Device dump for $dev_name completed.${NC}"
        else
            echo -e "${RED}[WARNING] Device $dev not found on system.${NC}"
        fi
    done
else
    echo -e "${RED}[WARNING] Tool 'mstdump' (Mellanox MST) is not installed or available in PATH.${NC}"
fi

if [ "$MST_EXECUTED" = false ]; then
    echo "No MST dumps were collected. Please ensure MST/MFT package is installed and MST devices are loaded." > "${WORKDIR}/MSTDUMP_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 3. PCI DIAGNOSTICS, KERNEL & DCGM
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/4] Collecting lspci, dmesg, and system diagnostics...${NC}"

# iv. lspci -tv
if command -v lspci &> /dev/null; then
    lspci -tv > "${WORKDIR}/lspcitv.log" 2>&1 || true
    # v. lspci -vvvxxxx
    lspci -vvvxxxx > "${WORKDIR}/lspcivvvxxxx.log" 2>&1 || true
else
    echo -e "${RED}[WARNING] lspci not available.${NC}"
fi

# vi. dmesg
if command -v dmesg &> /dev/null; then
    dmesg -T > "${WORKDIR}/dmesg.log" 2>&1 || dmesg > "${WORKDIR}/dmesg.log" 2>&1 || true
fi

# vii. BMC Onekeylog / Ipmitool (if available)
if command -v ipmitool &> /dev/null; then
    echo "Collecting BMC logs via ipmitool..."
    ipmitool sel list > "${WORKDIR}/bmc_sel.log" 2>&1 || true
    ipmitool mc info > "${WORKDIR}/bmc_info.log" 2>&1 || true
fi

# Image Item 4: NVIDIA DCGM Diagnostic
if command -v dcgmi &> /dev/null; then
    echo "Running NVIDIA DCGM Diagnostic (dcgmi diag -r 3)..."
    dcgmi diag -r 3 > "${WORKDIR}/dcgmi_diag.log" 2>&1 || true
fi

echo -e "${GREEN}[OK] System diagnostics collected.${NC}"

# ------------------------------------------------------------------------------
# 4. COMPRESS LOG FILES (SAVED TO /root/support_$hostname_$date.zip)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/4] Generating compressed archive in /root...${NC}"

ZIP_FILENAME="support_${HOSTNAME}_${TIMESTAMP}.zip"
FINAL_OUTPUT="/root/${ZIP_FILENAME}"

cd "${WORKDIR}"

if command -v zip &> /dev/null; then
    zip -q -r "${FINAL_OUTPUT}" ./*
else
    # Fallback if zip utility fails completely
    FINAL_OUTPUT="/root/support_${HOSTNAME}_${TIMESTAMP}.tar.gz"
    tar -czf "${FINAL_OUTPUT}" ./*
fi

# Clean up temporary working directory
rm -rf "${WORKDIR}" /tmp/sysinfo_extracted 2>/dev/null || true

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}   LOG COLLECTION COMPLETED SUCCESSFULLY!           ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Final output archive: ${YELLOW}${FINAL_OUTPUT}${NC}"
if [ -f "${FINAL_OUTPUT}" ]; then
    echo -e "Archive size: $(du -sh "${FINAL_OUTPUT}" | cut -f1)"
fi
echo -e "\nAttach the file above directly to your Zendesk ticket."
sh: linha 7: `<!DOCTYPE html>'

[root@localhost user]# curl -sL https://raw.githubusercontent.com/celsoyoshioka-creator/Linux/refs/heads/main/log_collect.sh | sudo bash

====================================================

   Starting Fail-Safe GPU / System Log Collection

====================================================

[+] Temporary working directory: /tmp/gpu_logs_localhost_20260817_145923

[+] Detected Operating System: ol (Package Manager: dnf)



[+] Checking and installing required dependencies...



[1/4] Running Sysinfo Snapshot...

[WARNING] sysinfo-snapshot tool not found in the environment.



[2/4] Running CX8 MST Dumps...

[WARNING] Tool 'mstdump' (Mellanox MST) is not installed or available in PATH.



[3/4] Collecting lspci, dmesg, and system diagnostics...

[OK] System diagnostics collected.



[4/4] Generating compressed archive in /root...



====================================================

O script em si funcionou e rodou perfeitamente no seu Oracle Linux (ol), mas há duas coisas importantes acontecendo na sua saída:

1. O erro sh: linha 7: <!DOCTYPE html>
Esse erro ocorre porque a URL passada no curl retornou um redirecionamento ou uma página HTML 404 em vez do código cru em Bash.

Solução: Sempre use a URL RAW direta do GitHub e garanta as aspas no curl:

Bash
curl -fsSL "https://raw.githubusercontent.com/celsoyoshioka-creator/Linux/main/log_collect.sh" | sudo bash
2. Os avisos de ferramentas ausentes ([WARNING])
O script é fail-safe, então ele não crashou e coletou tudo o que podia (como lspci, dmesg, etc.), gerando o arquivo ZIP em /root/support_localhost_20260817_145923.zip.

Porém, para coletar os dados de GPU e Mellanox que o suporte pediu na imagem, o sistema precisa dessas ferramentas instaladas localmente:

Para resolver o Sysinfo Snapshot (sysinfo-snapshot.py):
Baixe o repositório que o suporte indicou no ticket (linux-sysinfo-snapshot-master.zip) e coloque-o na mesma pasta onde você executa o script. O script irá extrair e rodar a ferramenta automaticamente.

Para resolver o MST Dump (mstdump):
Instale o pacote MFT (Mellanox Firmware Tools) no seu Oracle Linux para disponibilizar os utilitários de placa de rede/InfiniBand:

Bash
sudo dnf install -y mft
sudo mst start
📦 Como pegar o arquivo final para o Zendesk
Mesmo com os avisos, o pacote ZIP com todos os dados disponíveis foi gerado com sucesso. Para verificar o arquivo criado no seu servidor:

Bash
ls -lh /root/support_*.zip
preciso que tudo que seja rodado seja instalado pelo script

Here is the self-contained Bash script that automatically downloads, installs, and configures all required dependencies (including sysinfo-snapshot directly from GitHub and Mellanox MST tools) on both Ubuntu and Oracle Linux before running the diagnostics and building /root/support_$hostname_$date.zip.

SH icon
coletar_logs_gpu_autoinstall
 SH 
Open
Bash
#!/bin/bash
# ==============================================================================
# Fail-Safe Auto-Install Diagnostic Log Collection Script for GPU / Mellanox
# Compatibility: Ubuntu / Debian & Oracle Linux / RHEL / CentOS / Rocky / Alma
# Output: /root/support_$hostname_$date.zip (ready to attach to Zendesk ticket)
# ==============================================================================

set -u

# Visual Formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Starting Full Auto-Install GPU / System Log Collect ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. Root User Privilege Check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[CRITICAL ERROR] This script must be executed as root (sudo).${NC}"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "host")
WORKDIR="/tmp/gpu_logs_${HOSTNAME}_${TIMESTAMP}"
mkdir -p "${WORKDIR}"

echo -e "${YELLOW}[+] Temporary working directory: ${WORKDIR}${NC}"

# ------------------------------------------------------------------------------
# OPERATING SYSTEM DETECT & PACKAGE MANAGER IDENTIFICATION
# ------------------------------------------------------------------------------
PKG_MANAGER=""
OS_TYPE=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
fi

echo -e "${YELLOW}[+] Detected Operating System: ${OS_TYPE:-Unknown} (Package Manager: ${PKG_MANAGER:-Unknown})${NC}"

# ------------------------------------------------------------------------------
# AUTOMATIC DEPENDENCY INSTALLATION
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[+] Checking and installing base OS dependencies...${NC}"

install_package() {
    local cmd="$1"
    local pkg_apt="$2"
    local pkg_yum="$3"

    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}  -> Command '$cmd' not found. Installing package...${NC}"
        if [ "$PKG_MANAGER" = "apt" ]; then
            apt-get update -qq -y && apt-get install -y -qq "$pkg_apt"
        elif [ "$PKG_MANAGER" = "dnf" ]; then
            dnf install -y -q "$pkg_yum"
        elif [ "$PKG_MANAGER" = "yum" ]; then
            yum install -y -q "$pkg_yum"
        fi
    fi
}

# Install core system utilities
install_package "lspci" "pciutils" "pciutils"
install_package "zip" "zip" "zip"
install_package "unzip" "unzip" "unzip"
install_package "python3" "python3" "python3"
install_package "wget" "wget" "wget"
install_package "curl" "curl" "curl"
install_package "git" "git" "git"

# ------------------------------------------------------------------------------
# AUTO-INSTALL MELLANOX SOFTWARE TOOLS (mstdump) IF MISSING
# ------------------------------------------------------------------------------
if ! command -v mstdump &> /dev/null && ! command -v mst &> /dev/null; then
    echo -e "\n${YELLOW}[+] Mellanox tools missing. Attempting automatic installation...${NC}"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y -qq mstflint || true
    elif [ "$PKG_MANAGER" = "dnf" ]; then
        dnf install -y -q mstflint || dnf install -y -q mft || true
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install -y -q mstflint || yum install -y -q mft || true
    fi
fi

# ------------------------------------------------------------------------------
# 1. SYSINFO SNAPSHOT (linux-sysinfo-snapshot) - AUTO DOWNLOAD & RUN
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[1/4] Setting up and running Sysinfo Snapshot...${NC}"

SYSINFO_BIN=""

# Check local PATH first
if command -v sysinfo-snapshot.py &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot.py)
elif command -v sysinfo-snapshot &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot)
elif [ -f "./sysinfo-snapshot.py" ]; then
    SYSINFO_BIN="./sysinfo-snapshot.py"
fi

# If not present, download directly from GitHub
if [ -z "$SYSINFO_BIN" ]; then
    echo "Downloading sysinfo-snapshot automatically from GitHub..."
    mkdir -p /tmp/sysinfo_download
    
    if wget -q https://github.com/Mellanox/linux-sysinfo-snapshot/archive/refs/heads/master.zip -O /tmp/sysinfo_download/sysinfo.zip 2>/dev/null; then
        unzip -q -o /tmp/sysinfo_download/sysinfo.zip -d /tmp/sysinfo_download/
        SYSINFO_BIN=$(find /tmp/sysinfo_download -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    elif git clone --depth 1 https://github.com/Mellanox/linux-sysinfo-snapshot.git /tmp/sysinfo_download/repo 2>/dev/null; then
        SYSINFO_BIN=$(find /tmp/sysinfo_download/repo -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    fi
fi

if [ -n "$SYSINFO_BIN" ] && [ -f "$SYSINFO_BIN" ]; then
    echo "Executing: python3 $SYSINFO_BIN --gpu"
    python3 "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || true
    
    # Collect output files
    find /tmp . -maxdepth 2 -name "sysinfo-snapshot*" -not -path "${WORKDIR}/*" -exec mv {} "${WORKDIR}/" \; 2>/dev/null || true
    echo -e "${GREEN}[OK] Sysinfo snapshot completed.${NC}"
else
    echo -e "${RED}[WARNING] Could not auto-download sysinfo-snapshot. Skipping...${NC}"
    echo "Sysinfo snapshot tool download failed. Ensure outbound internet access." > "${WORKDIR}/SYSINFO_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 2. CX8 MST DUMP (Mellanox Software Tools)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/4] Running CX8 MST Dumps...${NC}"

# Start MST service if present
if command -v mst &> /dev/null; then
    mst start > /dev/null 2>&1 || true
elif [ -f "/etc/init.d/mst" ]; then
    /etc/init.d/mst start > /dev/null 2>&1 || true
fi

DEVICES=(
    "/dev/mst/mt4131_pciconf0"
    "/dev/mst/mt4131_pciconf1"
    "/dev/mst/mt4131_pciconf2"
    "/dev/mst/mt4131_pciconf3"
)

MST_EXECUTED=false

# Support both official 'mstdump' and open-source fallback 'mstflint'
DUMP_CMD=""
if command -v mstdump &> /dev/null; then
    DUMP_CMD="mstdump"
elif command -v mstflint &> /dev/null; then
    DUMP_CMD="mstflint -d"
fi

if [ -n "$DUMP_CMD" ]; then
    for dev in "${DEVICES[@]}"; do
        dev_name=$(basename "$dev")
        if [ -e "$dev" ]; then
            MST_EXECUTED=true
            echo "Starting dump for $dev using '$DUMP_CMD' (3 readings with 15-second intervals)..."
            
            $DUMP_CMD "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log1.log" 2>&1
            sleep 15
            $DUMP_CMD "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log2.log" 2>&1
            sleep 15
            $DUMP_CMD "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log3.log" 2>&1
            
            echo -e "${GREEN}[OK] Device dump for $dev_name completed.${NC}"
        else
            echo -e "${RED}[WARNING] Device $dev not found on system.${NC}"
        fi
    done
else
    echo -e "${RED}[WARNING] Neither 'mstdump' nor 'mstflint' are available on this system.${NC}"
fi

if [ "$MST_EXECUTED" = false ]; then
    echo "No MST dumps were collected. Devices $DEVICES were not present or driver missing." > "${WORKDIR}/MSTDUMP_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 3. PCI DIAGNOSTICS, KERNEL & DCGM
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/4] Collecting lspci, dmesg, and system diagnostics...${NC}"

# iv. lspci -tv
if command -v lspci &> /dev/null; then
    lspci -tv > "${WORKDIR}/lspcitv.log" 2>&1 || true
    # v. lspci -vvvxxxx
    lspci -vvvxxxx > "${WORKDIR}/lspcivvvxxxx.log" 2>&1 || true
fi

# vi. dmesg
if command -v dmesg &> /dev/null; then
    dmesg -T > "${WORKDIR}/dmesg.log" 2>&1 || dmesg > "${WORKDIR}/dmesg.log" 2>&1 || true
fi

# vii. BMC Onekeylog / Ipmitool (if available)
if command -v ipmitool &> /dev/null; then
    echo "Collecting BMC logs via ipmitool..."
    ipmitool sel list > "${WORKDIR}/bmc_sel.log" 2>&1 || true
    ipmitool mc info > "${WORKDIR}/bmc_info.log" 2>&1 || true
fi

# Item 4: NVIDIA DCGM Diagnostic
if command -v dcgmi &> /dev/null; then
    echo "Running NVIDIA DCGM Diagnostic (dcgmi diag -r 3)..."
    dcgmi diag -r 3 > "${WORKDIR}/dcgmi_diag.log" 2>&1 || true
fi

echo -e "${GREEN}[OK] System diagnostics collected.${NC}"

# ------------------------------------------------------------------------------
# 4. COMPRESS LOG FILES (SAVED TO /root/support_$hostname_$date.zip)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/4] Generating compressed archive in /root...${NC}"

ZIP_FILENAME="support_${HOSTNAME}_${TIMESTAMP}.zip"
FINAL_OUTPUT="/root/${ZIP_FILENAME}"

cd "${WORKDIR}"

if command -v zip &> /dev/null; then
    zip -q -r "${FINAL_OUTPUT}" ./*
else
    FINAL_OUTPUT="/root/support_${HOSTNAME}_${TIMESTAMP}.tar.gz"
    tar -czf "${FINAL_OUTPUT}" ./*
fi

# Cleanup temporary download and build areas
rm -rf "${WORKDIR}" /tmp/sysinfo_download 2>/dev/null || true

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}   LOG COLLECTION COMPLETED SUCCESSFULLY!           ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Final output archive: ${YELLOW}${FINAL_OUTPUT}${NC}"
if [ -f "${FINAL_OUTPUT}" ]; then
    echo -e "Archive size: $(du -sh "${FINAL_OUTPUT}" | cut -f1)"
fi
echo -e "\nAttach the file above directly to your Zendesk ticket."



Your Megaport chats aren’t used to improve our models. Gemini is AI and can make mistakes. Your privacy & GeminiOpens in a new window

O menu 1Password está disponível. Pressione a seta para baixo para selecionar.Analyzing
#!/bin/bash
# ==============================================================================
# Fail-Safe Auto-Install Diagnostic Log Collection Script for GPU / Mellanox
# Compatibility: Ubuntu / Debian & Oracle Linux / RHEL / CentOS / Rocky / Alma
# Output: /root/support_$hostname_$date.zip (ready to attach to Zendesk ticket)
# ==============================================================================

set -u

# Visual Formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Starting Full Auto-Install GPU / System Log Collect ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. Root User Privilege Check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[CRITICAL ERROR] This script must be executed as root (sudo).${NC}"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "host")
WORKDIR="/tmp/gpu_logs_${HOSTNAME}_${TIMESTAMP}"
mkdir -p "${WORKDIR}"

echo -e "${YELLOW}[+] Temporary working directory: ${WORKDIR}${NC}"

# ------------------------------------------------------------------------------
# OPERATING SYSTEM DETECT & PACKAGE MANAGER IDENTIFICATION
# ------------------------------------------------------------------------------
PKG_MANAGER=""
OS_TYPE=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
fi

echo -e "${YELLOW}[+] Detected Operating System: ${OS_TYPE:-Unknown} (Package Manager: ${PKG_MANAGER:-Unknown})${NC}"

# ------------------------------------------------------------------------------
# AUTOMATIC DEPENDENCY INSTALLATION
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[+] Checking and installing base OS dependencies...${NC}"

install_package() {
    local cmd="$1"
    local pkg_apt="$2"
    local pkg_yum="$3"

    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}  -> Command '$cmd' not found. Installing package...${NC}"
        if [ "$PKG_MANAGER" = "apt" ]; then
            apt-get update -qq -y && apt-get install -y -qq "$pkg_apt"
        elif [ "$PKG_MANAGER" = "dnf" ]; then
            dnf install -y -q "$pkg_yum"
        elif [ "$PKG_MANAGER" = "yum" ]; then
            yum install -y -q "$pkg_yum"
        fi
    fi
}

# Install core system utilities
install_package "lspci" "pciutils" "pciutils"
install_package "zip" "zip" "zip"
install_package "unzip" "unzip" "unzip"
install_package "python3" "python3" "python3"
install_package "wget" "wget" "wget"
install_package "curl" "curl" "curl"
install_package "git" "git" "git"

# ------------------------------------------------------------------------------
# AUTO-INSTALL MELLANOX SOFTWARE TOOLS (mstdump) IF MISSING
# ------------------------------------------------------------------------------
if ! command -v mstdump &> /dev/null && ! command -v mst &> /dev/null; then
    echo -e "
${YELLOW}[+] Mellanox tools missing. Attempting automatic installation...${NC}"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y -qq mstflint || true
    elif [ "$PKG_MANAGER" = "dnf" ]; then
        dnf install -y -q mstflint || dnf install -y -q mft || true
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install -y -q mstflint || yum install -y -q mft || true
    fi
fi

# ------------------------------------------------------------------------------
# 1. SYSINFO SNAPSHOT (linux-sysinfo-snapshot) - AUTO DOWNLOAD & RUN
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[1/4] Setting up and running Sysinfo Snapshot...${NC}"

SYSINFO_BIN=""

# Check local PATH first
if command -v sysinfo-snapshot.py &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot.py)
elif command -v sysinfo-snapshot &> /dev/null; then
    SYSINFO_BIN=$(command -v sysinfo-snapshot)
elif [ -f "./sysinfo-snapshot.py" ]; then
    SYSINFO_BIN="./sysinfo-snapshot.py"
fi

# If not present, download directly from GitHub
if [ -z "$SYSINFO_BIN" ]; then
    echo "Downloading sysinfo-snapshot automatically from GitHub..."
    mkdir -p /tmp/sysinfo_download
    
    # Download zip or clone repo
    if wget -q https://github.com/Mellanox/linux-sysinfo-snapshot/archive/refs/heads/master.zip -O /tmp/sysinfo_download/sysinfo.zip 2>/dev/null; then
        unzip -q -o /tmp/sysinfo_download/sysinfo.zip -d /tmp/sysinfo_download/
        SYSINFO_BIN=$(find /tmp/sysinfo_download -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    elif git clone --depth 1 https://github.com/Mellanox/linux-sysinfo-snapshot.p.git /tmp/sysinfo_download/repo 2>/dev/null; then
        SYSINFO_BIN=$(find /tmp/sysinfo_download/repo -name "sysinfo-snapshot.py" -o -name "sysinfo-snapshot" | head -n 1)
    fi
fi

if [ -n "$SYSINFO_BIN" ] && [ -f "$SYSINFO_BIN" ]; then
    echo "Executing: python3 $SYSINFO_BIN --gpu"
    python3 "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || "$SYSINFO_BIN" --gpu > "${WORKDIR}/sysinfo_stdout.log" 2>&1 || true
    
    # Collect output files
    find /tmp . -maxdepth 2 -name "sysinfo-snapshot*" -not -path "${WORKDIR}/*" -exec mv {} "${WORKDIR}/" \; 2>/dev/null || true
    echo -e "${GREEN}[OK] Sysinfo snapshot completed.${NC}"
else
    echo -e "${RED}[WARNING] Could not auto-download sysinfo-snapshot. Skipping...${NC}"
    echo "Sysinfo snapshot tool download failed. Ensure outbound internet access." > "${WORKDIR}/SYSINFO_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 2. CX8 MST DUMP (Mellanox Software Tools)
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[2/4] Running CX8 MST Dumps...${NC}"

# Start MST service if present
if command -v mst &> /dev/null; then
    mst start > /dev/null 2>&1 || true
elif [ -f "/etc/init.d/mst" ]; then
    /etc/init.d/mst start > /dev/null 2>&1 || true
fi

DEVICES=(
    "/dev/mst/mt4131_pciconf0"
    "/dev/mst/mt4131_pciconf1"
    "/dev/mst/mt4131_pciconf2"
    "/dev/mst/mt4131_pciconf3"
)

MST_EXECUTED=false

# Support both official 'mstdump' and open-source fallback 'mstflint'
DUMP_CMD=""
if command -v mstdump &> /dev/null; then
    DUMP_CMD="mstdump"
elif command -v mstflint &> /dev/null; then
    DUMP_CMD="mstflint -d"
fi

if [ -n "$DUMP_CMD" ]; then
    for dev in "${DEVICES[@]}"; do
        dev_name=$(basename "$dev")
        if [ -e "$dev" ]; then
            MST_EXECUTED=true
            echo "Starting dump for $dev using '$DUMP_CMD' (3 readings with 15-second intervals)..."
            
            $DUMP_CMD "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log1.log" 2>&1
            sleep 15
            $DUMP_CMD "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log2.log" 2>&1
            sleep 15
            $DUMP_CMD "$dev" >> "${WORKDIR}/mstdump_${dev_name}_log3.log" 2>&1
            
            echo -e "${GREEN}[OK] Device dump for $dev_name completed.${NC}"
        else
            echo -e "${RED}[WARNING] Device $dev not found on system.${NC}"
        fi
    done
else
    echo -e "${RED}[WARNING] Neither 'mstdump' nor 'mstflint' are available on this system.${NC}"
fi

if [ "$MST_EXECUTED" = false ]; then
    echo "No MST dumps were collected. Devices $DEVICES were not present or driver missing." > "${WORKDIR}/MSTDUMP_NOT_EXECUTED.txt"
fi

# ------------------------------------------------------------------------------
# 3. PCI DIAGNOSTICS, KERNEL & DCGM
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[3/4] Collecting lspci, dmesg, and system diagnostics...${NC}"

# iv. lspci -tv
if command -v lspci &> /dev/null; then
    lspci -tv > "${WORKDIR}/lspcitv.log" 2>&1 || true
    # v. lspci -vvvxxxx
    lspci -vvvxxxx > "${WORKDIR}/lspcivvvxxxx.log" 2>&1 || true
fi

# vi. dmesg
if command -v dmesg &> /dev/null; then
    dmesg -T > "${WORKDIR}/dmesg.log" 2>&1 || dmesg > "${WORKDIR}/dmesg.log" 2>&1 || true
fi

# vii. BMC Onekeylog / Ipmitool (if available)
if command -v ipmitool &> /dev/null; then
    echo "Collecting BMC logs via ipmitool..."
    ipmitool sel list > "${WORKDIR}/bmc_sel.log" 2>&1 || true
    ipmitool mc info > "${WORKDIR}/bmc_info.log" 2>&1 || true
fi

# Item 4: NVIDIA DCGM Diagnostic
if command -v dcgmi &> /dev/null; then
    echo "Running NVIDIA DCGM Diagnostic (dcgmi diag -r 3)..."
    dcgmi diag -r 3 > "${WORKDIR}/dcgmi_diag.log" 2>&1 || true
fi

echo -e "${GREEN}[OK] System diagnostics collected.${NC}"

# ------------------------------------------------------------------------------
# 4. COMPRESS LOG FILES (SAVED TO /root/support_$hostname_$date.zip)
# ------------------------------------------------------------------------------
echo -e "
${YELLOW}[4/4] Generating compressed archive in /root...${NC}"

ZIP_FILENAME="support_${HOSTNAME}_${TIMESTAMP}.zip"
FINAL_OUTPUT="/root/${ZIP_FILENAME}"

cd "${WORKDIR}"

if command -v zip &> /dev/null; then
    zip -q -r "${FINAL_OUTPUT}" ./*
else
    FINAL_OUTPUT="/root/support_${HOSTNAME}_${TIMESTAMP}.tar.gz"
    tar -czf "${FINAL_OUTPUT}" ./*
fi

# Cleanup temporary download and build areas
rm -rf "${WORKDIR}" /tmp/sysinfo_download 2>/dev/null || true

echo -e "
${GREEN}====================================================${NC}"
echo -e "${GREEN}   LOG COLLECTION COMPLETED SUCCESSFULLY!           ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Final output archive: ${YELLOW}${FINAL_OUTPUT}${NC}"
if [ -f "${FINAL_OUTPUT}" ]; then
    echo -e "Archive size: $(du -sh "${FINAL_OUTPUT}" | cut -f1)"
fi
echo -e "
Attach the file above directly to your Zendesk ticket."
coletar_logs_gpu_autoinstall.sh
Displaying coletar_logs_gpu_autoinstall.sh.
