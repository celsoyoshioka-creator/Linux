#!/bin/sh

# Aborta o script em erros não tratados
set -e

# Função de pausa em sintaxe POSIX sh
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
echo " 5. Seleção do Arquivo de Firmware (.bin)"
echo "============================================================"

echo "Informe o nome ou caminho do arquivo de firmware."
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
FILE_FW_VER=$(echo "$FILE_QUERY" | grep -i "FW Version:" | awk '{print $3}')

echo ""
echo "✅ Arquivo de firmware carregado com sucesso!"
echo "   - Arquivo: $FW_FILE"
echo "   - PSID do Firmware: $FILE_PSID"
echo "   - Versão do Firmware no Arquivo: $FILE_FW_VER"

echo "============================================================"
echo " 6. Filtrando Placas Elegíveis para Atualização"
echo "============================================================"

PCI_DEVS=$(lspci -d 15b3: | awk '{print $1}')

if [ -z "$PCI_DEVS" ]; then
    echo "❌ Nenhuma placa Mellanox (ID PCI 15b3) foi encontrada no barramento!"
    exit 1
fi

VALID_DEVS=""
COUNT=0

for DEV in $PCI_DEVS; do
    CARD_QUERY=$(mstflint -d "$DEV" q 2>/dev/null || true)
    CARD_PSID=$(echo "$CARD_QUERY" | grep -i "PSID:" | awk '{print $2}' || echo "N/A")
    CARD_FW_VER=$(echo "$CARD_QUERY" | grep -i "FW Version:" | awk '{print $3}' || echo "N/A")

    # Regras: O PSID deve ser idêntico E a versão do FW deve ser diferente
    if [ "$CARD_PSID" = "$FILE_PSID" ] && [ "$CARD_FW_VER" != "$FILE_FW_VER" ]; then
        COUNT=$((COUNT + 1))
        
        # Armazena mapeamento no formato: INDICE|DEV|FW_ATUAL
        eval "DEV_MAP_$COUNT=\"$DEV\""
        eval "FW_MAP_$COUNT=\"$CARD_FW_VER\""
    else
        echo " ℹ️ Placa $DEV ignorada (PSID: $CARD_PSID | FW Atual: $CARD_FW_VER) -> Já está atualizada ou é incompatível."
    fi
done

if [ "$COUNT" -eq 0 ]; then
    echo ""
    echo "✅ Todas as placas compatíveis com o PSID $FILE_PSID já estão na versão $FILE_FW_VER (ou nenhuma placa compatível foi encontrada)."
    echo "Nenhuma atualização pendente!"
    exit 0
fi

echo ""
echo "============================================================"
echo " 7. Seleção da Placa para Atualizar"
echo "============================================================"
echo "Selecione UMA placa para aplicar a atualização:"
echo ""

i=1
while [ "$i" -le "$COUNT" ]; do
    eval "TMP_DEV=\$DEV_MAP_$i"
    eval "TMP_FW=\$FW_MAP_$i"
    echo "  $i) Endereço PCI: $TMP_DEV (FW Atual: $TMP_FW ➔ Novo FW: $FILE_FW_VER)"
    i=$((i + 1))
done

echo ""
printf "Digite o número da placa desejada (1-$COUNT) ou '0' para cancelar: "
read OPCAO < /dev/tty

if [ "$OPCAO" -eq 0 ] 2>/dev/null; then
    echo "Operação cancelada pelo usuário."
    exit 0
fi

if [ "$OPCAO" -lt 1 ] 2>/dev/null || [ "$OPCAO" -gt "$COUNT" ] 2>/dev/null; then
    echo "❌ Opção inválida! Encerrando."
    exit 1
fi

eval "SELECTED_DEV=\$DEV_MAP_$OPCAO"

MSG_PAUSA_3="Tudo pronto para gravar o firmware na placa $SELECTED_DEV.
   A gravação de hardware é irreversível durante a execução."

pausar_para_usuario "$MSG_PAUSA_3"

echo "============================================================"
echo " 8. Gravando Firmware (Burn) e Habilitando Option ROM"
echo "============================================================"

echo "Executando burn do firmware na placa $SELECTED_DEV..."
mstflint -d "$SELECTED_DEV" -i "$FW_FILE" -y burn

echo "Configurando suporte a Boot na BIOS (Option ROM PXE/UEFI)..."
mstconfig -d "$SELECTED_DEV" set EXP_ROM_PXE_ENABLE=1 EXP_ROM_UEFI_x86_ENABLE=1 -y

mstconfig -d "$SELECTED_DEV" set LINK_TYPE_P1=2 LINK_TYPE_P2=2 -y 2>/dev/null || \
    echo "Info: Placa é Ethernet fixa (EN). Parâmetros LINK_TYPE ignorados com sucesso."

echo "✅ Placa $SELECTED_DEV atualizada com sucesso!"

echo "============================================================"
echo " 9. Operação Concluída - Power Cycle / Reinicialização"
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

echo "✅ Processo finalizado!"
