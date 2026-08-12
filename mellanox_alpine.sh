#!/bin/bash

# ==============================================================================
# SCRIPT DE INSTALAÇÃO E ATUALIZAÇÃO FAIL-SAFE PARA MSTFLINT (ALPINE LINUX)
# ==============================================================================

# Aborta o script em erros não tratados, variáveis não declaradas e falhas em pipes
set -euo pipefail

# Captura erros e exibe informações de depuração
trap 'echo -e "\n❌ [ERRO] Ocorreu uma falha na linha $LINENO. Processo interrompido de forma segura."; exit 1' ERR

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

# Detecta o IP principal com fallback inteligente
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

echo "Atualizando o sistema e instalando ferramentas essenciais (curl, ipmitool, build-tools)..."
apk update && apk upgrade

# Adiciona todas as dependências de runtime, compilação e gerenciamento de rede/hardware
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

echo "Aplicando patches de compatibilidade de tipos no código fonte..."
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

# Confirma que o binário foi compilado e está funcional
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

echo "------------------------------------------------------------"
echo " [BACKUP GERADO] Caso queira salvar no Windows, rode:"
echo " scp root@${HOST_IP}:/root/mstflint-alpine-x86_64.tar.gz %USERPROFILE%\\Downloads\\"
echo "------------------------------------------------------------"

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
# 5. AUTOMAÇÃO DO DOWNLOAD DO FIRMWARE (FAIL-SAFE)
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 6. Obtenção do Arquivo de Firmware (.bin)"
echo "============================================================"

# Se o arquivo já existir localmente (ex: se você enviou via SCP), ele aproveita.
if [ ! -f /root/cx5fw.bin ]; then
    echo "Arquivo /root/cx5fw.bin não encontrado localmente."
    echo ""
    echo "Opções para obter o firmware:"
    echo "1) Insira a URL direta para download do arquivo .bin"
    echo "2) Envie manualmente via Windows/SCP em outra janela"
    read -p "Cole a URL do Firmware (.bin) ou pressione [ENTER] para esperar o envio manual: " FW_URL

    if [ -n "$FW_URL" ]; then
        echo "Baixando o arquivo de firmware da URL informada..."
        curl -L -s -o /root/cx5fw.bin "$FW_URL"
    else
        read -p "Envie o arquivo para /root/cx5fw.bin e pressione [ENTER] para continuar..."
    fi
fi

# Validação se o arquivo de fato existe e não está zerado
if [ ! -s /root/cx5fw.bin ]; then
    echo "❌ O arquivo /root/cx5fw.bin não existe ou está vazio!"
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
    echo "❌ [BLOQUEIO DE SEGURANÇA] PSID Incompatível!"
    echo "O firmware fornecido NÃO é para este modelo de placa. Operação abortada para evitar danos."
    exit 1
fi

echo "✅ Validação bem-sucedida! PSID correspondente."

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

# Tenta aplicar configurações de porta Ethernet caso seja variante VPI
mstconfig -d "$PCI_DEV" set LINK_TYPE_P1=2 LINK_TYPE_P2=2 -y 2>/dev/null || echo "Info: Placa é Ethernet fixa (EN). Parâmetros LINK_TYPE ignorados com sucesso."

# ------------------------------------------------------------------------------
# 8. FINALIZAÇÃO E POWER CYCLE VIA IPMI (OPCIONAL)
# ------------------------------------------------------------------------------
echo "============================================================"
echo " 9. Operação Concluída - Power Cycle / Reinicialização"
echo "============================================================"
echo ""
read -p "Deseja realizar o Power Cycle (desligamento frio) via IPMI agora? (s/N): " RESPOSTA

if [[ "$RESPOSTA" =~ ^[Ss]$ ]]; then
    read -p "IP da BMC/IPMI: " BMC_IP
    read -p "Usuário IPMI: " BMC_USER
    read -s -p "Senha IPMI: " BMC_PASS
    echo ""
    echo "Enviando comando Chassis Power Cycle via IPMI..."
    ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" chassis power cycle
else
    echo "Para concluir a gravação, execute um 'reboot' ou realize o Power Cycle via IPMI posteriormente."
fi

echo "✅ Processo executado com total segurança!"
