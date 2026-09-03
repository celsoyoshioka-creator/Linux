#!/bin/bash

# Define a linha divisória da tabela ASCII
SEP="+----------------------+---------------------------------------------------------+"

# Função para imprimir linhas de dados
print_row() {
    # Corta o valor se for maior que 55 caracteres para não quebrar a tabela
    local val="${2:0:55}"
    printf "| %-20s | %-55s |\n" "$1" "$val"
}

# --- COLETA DE DADOS DE HARDWARE ---

# 1. Hostname e SO
HOST=$(hostname)
OS=$(grep "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2)
[ -z "$OS" ] && OS=$(uname -srm)

# 2. Processador
CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs)
CPU_CORES=$(nproc 2>/dev/null || echo "?")
CPU_INFO="${CPU_CORES}x ${CPU_MODEL}"

# 3. Memória RAM (Capacidade Lógica)
RAM_INFO=$(free -h 2>/dev/null | awk '/^Mem:/ || /^Memória:/ {print "Total: "$2" | Usada: "$3" | Disp: "$7}')
[ -z "$RAM_INFO" ] && RAM_INFO="Não foi possível ler a RAM"

# 4. Bancos de Memória (DIMM Slots Físicos)
if [ "$EUID" -ne 0 ]; then
    DIMM_INFO="Requer execução com 'sudo' para ler os slots"
elif command -v dmidecode &> /dev/null; then
    TOTAL_SLOTS=$(dmidecode -t memory 2>/dev/null | grep -c "^[[:space:]]*Size:")
    FREE_SLOTS=$(dmidecode -t memory 2>/dev/null | grep -ic "No Module Installed")
    
    if [ "$TOTAL_SLOTS" -gt 0 ]; then
        OCCUPIED_SLOTS=$((TOTAL_SLOTS - FREE_SLOTS))
        DIMM_INFO="Total: $TOTAL_SLOTS slot(s) | Ocupados: $OCCUPIED_SLOTS | Livres: $FREE_SLOTS"
    else
        DIMM_INFO="Informação não suportada ou VM (Virtual Machine)"
    fi
else
    DIMM_INFO="Pacote 'dmidecode' não instalado"
fi

# 5. Discos físicos (Ignora loopbacks e cd-roms)
DISKS=$(lsblk -nd -o NAME,SIZE -e 7,11 2>/dev/null | awk '{print $1" ("$2")"}' | paste -sd ", " -)
[ -z "$DISKS" ] && DISKS="Nenhum disco físico detectado"

# 6. Placas de rede (Ignora loopback)
NETWORKS=$(ip -4 -br addr show 2>/dev/null | grep -v "^lo" | awk '{print $1" ("$3")"}' | paste -sd ", " -)
[ -z "$NETWORKS" ] && NETWORKS="Nenhuma rede detectada"


# --- RENDERIZAÇÃO DA TABELA ASCII ---
echo ""
echo "$SEP"
# Calcula o centro exato para o título
TITLE="INVENTÁRIO DE HARDWARE: ${HOST^^}"
printf "| %-78s |\n" "$(printf "%*s" $(( (${#TITLE} + 78) / 2 )) "$TITLE")"
echo "$SEP"

# Imprime as linhas
print_row "Sistema Operacional" "$OS"
print_row "Processador (CPU)" "$CPU_INFO"
print_row "Memória RAM" "$RAM_INFO"
print_row "Slots DIMM (Bancos)" "$DIMM_INFO"
print_row "Discos Físicos" "$DISKS"
print_row "Placas de Rede / IP" "$NETWORKS"

echo "$SEP"
echo ""
