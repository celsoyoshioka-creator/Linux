#!/bin/bash

# ==============================================================================
# SCRIPT DE INSTALAÇÃO E ATUALIZAÇÃO FAIL-SAFE COM PAUSAS INTERATIVAS
# ==============================================================================

# Aborta o script em erros não tratados, variáveis não declaradas e falhas em pipes
set -euo pipefail

# Captura erros e exibe informações de depuração
trap 'echo -e "\n❌ [ERRO] Ocorreu uma falha na linha $LINENO. Processo interrompido de forma segura."; exit 1' ERR

# Função auxiliar para criar pausas claras
pausar_para_usuario() {
    echo ""
    echo "============================================================"
    echo -e "⏸️  [PAUSA - AÇÃO MANUAL NECESSÁRIA]"
    echo -e "   $1"
    echo "============================================================"
    read -p "Pressione [ENTER] assim que concluir para continuar o script..."
    echo ""
}

# ------------------------------------------------------------------------------
# 0. CHECAGENS PRÉVIAS DE AMBIENTE E PRIVILÉGIOS
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Este script DEVE ser executado como root."
    exit 1
fi

echo "============================================================"
echo " 1. Verificando Conectividade e IP do Host"
echo "============================================================"

HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || true)
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -i 2>/dev/null | awk '{print $1}' || echo "IP_NAO_ENCONTRADO")
fi
echo "IP detectado do host: ${HOST_IP}"

# ------------------------------------------------------------------------------
# 1. CONFIGURAÇÃO DE REPOSITÓRIOS E INSTALAÇÃO COMPLETA DE DEPENDÊNCIAS
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 2. Configurando Repositórios e Instalando Dependências"
echo "============================================================"

cat > /etc/apk/repositories << 'EOF'
http://dl-cdn.alpinelinux.org/alpine/v3.20/main
http://dl-cdn.alpinelinux.org/alpine/v3.20/community
EOF

echo "Atualizando o sistema e instalando dependências do Alpine..."
apk update && apk upgrade

apk add --no-cache \
    ca-certificates bash curl wget tar gzip ipmitool \
    alpine-sdk autoconf automake libtool bison flex pkgconfig \
    linux-headers musl-dev gcompat \
    zlib zlib-dev openssl openssl-dev \
    pciutils pciutils-dev libpciaccess libpciaccess-dev \
    rdma-core rdma-core-dev \
    ccache git

update-ca-certificates

# ------------------------------------------------------------------------------
# 2. DOWNLOAD, COMPILAÇÃO E CORREÇÃO (PATCH) DO MSTFLINT
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 3. Compilando o MSTFLINT com Patches para Musl libc"
echo "============================================================"
cd /root
rm -rf mstflint

git clone --depth 1 https://github.com/Mellanox/mstflint.git
cd mstflint

echo "Aplicando patches de compatibilidade no código fonte..."
find . -type f \( -name '*.c' -o -name '*.h' -o -name '*.cpp' -o -name '*.hpp' \) -exec sed -i \
    -e 's/u_int8_t/uint8_t/g' \
    -e 's/u_int16_t/uint16_t/g' \
    -e 's/u_int32_t/uint32_t/g' \
    -e 's/u_int64_t/uint64_t/g' {} +

sed -i '/#include <sys\/types.h>/a #include <stdint.h>' include/mtcr_ul/mtcr_com_defs.h

./autogen.sh
mkdir build && cd build
../configure --enable-openssl

# Ajuste Fail-Safe para o link simbólico do zlib
if ! ls /usr/lib/libz.so >/dev/null 2>&1; then
    ZLIB_LIB=$(find /usr/lib /lib -name "libz.so*" 2>/dev/null | head -n 1 || true)
    if [ -n "$ZLIB_LIB" ]; then
        echo "Ajustando link simbólico da libz: $ZLIB_LIB"
        ln -sf "$ZLIB_LIB" /usr/lib/libz.so
    fi
fi

make -j"$(nproc)"
make install

if ! command -v mstflint &> /dev/null; then
    echo "❌ Erro grave: A compilação do mstflint falhou!"
    exit 1
fi
echo "✅ mstflint compilado com sucesso! Versão: $(mstflint -v)"

# ------------------------------------------------------------------------------
# 3. CRIAÇÃO DO PACOTE PORTÁTIL DE BACKUP
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 4. Gerando Pacote de Backup para Instalação Rápida"
echo "============================================================"
mkdir -p /root/mstflint-alpine-build
cp /usr/local/bin/mstflint /usr/local/bin/mstconfig /root/mstflint-alpine-build/ 2>/dev/null || true
cp -r /usr/local/lib/mstflint /root/mstflint-alpine-build/lib 2>/dev/null || true
tar -czf /root/mstflint-alpine-x86_64.tar.gz -C /root mstflint-alpine-build

# PAUSA 1: Ação Manual no Windows (Cópia de Backup via SCP)
MSG_PAUSA_1="Execute o comando abaixo no Prompt/PowerShell do Windows para baixar o backup:\n\n"
MSG_PAUSA_1+="   scp root@${HOST_IP}:/root/mstflint-alpine-x86_64.tar.gz %USERPROFILE%\\Downloads\\"
pausar_para_usuario "$MSG_PAUSA_1"

# ------------------------------------------------------------------------------
# 4. DETECÇÃO DA PLACA MELLANOX
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 5. Identificando Placa Mellanox / NVIDIA"
echo "============================================================"
PCI_DEV=$(lspci -d 15b3: | head -n 1 | awk '{print $1}' || true)

