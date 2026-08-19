#!/bin/sh

# ==============================================================================
# SCRIPT BOOTSTRAP (Roda em 'sh' nativo do Alpine)
# Garante que o Bash seja instalado antes de interpretar o restante do código
# ==============================================================================

echo "============================================================"
echo " Inicializando Ambiente (Preparando Bash)..."
echo "============================================================"
apk update >/dev/null 2>&1
apk add --no-cache bash >/dev/null 2>&1

# Cria um arquivo temporário seguro para rodar o código avançado em Bash
BASH_SCRIPT="/tmp/setup_mellanox_core.bash"

cat << 'EOF_BASH' > "$BASH_SCRIPT"
#!/bin/bash

# Aborta o script em erros não tratados
set -e

# Função de pausa com limpeza de buffer
pausar_para_usuario() {
    echo ""
    echo "============================================================"
    echo "⏸️  [PAUSA - AÇÃO MANUAL NECESSÁRIA]"
    echo -e "   $1"
    echo "============================================================"
    printf "Pressione [ENTER] assim que concluir para continuar..."
    read -r unused < /dev/tty
    echo ""
}

# Verificação de Root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Este script DEVE ser executado como root."
    exit 1
fi

echo "✅ Bash inicializado com sucesso. Iniciando processo..."
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

echo "Atualizando o sistema e instalando dependências de compilação..."
apk update && apk upgrade

apk add --no-cache \
    ca-certificates wget tar gzip ipmitool \
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
echo "✅ mstflint compilado com sucesso! Versão: $(mstflint -v | head -n 1)"

echo "============================================================"
echo " 4. Obtenção e Seleção do Arquivo de Firmware (.bin)"
echo "============================================================"

echo "Informe o nome ou caminho do arquivo de firmware."
printf "Nome/Caminho do arquivo .bin [/root/cx5fw.bin]: "
read -r FW_FILE < /dev/tty

if [ -z "$FW_FILE" ]; then
    FW_FILE="/root/cx5fw.bin"
fi

if [ ! -f "$FW_FILE" ]; then
    echo ""
    echo "❌ O arquivo '$FW_FILE' não foi encontrado neste servidor."
    
    INSTRUCOES_SCP="O arquivo de firmware (.bin) precisa ser enviado do seu computador para o servidor Alpine.\n"
    INSTRUCOES_SCP+="   Siga este passo a passo detalhado no WINDOWS:\n\n"
    INSTRUCOES_SCP+="   1. Abra o menu Iniciar do Windows, digite 'PowerShell' e aperte Enter.\n"
    INSTRUCOES_SCP+="   2. Copie o comando abaixo, mas substitua o caminho 'C:\\caminho\\para\\seu_arquivo.bin'\n"
    INSTRUCOES_SCP+="      pelo local exato onde o firmware está salvo no seu PC (ex: Downloads).\n\n"
    INSTRUCOES_SCP+="      Comando a ser executado no PowerShell:\n"
    INSTRUCOES_SCP+="      scp \"C:\\caminho\\para\\seu_arquivo.bin\" root@${HOST_IP}:${FW_FILE}\n\n"
    INSTRUCOES_SCP+="   3. Aperte Enter no PowerShell. Se for perguntado 'Are you sure you want to continue connecting (yes/no)?', digite yes e dê Enter.\n"
    INSTRUCOES_SCP+="   4. Digite a senha do usuário root deste servidor Alpine.\n"
    INSTRUCOES_SCP+="   5. Aguarde o upload chegar a 100% e só então retorne a esta tela."

    pausar_para_usuario "$INSTRUCOES_SCP"
fi

if [ ! -s "$FW_FILE" ]; then
    echo "❌ O arquivo $FW_FILE não existe ou está vazio (0 bytes)!"
    echo "Verifique se a transferência via SCP foi concluída com sucesso e rode o script novamente."
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
echo "✅ Arquivo de firmware lido com sucesso!"
echo "   - Arquivo: $FW_FILE"
echo "   - PSID do Firmware: $FILE_PSID"
echo "   - Versão do Firmware no Arquivo: $FILE_FW_VER"

echo "============================================================"
echo " 5. Filtrando Placas Elegíveis para Atualização"
echo "============================================================"

PCI_DEVS=$(lspci -d 15b3: | awk '{print $1}')

if [ -z "$PCI_DEVS" ]; then
    echo "❌ Nenhuma placa Mellanox (ID PCI 15b3) foi encontrada no barramento!"
    exit 1
fi

# Utilizando Arrays nativos do Bash para mapeamento seguro
ELIGIBLE_DEVS=()
ELIGIBLE_FWS=()

