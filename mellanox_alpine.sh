#!/bin/bash

# Interrompe o script imediatamente se ocorrer algum erro
set -e

# Detecta o IP principal da máquina
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -i | awk '{print $1}')
fi

echo "============================================================"
echo " 1. Configurando repositórios apk e toolchain de build"
echo "============================================================"
echo "Versão do Alpine Linux:"
cat /etc/alpine-release

cat > /etc/apk/repositories << 'EOF'
http://dl-cdn.alpinelinux.org/alpine/v3.20/main
http://dl-cdn.alpinelinux.org/alpine/v3.20/community
EOF

echo "Atualizando repositórios e pacotes do sistema..."
apk update && apk upgrade
apk add --no-cache ca-certificates bash ipmitool
update-ca-certificates

echo "Instalando dependências de desenvolvimento..."
apk add --no-cache \
    alpine-sdk autoconf automake libtool bison flex pkgconfig \
    linux-headers musl-dev gcompat \
    zlib-dev openssl-dev \
    pciutils pciutils-dev libpciaccess libpciaccess-dev \
    rdma-core rdma-core-dev \
    ccache git

echo ""
echo "============================================================"
echo " 2. Clonando e compilando o mstflint"
echo "============================================================"
cd /root
if [ -d "mstflint" ]; then
    rm -rf mstflint
fi

git clone --depth 1 https://github.com/Mellanox/mstflint.git
cd mstflint

echo "Aplicando patches de compatibilidade com musl libc..."
find . -type f \( -name '*.c' -o -name '*.h' -o -name '*.cpp' -o -name '*.hpp' \) -exec sed -i \
    -e 's/u_int8_t/uint8_t/g' \
    -e 's/u_int16_t/uint16_t/g' \
    -e 's/u_int32_t/uint32_t/g' \
    -e 's/u_int64_t/uint64_t/g' {} +

sed -i '/#include <sys\/types.h>/a #include <stdint.h>' include/mtcr_ul/mtcr_com_defs.h

echo "Iniciando compilação do mstflint..."
./autogen.sh
mkdir build && cd build
../configure --enable-openssl

# Ajuste do link simbólico do zlib caso necessário
if ! ls /usr/lib/libz.so >/dev/null 2>&1; then
    ZLIB_LIB=$(find /usr/lib /lib -name "libz.so*" 2>/dev/null | head -n 1)
    if [ -n "$ZLIB_LIB" ]; then
        echo "Ajustando link simbólico do zlib: $ZLIB_LIB"
        ln -sf "$ZLIB_LIB" /usr/lib/libz.so
    fi
fi

make -j"$(nproc)" 2>&1 | tee /root/build.log | grep -i "error:" || true
make install

echo "Verificando versão do mstflint instalado:"
mstflint -v

echo ""
echo "============================================================"
echo " 3. Criando pacote de backup para reuso em outras máquinas"
echo "============================================================"
mkdir -p /root/mstflint-alpine-build
cp /usr/local/bin/mstflint /usr/local/bin/mstconfig /root/mstflint-alpine-build/ 2>/dev/null || true
cp -r /usr/local/lib/mstflint /root/mstflint-alpine-build/lib 2>/dev/null || true
tar -czf /root/mstflint-alpine-x86_64.tar.gz -C /root mstflint-alpine-build

echo ""
echo "------------------------------------------------------------"
echo " [AÇÃO NO WINDOWS - FAZER BACKUP]"
echo " Execute o comando abaixo no PowerShell/Prompt do Windows:"
echo "------------------------------------------------------------"
echo "scp root@${HOST_IP}:/root/mstflint-alpine-x86_64.tar.gz %USERPROFILE%\Downloads\"
echo "------------------------------------------------------------"
echo ""

echo "============================================================"
echo " 4. Identificando Placa Mellanox / NVIDIA ConnectX"
echo "============================================================"
PCI_DEV=$(lspci -d 15b3: | head -n 1 | awk '{print $1}')

