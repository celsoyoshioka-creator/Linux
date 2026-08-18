#!/bin/bash

# Aborta o script em erros não tratados
set -euo pipefail

# Captura de erros e saída limpa
trap 'echo -e "\n❌ [ERRO] Ocorreu uma falha no script (linha $LINENO). Processo interrompido de forma segura."; exit 1' ERR

# ------------------------------------------------------------------------------
# 1. PREPARAÇÃO DO AMBIENTE (BASH, DEPENDÊNCIAS E PACOTE PRÉ-COMPILADO)
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 1. Preparando Ambiente e Instalando Dependências"
echo "============================================================"

# Atualiza repositórios do Alpine
cat > /etc/apk/repositories << 'EOF'
http://dl-cdn.alpinelinux.org/alpine/v3.20/main
http://dl-cdn.alpinelinux.org/alpine/v3.20/community
EOF

echo "Garantindo instalação do Bash e bibliotecas básicas..."
apk update >/dev/null
apk add --no-cache bash wget tar gzip ipmitool gcompat zlib openssl libpciaccess pciutils rdma-core ca-certificates >/dev/null
update-ca-certificates >/dev/null

# Detecta o IP do Host
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || true)
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -i 2>/dev/null | awk '{print $1}' || echo "IP_HOST")
fi

echo "✅ Ambiente pronto. IP do servidor: ${HOST_IP}"

echo "============================================================"
echo " 2. Baixando e Instalando o MSTFLINT Pré-Compilado"
echo "============================================================"

URL_PACOTE="https://github.com/celsoyoshioka-creator/Linux/raw/refs/heads/main/mstflint-alpine-x86_64.tar.gz"

echo "Baixando pacote do GitHub..."
wget -qO /tmp/mstflint-package.tar.gz "$URL_PACOTE"

echo "Extraindo binários para /usr/local/bin..."
mkdir -p /tmp/mstflint-extract
tar -xzf /tmp/mstflint-package.tar.gz -C /tmp/mstflint-extract

cp /tmp/mstflint-extract/mstflint-alpine-build/mstflint /usr/local/bin/ 2>/dev/null || true
cp /tmp/mstflint-extract/mstflint-alpine-build/mstconfig /usr/local/bin/ 2>/dev/null || true

