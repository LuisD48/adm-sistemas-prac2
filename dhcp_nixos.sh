#!/bin/sh

# Colores
VERDE='\033[0;32m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

# Archivo de destino para la configuración generada
CONFIG_FILE="/etc/nixos/dhcp-autogen.nix"

echo -e "${AZUL}=== AUTOMATIZACIÓN DHCP SERVER PARA NIXOS ===${NC}"

# 1. SOLICITUD DE DATOS (Interactivo)
echo "Ingrese la interfaz de red para el DHCP (ej. enp0s3, eth0):"
read INTERFACE
echo "Ingrese IP Inicial (ej. 192.168.100.50):"
read RANGE_START
echo "Ingrese IP Final (ej. 192.168.100.150):"
read RANGE_END
echo "Ingrese Gateway (ej. 192.168.100.1):"
read GATEWAY
echo "Ingrese DNS Server (IP Práctica 1 o 8.8.8.8):"
read DNS_SERVER

echo -e "\n${AZUL}Generando módulo de NixOS en $CONFIG_FILE...${NC}"

# 2. GENERACIÓN DEL ARCHIVO .NIX (Aquí está la magia declarativa)
cat <<EOF > $CONFIG_FILE
{ config, pkgs, ... }:

{
  # Habilitar el servidor DHCP
  services.dhcpd4 = {
    enable = true;
    interfaces = [ "$INTERFACE" ];
    extraConfig = ''
      option subnet-mask 255.255.255.0;
      option routers $GATEWAY;
      option domain-name-servers $DNS_SERVER;
      option domain-name "red-sistemas.local";
      
      subnet 192.168.100.0 netmask 255.255.255.0 {
        range $RANGE_START $RANGE_END;
        default-lease-time 600;
        max-lease-time 7200;
      }
    '';
  };

  # ABRIR EL FIREWALL (Vital en NixOS)
  networking.firewall.allowedUDPPorts = [ 67 ];
}
EOF

# 3. APLICAR CONFIGURACIÓN (El equivalente a "Instalar")
echo -e "${AZUL}Aplicando configuración (nixos-rebuild switch)... esto puede tardar.${NC}"
nixos-rebuild switch

if [ $? -eq 0 ]; then
    echo -e "${VERDE}[EXITO] Sistema reconstruido y DHCP activo.${NC}"
else
    echo -e "${ROJO}[FALLO] Error al reconstruir NixOS. Verifica tu configuration.nix.${NC}"
    exit 1
fi

# 4. MONITOREO Y VALIDACIÓN
echo -e "\n${AZUL}=== ESTADO DEL SERVICIO ===${NC}"
systemctl status dhcpd4 --no-pager | head -n 10

echo -e "\n${AZUL}=== CONCESIONES ACTUALES (Leases) ===${NC}"
LEASE_FILE="/var/lib/dhcp/dhcpd.leases"

if [ -f "$LEASE_FILE" ]; then
    cat $LEASE_FILE
else
    echo "Aún no hay clientes conectados (No existe $LEASE_FILE)."
fi