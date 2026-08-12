#!/bin/sh

# Aborta o script em erros não tratados
set -e

# Função de pausa em sintaxe POSIX sh com limpeza de buffer
pausar_para_usuario() {
    echo ""
    echo "============================================================"
    echo "⏸️  [PAUSA - AÇÃO MANUAL NECESSÁRIA]"
    echo "   $1"
    echo "============================================================"
    printf "Pressione [ENTER] assim que concluir para continuar..."
    read unused < /dev/tty
    echo ""
}

# Verificação de Root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Este script DEVE ser executado como root."
    exit 1
fi

echo "============================================================"
echo " 1. Verificando Conectividade e IP do Host"
echo "============================================================"

HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
fi
echo "IP detectado do host: ${HOST_IP}"

echo "============================================================"
echo " 2. Configurando Repositórios e Instalando Dependências"
echo "============================================================"

cat > /etc/apk/repositories << 'EOF'
http://dl-cdn.alpinelinux.org/alpine/v3.20/main
http://dl-cdn.alpinelinux.org/alpine/v3.20/community
EOF

echo "Atualizando o sistema e instalando pacotes de compilação..."
apk update && apk upgrade

apk add --no-cache \
    ca-certificates bash wget tar gzip ipmitool \
    alpine-sdk autoconf automake libtool bison flex pkgconfig \
    linux-headers musl-dev gcompat \
    zlib zlib-dev openssl openssl-dev \
    pciutils pciutils-dev libpciaccess libpciaccess-dev \
    rdma-core rdma-core-dev \
    ccache git

update-ca-certificates

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

if ! ls /usr/lib/libz.so >/dev/null 2>&1; then
    ZLIB_LIB=$(find /usr/lib /lib -name "libz.so*" 2>/dev/null | head -n 1)
    if [ -n "$ZLIB_LIB" ]; then
        echo "Ajustando link simbólico da libz: $ZLIB_LIB"
        ln -sf "$ZLIB_LIB" /usr/lib/libz.so
    fi
fi

make -j"$(nproc)"
make install

if ! command -v mstflint >/dev/null 2>&1; then
    echo "❌ Erro grave: A compilação do mstflint falhou!"
    exit 1
fi
echo "✅ mstflint compilado com sucesso! Versão: $(mstflint -v)"

echo "============================================================"
echo " 4. Gerando Pacote de Backup para Instalação Rápida"
echo "============================================================"
mkdir -p /root/mstflint-alpine-build
cp /usr/local/bin/mstflint /usr/local/bin/mstconfig /root/mstflint-alpine-build/ 2>/dev/null || true
cp -r /usr/local/lib/mstflint /root/mstflint-alpine-build/lib 2>/dev/null || true
tar -czf /root/mstflint-alpine-x86_64.tar.gz -C /root mstflint-alpine-build

MSG_PAUSA_1="Execute no Prompt/PowerShell do Windows para baixar o backup:

   scp root@${HOST_IP}:/root/mstflint-alpine-x86_64.tar.gz %USERPROFILE%\Downloads\\"

pausar_para_usuario "$MSG_PAUSA_1"

echo "============================================================"
echo " 5. Múltipla Detecção de Placas Mellanox / NVIDIA"
echo "============================================================"

PCI_DEVS=$(lspci -d 15b3: | awk '{print $1}')

if [ -z "$PCI_DEVS" ]; then
    echo "❌ Nenhuma placa Mellanox (ID PCI 15b3) foi encontrada no barramento!"
    exit 1
fi

echo "Placas detectadas no sistema:"
echo "------------------------------------------------------------"
for DEV in $PCI_DEVS; do
    DEV_PSID=$(mstflint -d "$DEV" q 2>/dev/null | grep -i "PSID:" | awk '{print $2}' || echo "N/A")
    DEV_DESC=$(lspci -s "$DEV" | cut -d ':' -f3-)
    echo "  • Endereço PCI: $DEV | PSID: $DEV_PSID | Modelo:$DEV_DESC"
done
echo "------------------------------------------------------------"

echo "============================================================"
echo " 6. Seleção do Arquivo de Firmware (.bin)"
echo "============================================================"

echo "Informe o nome ou caminho do arquivo de firmware."
echo "(Exemplo: /root/fw-ConnectX5-rel-16_35_1012-MCX516A-CCA_Ax-UEFI-14.28.15-FlexBoot-3.6.804.bin)"
echo ""
printf "Nome/Caminho do arquivo .bin [/root/cx5fw.bin]: "
read FW_FILE < /dev/tty