if [ -z "$PCI_DEV" ]; then
    echo "❌ Nenhuma placa Mellanox (ID PCI 15b3) foi encontrada no barramento!"
    exit 1
fi

echo "Placa encontrada no endereço PCI: $PCI_DEV"
CARD_QUERY=$(mstflint -d "$PCI_DEV" q)
echo "$CARD_QUERY"

CARD_PSID=$(echo "$CARD_QUERY" | grep -i "PSID:" | awk '{print $2}' || true)

if [ -z "$CARD_PSID" ]; then
    echo "❌ Não foi possível ler o PSID da placa no endereço $PCI_DEV."
    exit 1
fi

echo "✅ PSID da placa física: $CARD_PSID"

# ------------------------------------------------------------------------------
# 5. OBTENÇÃO E VALIDAÇÃO DO FIRMWARE
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 6. Obtenção do Arquivo de Firmware (.bin)"
echo "============================================================"

if [ ! -f /root/cx5fw.bin ]; then
    echo "O arquivo /root/cx5fw.bin não existe no servidor Alpine."
    echo ""
    echo "Como deseja obter o arquivo .bin?"
    echo "1) Baixar informando uma URL direta"
    echo "2) Enviar via SCP do Windows em outro terminal"
    echo ""
    read -p "Digite a URL (ou pressione [ENTER] para optar pelo SCP via Windows): " FW_URL

    if [ -n "$FW_URL" ]; then
        echo "Baixando arquivo da URL..."
        curl -L -s -o /root/cx5fw.bin "$FW_URL"
    else
        # PAUSA 2: Ação Manual no Windows (Envio do Firmware via SCP)
        MSG_PAUSA_2="No Windows, envie o arquivo de firmware (.bin) executando:\n\n"
        MSG_PAUSA_2+="   scp \"C:\\caminho\\seu_arquivo.bin\" root@${HOST_IP}:/root/cx5fw.bin"
        pausar_para_usuario "$MSG_PAUSA_2"
    fi
fi

# Validação do arquivo
if [ ! -s /root/cx5fw.bin ]; then
    echo "❌ O arquivo /root/cx5fw.bin não existe ou tem tamanho 0 bytes!"
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. CHECAGEM FAIL-SAFE DE COMPATIBILIDADE (VALIDAÇÃO DE PSID)
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 7. Validação de Integridade e Compatibilidade de Firmware"
echo "============================================================"

FILE_QUERY=$(mstflint -i /root/cx5fw.bin q 2>/dev/null || true)

if [ -z "$FILE_QUERY" ]; then
    echo "❌ O arquivo /root/cx5fw.bin é inválido ou está corrompido!"
    exit 1
fi

FILE_PSID=$(echo "$FILE_QUERY" | grep -i "PSID:" | awk '{print $2}' || true)

echo "Comparativo de Segurança:"
echo "  - PSID Placa Física: $CARD_PSID"
echo "  - PSID Arquivo .bin: $FILE_PSID"

if [ "$CARD_PSID" != "$FILE_PSID" ]; then
    echo "❌ [BLOQUEIO DE SEGURANÇA] PSIDs incompatíveis!"
    echo "O firmware fornecido é para outro modelo. Operação abortada para evitar danos."
    exit 1
fi

echo "✅ Validação bem-sucedida! PSIDs correspondentes."

# PAUSA 3: Confirmação Antes da Gravação Física (Burn)
MSG_PAUSA_3="Tudo pronto para gravar o firmware na placa $PCI_DEV.\n"
MSG_PAUSA_3+="   Esta operação é irreversível durante a gravação."
pausar_para_usuario "$MSG_PAUSA_3"

# ------------------------------------------------------------------------------
# 7. GRAVAÇÃO DO FIRMWARE E HABILITAÇÃO NA BIOS
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 8. Gravando Firmware (Burn) e Habilitando Option ROM"
echo "============================================================"

echo "Executando burn do firmware..."
mstflint -d "$PCI_DEV" -i /root/cx5fw.bin burn

echo "Habilitando suporte a boot na BIOS (Option ROM PXE/UEFI)..."
mstconfig -d "$PCI_DEV" set EXP_ROM_PXE_ENABLE=1 EXP_ROM_UEFI_x86_ENABLE=1 -y

mstconfig -d "$PCI_DEV" set LINK_TYPE_P1=2 LINK_TYPE_P2=2 -y 2>/dev/null || echo "Info: Placa é Ethernet fixa (EN). Parâmetros LINK_TYPE ignorados."

# ------------------------------------------------------------------------------
# 8. FINALIZAÇÃO E POWER CYCLE VIA IPMI (OPCIONAL)
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 9. Operação Concluída - Power Cycle / Reinicialização"
echo "============================================================"

read -p "Deseja realizar o Power Cycle (desligamento frio) via IPMI agora? (s/N): " RESPOSTA

if [[ "$RESPOSTA" =~ ^[Ss]$ ]]; then
    read -p "IP da BMC/IPMI: " BMC_IP
    read -p "Usuário IPMI: " BMC_USER
    read -s -p "Senha IPMI: " BMC_PASS
    echo ""
    echo "Enviando comando Chassis Power Cycle via IPMI..."
    ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" chassis power cycle
else
    echo "Para concluir a gravação, execute 'reboot' ou realize o Power Cycle via IPMI manualmente."
fi

echo "✅ Processo executado com sucesso!"
