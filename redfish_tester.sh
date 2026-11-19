#!/bin/bash

# ==========================================
# Script de Teste Redfish API - Ubuntu
# ==========================================

# Limpar credenciais ao sair do script ou em caso de interrupção (Ctrl+C)
trap 'unset RF_IP RF_USER RF_PASS SYSTEM_ID MANAGER_ID; echo -e "\nCredenciais apagadas da memória. Saindo..."; exit' INT TERM EXIT

# 1. Instalação de Dependências
echo "Verificando dependências (curl, jq)..."
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    echo "Instalando dependências necessárias..."
    sudo apt-get update
    sudo apt-get install -y curl jq
fi

# 2. Coleta de Credenciais
echo -e "\n=== Configuração de Acesso Redfish ==="
read -p "Digite o IP do servidor (Ex: 192.168.1.100): " RF_IP
read -p "Digite o Usuário: " RF_USER
read -s -p "Digite a Senha: " RF_PASS
echo -e "\nCredenciais armazenadas temporariamente na sessão."

# Função base para chamadas Redfish (Ignora SSL com -k)
rf_get() {
    curl -k -s -u "$RF_USER:$RF_PASS" -H "Accept: application/json" "https://$RF_IP$1"
}

rf_post() {
    curl -k -s -u "$RF_USER:$RF_PASS" -H "Content-Type: application/json" -X POST -d "$2" "https://$RF_IP$1"
}

# 3. Descobrindo IDs dinamicamente (Geralmente 1 ou System.Embedded.1)
SYSTEM_ID=$(rf_get "/redfish/v1/Systems" | jq -r '.Members[0]."@odata.id" | select(. != null)')
MANAGER_ID=$(rf_get "/redfish/v1/Managers" | jq -r '.Members[0]."@odata.id" | select(. != null)')
CHASSIS_ID=$(rf_get "/redfish/v1/Chassis" | jq -r '.Members[0]."@odata.id" | select(. != null)')

if [ -z "$SYSTEM_ID" ]; then
    echo "Erro: Não foi possível conectar ao Redfish no IP $RF_IP. Verifique IP e credenciais."
    exit 1
fi

# 4. Menu de Ações
while true; do
    echo -e "\n=============================================="
    echo "       MENU DE TESTES REDFISH (BETA)          "
    echo "=============================================="
    echo " 1) Power Status"
    echo " 2) Power ON"
    echo " 3) Power OFF (forçado)"
    echo " 4) Soft Shutdown (ACPI, gracioso)"
    echo " 5) Power Cycle"
    echo " 6) Cold Reset BMC"
    echo " 7) Ativar/Status SOL OOB (Verificação de Rede)"
    echo " 8) LAN Config (Infos de Rede)"
    echo " 9) Chassis Status"
    echo "10) SDR List (Sensores / Temperaturas)"
    echo "11) SEL Log (Logs de Eventos)"
    echo "12) FRU Print (Informações de Fabricação)"
    echo " 0) Sair (Apaga os dados)"
    echo "=============================================="
    read -p "Escolha uma opção: " OPCAO

    case $OPCAO in
        1)
            echo -e "\n[Power Status]"
            rf_get "$SYSTEM_ID" | jq -r '"Estado da Energia: " + .PowerState'
            ;;
        2)
            echo -e "\n[Power ON]"
            rf_post "$SYSTEM_ID/Actions/ComputerSystem.Reset" '{"ResetType": "On"}' | jq .
            ;;
        3)
            echo -e "\n[Power OFF - Forçado]"
            rf_post "$SYSTEM_ID/Actions/ComputerSystem.Reset" '{"ResetType": "ForceOff"}' | jq .
            ;;
        4)
            echo -e "\n[Soft Shutdown - Gracioso]"
            rf_post "$SYSTEM_ID/Actions/ComputerSystem.Reset" '{"ResetType": "GracefulShutdown"}' | jq .
            ;;
        5)
            echo -e "\n[Power Cycle]"
            rf_post "$SYSTEM_ID/Actions/ComputerSystem.Reset" '{"ResetType": "ForceRestart"}' | jq .
            ;;
        6)
            echo -e "\n[Cold Reset BMC]"
            rf_post "$MANAGER_ID/Actions/Manager.Reset" '{"ResetType": "GracefulRestart"}' | jq .
            ;;
        7)
            # Redfish não estabelece a *conexão* do console SOL (isso é feito via SSH/IPMItool),
            # mas permite ver se os serviços de protocolo estão ativos.
            echo -e "\n[Status do Serviço SOL / IPMI / SSH]"
            rf_get "$MANAGER_ID/NetworkProtocol" | jq '{IPMI: .IPMI, SSH: .SSH, SerialConsole: .SerialConsole}'
            echo "Nota: A conexão ao console SOL propriamente dita geralmente requer 'ipmitool sol activate' ou SSH."
            ;;
        8)
            echo -e "\n[LAN Config (Interfaces de Rede do Manager)]"
            ETH_URI=$(rf_get "$MANAGER_ID/EthernetInterfaces" | jq -r '.Members[0]."@odata.id"')
            rf_get "$ETH_URI" | jq '{Interface: .Id, MAC: .MACAddress, IPv4: .IPv4Addresses, VLAN: .VLAN}'
            ;;
        9)
            echo -e "\n[Chassis Status]"
            rf_get "$CHASSIS_ID" | jq '{Estado: .Status.State, Saude: .Status.Health, Energia: .PowerState}'
            ;;
        10)
            echo -e "\n[SDR List (Sensores)]"
            # Alguns servidores usam a rota de Sensores, outros Thermal/Power.
            echo "Buscando temperaturas..."
            rf_get "$CHASSIS_ID/Thermal" | jq '.Temperatures[]? | {Nome: .Name, Temp_C: .ReadingCelsius, Status: .Status.Health}'
            echo "Buscando energia/voltagens..."
            rf_get "$CHASSIS_ID/Power" | jq '.Voltages[]? | {Nome: .Name, Volts: .ReadingVolts, Status: .Status.Health}'
            ;;
        11)
            echo -e "\n[SEL Log (Logs do Sistema)]"
            LOG_URI=$(rf_get "$SYSTEM_ID/LogServices" | jq -r '.Members[0]."@odata.id"')
            if [ "$LOG_URI" != "null" ]; then
                rf_get "$LOG_URI/Entries" | jq '.Members[] | {ID: .Id, Severidade: .Severity, Mensagem: .Message, Data: .Created}' | head -n 30
                echo "... (Mostrando apenas os mais recentes)"
            else
                echo "LogService não encontrado para este sistema."
            fi
            ;;
        12)
            echo -e "\n[FRU Print (Informações de Fabricação)]"
            rf_get "$CHASSIS_ID" | jq '{Fabricante: .Manufacturer, Modelo: .Model, PartNumber: .PartNumber, SerialNumber: .SerialNumber}'
            ;;
        0)
            # O 'trap' configurado no início limpará as variáveis automaticamente.
            break
            ;;
        *)
            echo "Opção inválida!"
            ;;
    esac
    
    read -p "Pressione [ENTER] para continuar..."
done