if [ -z "$FW_FILE" ]; then
    FW_FILE="/root/cx5fw.bin"
fi

if [ ! -f "$FW_FILE" ]; then
    echo ""
    echo "O arquivo '$FW_FILE' não foi encontrado localmente."
    printf "Digite uma URL para baixar via wget (ou Pressione [ENTER] para SCP via Windows): "
    read FW_URL < /dev/tty

    if [ -n "$FW_URL" ]; then
        echo "Baixando arquivo via wget..."
        wget -O "$FW_FILE" "$FW_URL"
    else
        MSG_PAUSA_2="No Windows, envie o arquivo de firmware (.bin) executando:

   scp \"C:\caminho\seu_arquivo.bin\" root@${HOST_IP}:${FW_FILE}"

        pausar_para_usuario "$MSG_PAUSA_2"
    fi
fi

if [ ! -s "$FW_FILE" ]; then
    echo "❌ O arquivo $FW_FILE não existe ou está vazio (0 bytes)!"
    exit 1
fi

FILE_QUERY=$(mstflint -i "$FW_FILE" q 2>/dev/null || true)

if [ -z "$FILE_QUERY" ]; then
    echo "❌ O arquivo $FW_FILE é um firmware inválido ou está corrompido!"
    exit 1
fi

FILE_PSID=$(echo "$FILE_QUERY" | grep -i "PSID:" | awk '{print $2}')
echo ""
echo "✅ Arquivo de firmware carregado com sucesso!"
echo "   - Arquivo: $FW_FILE"
echo "   - PSID do Firmware: $FILE_PSID"

MSG_PAUSA_3="O firmware será aplicado em TODAS as placas compatíveis com o PSID: $FILE_PSID.
   A gravação de hardware é irreversível durante a execução."

pausar_para_usuario "$MSG_PAUSA_3"

echo "============================================================"
echo " 7. Atualização em Lote (Burn) e Habilitação na BIOS"
echo "============================================================"

for DEV in $PCI_DEVS; do
    echo ""
    echo "------------------------------------------------------------"
    echo " Processando placa PCI: $DEV"
    echo "------------------------------------------------------------"

    CARD_QUERY=$(mstflint -d "$DEV" q 2>/dev/null || true)
    CARD_PSID=$(echo "$CARD_QUERY" | grep -i "PSID:" | awk '{print $2}' || echo "DESCONHECIDO")

    echo "  - PSID da placa: $CARD_PSID"
    echo "  - PSID do arquivo: $FILE_PSID"

    if [ "$CARD_PSID" = "$FILE_PSID" ]; then
        echo "  ✅ PSIDs compatíveis! Iniciando gravação do firmware..."
        
        # Adicionada a flag -y para não abortar mesmo reescrevendo a mesma versão de FW
        mstflint -d "$DEV" -i "$FW_FILE" -y burn

        echo "  Configurando suporte a Boot na BIOS (Option ROM PXE/UEFI)..."
        mstconfig -d "$DEV" set EXP_ROM_PXE_ENABLE=1 EXP_ROM_UEFI_x86_ENABLE=1 -y

        mstconfig -d "$DEV" set LINK_TYPE_P1=2 LINK_TYPE_P2=2 -y 2>/dev/null || \
            echo "  Info: Placa é Ethernet fixa (EN). Parâmetros LINK_TYPE ignorados com sucesso."
        
        echo "  ✅ Placa $DEV atualizada e configurada!"
    else
        echo "  ⚠️ PULO DE SEGURANÇA: O PSID da placa ($CARD_PSID) diverge do firmware ($FILE_PSID)."
        echo "  A placa $DEV não foi alterada."
    fi
done

echo ""
echo "============================================================"
echo " 8. Operação Concluída - Power Cycle / Reinicialização"
echo "============================================================"

printf "Deseja realizar o Power Cycle via IPMI agora? (s/N): "
read RESPOSTA < /dev/tty

case "$RESPOSTA" in
    [Ss]* )
        printf "IP da BMC/IPMI: "
        read BMC_IP < /dev/tty
        printf "Usuário IPMI: "
        read BMC_USER < /dev/tty
        printf "Senha IPMI: "
        stty -echo
        read BMC_PASS < /dev/tty
        stty echo
        echo ""
        echo "Enviando comando Chassis Power Cycle via IPMI..."
        ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" chassis power cycle
        ;;
    * )
        echo "Execute 'reboot' ou realize o Power Cycle via IPMI manualmente para aplicar o novo firmware."
        ;;
esac

echo "✅ Script finalizado!"