if [ -z "$PCI_DEV" ]; then
    echo "❌ Erro: Nenhuma placa Mellanox (ID 15b3) encontrada no sistema!"
    exit 1
fi

echo "Placa detectada no endereço PCI: $PCI_DEV"
echo "------------------------------------------------------------"
mstflint -d "$PCI_DEV" q

CARD_PSID=$(mstflint -d "$PCI_DEV" q | grep -i "PSID:" | awk '{print $2}')
echo "PSID da placa atual: $CARD_PSID"

echo ""
echo "------------------------------------------------------------"
echo " [AÇÃO NO WINDOWS - ENVIAR FIRMWARE]"
echo " Transfira o arquivo .bin do firmware baixado executando no Windows:"
echo "------------------------------------------------------------"
echo "scp \"C:\caminho\seu_arquivo.bin\" root@${HOST_IP}:/root/cx5fw.bin"
echo "------------------------------------------------------------"
echo ""

# Pausa para o usuário realizar o envio do firmware no Windows
read -p "Pressione [ENTER] após ter enviado o arquivo /root/cx5fw.bin para o Alpine..."

if [ ! -f /root/cx5fw.bin ]; then
    echo "❌ Erro: Arquivo /root/cx5fw.bin não foi encontrado!"
    exit 1
fi

echo ""
echo "============================================================"
echo " 5. Validando e gravando o Firmware (Burn)"
echo "============================================================"
echo "Informações do arquivo de firmware enviado:"
mstflint -i /root/cx5fw.bin q

FILE_PSID=$(mstflint -i /root/cx5fw.bin q | grep -i "PSID:" | awk '{print $2}')

echo "Comparando PSIDs:"
echo "  - Placa: $CARD_PSID"
echo "  - Arquivo: $FILE_PSID"

if [ "$CARD_PSID" != "$FILE_PSID" ]; then
    echo "❌ ATENÇÃO: PSIDs incompatíveis! Operação abortada por segurança."
    exit 1
fi

echo "✅ PSIDs compatíveis! Efetuando gravação do firmware na placa $PCI_DEV..."
mstflint -d "$PCI_DEV" -i /root/cx5fw.bin burn

echo ""
echo "============================================================"
echo " 6. Habilitando Option ROM (PXE e UEFI) na BIOS"
echo "============================================================"
mstconfig -d "$PCI_DEV" set EXP_ROM_PXE_ENABLE=1 EXP_ROM_UEFI_x86_ENABLE=1 -y

echo "Tentando aplicar LINK_TYPE para VPI (se aplicável)..."
mstconfig -d "$PCI_DEV" set LINK_TYPE_P1=2 LINK_TYPE_P2=2 -y 2>/dev/null || echo "Info: Placa é variante EN (Ethernet-only). Parâmetro LINK_TYPE ignorado."

echo "Configuração final da placa:"
mstconfig -d "$PCI_DEV" q | grep -i "link_type\|exp_rom"

echo ""
echo "============================================================"
echo " 7. Opções de Reinicialização / Power Cycle"
echo "============================================================"
echo "As alterações na Option ROM/Firmware exigem um Power Cycle do hardware."
echo ""
read -p "Deseja realizar o Power Cycle via IPMI agora? (s/N): " RESPOSTA

if [[ "$RESPOSTA" =~ ^[Ss]$ ]]; then
    read -p "IP da BMC/IPMI: " BMC_IP
    read -p "Usuário IPMI: " BMC_USER
    read -s -p "Senha IPMI: " BMC_PASS
    echo ""
    echo "Executando Chassis Power Cycle via IPMI..."
    ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" chassis power cycle
else
    echo ""
    echo "Para fazer o Power Cycle via IPMI manualmente mais tarde, execute:"
    echo "ipmitool -I lanplus -H <IP_BMC> -U <user> -P '<senha>' chassis power cycle"
    echo ""
    echo "Ou apenas reinicie o sistema operacional rodando: reboot"
fi

echo ""
echo "✅ Script concluído com sucesso!"
