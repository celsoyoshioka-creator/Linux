#!/bin/bash

# Garante que os caminhos de binários de sistema estejam acessíveis (útil no RHEL/CentOS)
export PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin:/bin:/usr/bin

# Linhas divisórias das tabelas ASCII (ambas com exatamente 82 caracteres de largura)
SEP="+----------------------+---------------------------------------------------------+"
DIMM_SEP="+----------------------+----------------+----------------+-----------------------+"

# Função para imprimir linhas da tabela principal
print_row() {
    local val="${2:0:55}"
    printf "| %-20s | %-55s |\n" "$1" "$val"
}

# --- COLETA DE DADOS GERAIS DE HARDWARE ---

HOST=$(hostname)
if [ -f /etc/os-release ]; then
    OS=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'"' -f2)
else
    OS=$(uname -srm)
fi

CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs)
CPU_CORES=$(nproc 2>/dev/null || echo "?")
CPU_INFO="${CPU_CORES}x ${CPU_MODEL}"

RAM_INFO=$(free -h 2>/dev/null | awk '/^Mem:/ || /^Memória:/ {print "Total: "$2" | Usada: "$3" | Disp: "$7}')
[ -z "$RAM_INFO" ] && RAM_INFO="Não foi possível ler a RAM"

DISKS=$(lsblk -nd -o NAME,SIZE -e 7,11,252 2>/dev/null | awk '{print $1" ("$2")"}' | paste -sd ", " -)
[ -z "$DISKS" ] && DISKS="Nenhum disco físico detectado"

NETWORKS=$(ip -4 -o addr show 2>/dev/null | grep -v " lo " | awk '{print $2" ("$4")"}' | paste -sd ", " -)
[ -z "$NETWORKS" ] && NETWORKS="Nenhuma rede detectada"


# --- 1. RENDERIZAÇÃO DA TABELA PRINCIPAL ---
echo ""
echo "$SEP"
TITLE="INVENTÁRIO DE HARDWARE: ${HOST^^}"
printf "| %-78s |\n" "$(printf "%*s" $(( (${#TITLE} + 78) / 2 )) "$TITLE")"
echo "$SEP"

print_row "Sistema Operacional" "$OS"
print_row "Processador (CPU)" "$CPU_INFO"
print_row "Memória RAM (SO)" "$RAM_INFO"
print_row "Discos Físicos" "$DISKS"
print_row "Placas de Rede / IP" "$NETWORKS"
echo "$SEP"
echo ""


# --- 2. RENDERIZAÇÃO DA TABELA DE DIMMS (SLOTS DE MEMÓRIA) ---
echo "$DIMM_SEP"
DIMM_TITLE="DETALHAMENTO DOS SLOTS DE MEMORIA (DIMM)"
printf "| %-78s |\n" "$(printf "%*s" $(( (${#DIMM_TITLE} + 78) / 2 )) "$DIMM_TITLE")"

# Valida permissões e dependências antes de gerar a tabela
if [ "$EUID" -ne 0 ]; then
    echo "$DIMM_SEP"
    printf "| %-78s |\n" " [!] ERRO: Requer privilégios de root (sudo) para ler os slots físicos."
    echo "$DIMM_SEP"
elif ! command -v dmidecode &> /dev/null; then
    echo "$DIMM_SEP"
    printf "| %-78s |\n" " [!] ERRO: Pacote 'dmidecode' não está instalado."
    printf "| %-78s |\n" " Instale com: apt install dmidecode (Debian) ou yum install dmidecode (RHEL)"
    echo "$DIMM_SEP"
else
    # Processa a saída do dmidecode com awk para criar a tabela de slots
    dmidecode -t 17 2>/dev/null | awk -v sep="$DIMM_SEP" '
    BEGIN {
        print sep
        printf "| %-20s | %-14s | %-14s | %-21s |\n", "LOCALIZADOR", "TAMANHO", "TIPO", "VELOCIDADE"
        print sep
        count = 0
    }
    /^[[:space:]]*Locator:/ { loc = $0; sub(/^[[:space:]]*Locator:[[:space:]]*/, "", loc); }
    /^[[:space:]]*Size:/    { size = $0; sub(/^[[:space:]]*Size:[[:space:]]*/, "", size); }
    /^[[:space:]]*Type:/    { type = $0; sub(/^[[:space:]]*Type:[[:space:]]*/, "", type); }
    /^[[:space:]]*Speed:/   { speed = $0; sub(/^[[:space:]]*Speed:[[:space:]]*/, "", speed); }
    
    /^$/ {
        if (loc != "" && size != "") print_row()
    }
    
    END {
        # Garante a impressão do último bloco se não houver linha vazia no final
        if (loc != "" && size != "") print_row()
        
        if (count == 0) {
            printf "| %-78s |\n", " Nenhum slot detectado (Pode ser uma Máquina Virtual)."
        }
        print sep
    }
    
    function print_row() {
        # Tratamento de slots vazios ou não identificados
        if (size == "No Module Installed" || size == "No module installed") {
            size = "Livre"
            type = "-"
            speed = "-"
        } else if (size == "Not Specified") {
            size = "Desconhecido"
        }
        if (speed == "Unknown") speed = "Desconhecida"
        if (type == "Unknown") type = "Desconhecido"

        # Imprime a linha formatada cortando strings muito longas para não quebrar a tabela
        printf "| %-20s | %-14s | %-14s | %-21s |\n", substr(loc, 1, 20), substr(size, 1, 14), substr(type, 1, 14), substr(speed, 1, 21)
        
        # Reseta as variáveis para o próximo slot
        loc=""; size=""; type=""; speed=""
        count++
    }
    '
fi
echo ""