if [ -d "/tmp/mstflint-extract/mstflint-alpine-build/lib" ]; then
    mkdir -p /usr/local/lib/
    cp -r /tmp/mstflint-extract/mstflint-alpine-build/lib/* /usr/local/lib/ 2>/dev/null || true
fi

rm -rf /tmp/mstflint-package.tar.gz /tmp/mstflint-extract

if ! command -v mstflint &>/dev/null; then
    echo "❌ Erro ao validar o binário mstflint instalado!"
    exit 1
fi

echo "✅ mstflint configurado com sucesso! Versão: $(mstflint -v | head -n 1)"

# ------------------------------------------------------------------------------
# 2. BUSCA AUTOMÁTICA DE FIRMWARE EM /ROOT
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 3. Procurando Arquivos de Firmware (.bin) em /root"
echo "============================================================"

# Busca arquivos .bin válidos em /root
mapfile -t FW_FILES < <(find /root -maxdepth 1 -type f -name "*.bin" 2>/dev/null)

if [ "${#FW_FILES[@]}" -eq 0 ]; then
    echo ""
    echo "❌ Nenhum arquivo de firmware (.bin) foi encontrado na pasta /root!"
    echo ""
    echo "============================================================"
    echo " 📌 [AÇÃO REQUERIDA NO WINDOWS]"
    echo " Execute o comando abaixo no PowerShell / CMD para transferir o arquivo:"
    echo "============================================================"
    echo ""
    echo " scp \"C:\\caminho\\seu_firmware.bin\" root@${HOST_IP}:/root/"
    echo ""
    echo "============================================================"
    echo "Após enviar o arquivo, execute o script novamente!"
    exit 0
fi

# Caso encontre 1 ou mais arquivos .bin em /root
SELECTED_FW=""
if [ "${#FW_FILES[@]}" -eq 1 ]; then
    SELECTED_FW="${FW_FILES[0]}"
    echo "✅ Firmware encontrado: ${SELECTED_FW}"
else
    echo "Mais de um arquivo .bin foi encontrado em /root. Selecione o desejado:"
    for i in "${!FW_FILES[@]}"; do
        echo "  $((i+1))) ${FW_FILES[$i]}"
    done
    echo ""
    read -rp "Opção (1-${#FW_FILES[@]}): " FW_OPT
    INDEX=$((FW_OPT-1))
    
    if [[ "$INDEX" -ge 0 && "$INDEX" -lt "${#FW_FILES[@]}" ]]; then
        SELECTED_FW="${FW_FILES[$INDEX]}"
    else
        echo "❌ Opção inválida!"
        exit 1
    fi
fi

# Lendo Metadados do Arquivo .bin
FILE_QUERY=$(mstflint -i "$SELECTED_FW" q 2>/dev/null || true)
if [ -z "$FILE_QUERY" ]; then
    echo "❌ O arquivo ${SELECTED_FW} é inválido ou está corrompido!"
    exit 1
fi

FILE_PSID=$(echo "$FILE_QUERY" | grep -i "PSID:" | awk '{print $2}')
FILE_FW_VER=$(echo "$FILE_QUERY" | grep -i "FW Version:" | awk '{print $3}')

echo "   • PSID do Firmware: ${FILE_PSID}"
echo "   • Versão no Arquivo: ${FILE_FW_VER}"

# ------------------------------------------------------------------------------
# 3. Mapeamento e Validação das Placas PCI
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 4. Inventário e Compatibilidade de Placas Mellanox"
echo "============================================================"

PCI_DEVS=$(lspci -d 15b3: | awk '{print $1}')

if [ -z "$PCI_DEVS" ]; then
    echo "❌ Nenhuma placa Mellanox (PCI Vendor ID 15b3) encontrada no sistema!"
    exit 1
fi

ELIGIBLE_DEVS=()
ELIGIBLE_FWS=()

for DEV in $PCI_DEVS; do
    CARD_QUERY=$(mstflint -d "$DEV" q 2>/dev/null || true)
    CARD_PSID=$(echo "$CARD_QUERY" | grep -i "PSID:" | awk '{print $2}' || echo "DESCONHECIDO")
    CARD_FW_VER=$(echo "$CARD_QUERY" | grep -i "FW Version:" | awk '{print $3}' || echo "DESCONHECIDO")

    if [ "$CARD_PSID" = "$FILE_PSID" ] && [ "$CARD_FW_VER" != "$FILE_FW_VER" ]; then
        ELIGIBLE_DEVS+=("$DEV")
        ELIGIBLE_FWS+=("$CARD_FW_VER")
        echo "  [ELEGÍVEL] Placa $DEV | PSID: $CARD_PSID | FW Atual: $CARD_FW_VER ➔ Novo: $FILE_FW_VER"
    else
        echo "  [IGNORADA] Placa $DEV | PSID: $CARD_PSID | FW Atual: $CARD_FW_VER (Já atualizada ou PSID incompatível)"
    fi
done

if [ "${#ELIGIBLE_DEVS[@]}" -eq 0 ]; then
    echo ""
    echo "✅ Todas as placas compatíveis com o PSID $FILE_PSID já estão atualizadas para a versão $FILE_FW_VER."
    exit 0
fi

# ------------------------------------------------------------------------------
# 4. MENU DE SELEÇÃO DA PLACA E CONFIRMAÇÃO
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 5. Seleção para Atualização Individual"
echo "============================================================"
echo "Selecione UMA placa para atualizar:"
echo ""

for i in "${!ELIGIBLE_DEVS[@]}"; do
    echo "  $((i+1))) Endereço PCI: ${ELIGIBLE_DEVS[$i]} (FW Atual: ${ELIGIBLE_FWS[$i]} ➔ Novo FW: ${FILE_FW_VER})"
done
echo "  0) Cancelar e Sair"
echo ""

read -rp "Selecione a opção (1-${#ELIGIBLE_DEVS[@]}): " CARD_CHOICE

if [ "$CARD_CHOICE" -eq 0 ] 2>/dev/null; then
    echo "Operação cancelada pelo usuário."
    exit 0
fi

INDEX=$((CARD_CHOICE-1))

if [[ "$INDEX" -lt 0 || "$INDEX" -ge "${#ELIGIBLE_DEVS[@]}" ]]; then
    echo "❌ Opção inválida!"
    exit 1
fi

TARGET_DEV="${ELIGIBLE_DEVS[$INDEX]}"
TARGET_CURRENT_FW="${ELIGIBLE_FWS[$INDEX]}"

echo ""
echo "============================================================"
echo " ⚠️ CONFIRMAÇÃO DE GRAVAÇÃO"
echo "============================================================"
echo " Placa Alvo:      $TARGET_DEV"
echo " PSID:            $FILE_PSID"
echo " Firmware Atual:  $TARGET_CURRENT_FW"
echo " Novo Firmware:   $FILE_FW_VER"
echo " Arquivo Origem:  $SELECTED_FW"
echo "============================================================"
read -rp "Confirma a gravação do firmware nesta placa agora? (s/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo "Operação abortada pelo usuário."
    exit 0
fi

# ------------------------------------------------------------------------------
# 5. EXECUÇÃO DO BURN E OPTION ROM
# ------------------------------------------------------------------------------
echo ""
echo "Gravando firmware na placa $TARGET_DEV..."
mstflint -d "$TARGET_DEV" -i "$SELECTED_FW" -y burn

echo "Habilitando Option ROM (PXE/UEFI) na BIOS..."
mstconfig -d "$TARGET_DEV" set EXP_ROM_PXE_ENABLE=1 EXP_ROM_UEFI_x86_ENABLE=1 -y

mstconfig -d "$TARGET_DEV" set LINK_TYPE_P1=2 LINK_TYPE_P2=2 -y 2>/dev/null || \
    echo "Info: Placa é variante Ethernet fixa (EN). Parâmetro LINK_TYPE ignorado."

echo "✅ Gravação concluída com sucesso na placa $TARGET_DEV!"

# ------------------------------------------------------------------------------
# 6. IPMI POWER CYCLE OU REBOOT
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " 6. Reinicialização / Power Cycle (Obrigatório pós-burn)"
echo "============================================================"
read -rp "Deseja efetuar o Power Cycle via IPMI agora? (s/N): " IPMI_ANS

if [[ "$IPMI_ANS" =~ ^[Ss]$ ]]; then
    read -rp "IP da BMC/IPMI: " BMC_IP
    read -rp "Usuário IPMI: " BMC_USER
    read -rs -p "Senha IPMI: " BMC_PASS
    echo ""
    echo "Enviando comando Chassis Power Cycle via IPMI..."
    ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" chassis power cycle
else
    echo "Lembre-se de dar um 'reboot' ou aplicar o Power Cycle via IPMI para efetivar a nova versão na BIOS."
fi

echo "✅ Processo finalizado!"