for DEV in $PCI_DEVS; do
    CARD_QUERY=$(mstflint -d "$DEV" q 2>/dev/null || true)
    CARD_PSID=$(echo "$CARD_QUERY" | grep -i "PSID:" | awk '{print $2}' || echo "N/A")
    CARD_FW_VER=$(echo "$CARD_QUERY" | grep -i "FW Version:" | awk '{print $3}' || echo "N/A")

    # A placa só é elegível se o PSID for igual E a versão atual for diferente do arquivo
    if [ "$CARD_PSID" = "$FILE_PSID" ] && [ "$CARD_FW_VER" != "$FILE_FW_VER" ]; then
        ELIGIBLE_DEVS+=("$DEV")
        ELIGIBLE_FWS+=("$CARD_FW_VER")
    else
        echo " ℹ️ Placa $DEV ignorada (PSID: $CARD_PSID | FW Atual: $CARD_FW_VER) -> Já está atualizada ou não é compatível."
    fi
done

COUNT=${#ELIGIBLE_DEVS[@]}

if [ "$COUNT" -eq 0 ]; then
    echo ""
    echo "✅ Todas as placas compatíveis com o PSID $FILE_PSID já estão na versão $FILE_FW_VER."
    echo "Nenhuma atualização pendente!"
    exit 0
fi

echo ""
echo "============================================================"
echo " 6. Seleção da Placa para Atualizar"
echo "============================================================"
echo "Selecione UMA placa para aplicar a atualização:"
echo ""

for i in "${!ELIGIBLE_DEVS[@]}"; do
    NUM=$((i + 1))
    echo "  $NUM) Endereço PCI: ${ELIGIBLE_DEVS[$i]} (FW Atual: ${ELIGIBLE_FWS[$i]} ➔ Novo FW: $FILE_FW_VER)"
done

echo ""
printf "Digite o número da placa desejada (1-$COUNT) ou '0' para cancelar: "
read -r OPCAO < /dev/tty

if [ "$OPCAO" -eq 0 ] 2>/dev/null; then
    echo "Operação cancelada pelo usuário."
    exit 0
fi

if [ "$OPCAO" -lt 1 ] 2>/dev/null || [ "$OPCAO" -gt "$COUNT" ] 2>/dev/null; then
    echo "❌ Opção inválida! Encerrando."
    exit 1
fi

SELECTED_INDEX=$((OPCAO - 1))
SELECTED_DEV="${ELIGIBLE_DEVS[$SELECTED_INDEX]}"

MSG_PAUSA_3="Tudo pronto para gravar o firmware na placa $SELECTED_DEV.\n   A gravação no hardware é IRREVERSÍVEL durante a execução."

pausar_para_usuario "$MSG_PAUSA_3"

echo "============================================================"
echo " 7. Gravando Firmware (Burn) e Habilitando Option ROM"
echo "============================================================"

echo "Executando burn do firmware na placa $SELECTED_DEV..."
mstflint -d "$SELECTED_DEV" -i "$FW_FILE" -y burn

echo "Configurando suporte a Boot na BIOS (Option ROM PXE/UEFI)..."
mstconfig -d "$SELECTED_DEV" set EXP_ROM_PXE_ENABLE=1 EXP_ROM_UEFI_x86_ENABLE=1 -y

mstconfig -d "$SELECTED_DEV" set LINK_TYPE_P1=2 LINK_TYPE_P2=2 -y 2>/dev/null || \
    echo "Info: Placa é Ethernet fixa (EN). Parâmetros LINK_TYPE ignorados com sucesso."

echo "✅ Placa $SELECTED_DEV atualizada com sucesso!"

echo "============================================================"
echo " 8. Operação Concluída - Power Cycle / Reinicialização"
echo "============================================================"

printf "Deseja realizar o Power Cycle via IPMI agora? (s/N): "
read -r RESPOSTA < /dev/tty

case "$RESPOSTA" in
    [Ss]* )
        printf "IP da BMC/IPMI: "
        read -r BMC_IP < /dev/tty
        printf "Usuário IPMI: "
        read -r BMC_USER < /dev/tty
        printf "Senha IPMI: "
        stty -echo
        read -r BMC_PASS < /dev/tty
        stty echo
        echo ""
        echo "Enviando comando Chassis Power Cycle via IPMI..."
        ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" chassis power cycle
        ;;
    * )
        echo "Execute 'reboot' ou realize o Power Cycle via IPMI manualmente para que a BIOS carregue o novo firmware."
        ;;
esac

echo "✅ Processo finalizado com sucesso!"
EOF_BASH

# ==============================================================================
# Executa o script Bash protegido e, ao finalizar, remove o arquivo temporário
# ==============================================================================
bash "$BASH_SCRIPT"
rm -f "$BASH_SCRIPT"
