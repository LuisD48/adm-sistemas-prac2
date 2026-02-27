# Práctica 2: Automatización y Gestión del Servidor DHCP

Este repositorio contiene la implementación de una solución automatizada mediante scripts (Bash y PowerShell) para la instalación, configuración y monitoreo de un servidor DHCP. El sistema gestiona el direccionamiento dinámico de una red interna de forma segura y desatendida, garantizando la integridad de los parámetros de red entregados a los nodos cliente.

**Autor:** Luis
**Materia:** Administración de Sistemas

## Objetivo del Proyecto
Diseñar y desplegar una arquitectura de red automatizada capaz de orquestar servicios DHCP en entornos heterogéneos (Linux y Windows Server). Los scripts aseguran la instalación idempotente de los demonios/roles necesarios, la configuración dinámica de ámbitos (scopes) y la validación en tiempo real del estado del servicio.

## Requerimientos Técnicos Implementados
El entorno está configurado para operar bajo los siguientes parámetros base:
- **Segmento de Red:** `192.168.100.0 /24`
- **Rango de Asignación:** `192.168.100.50` al `192.168.100.150`
- **Puerta de Enlace (Gateway):** `192.168.100.1`
- **Servicio Linux:** `dhcp-server` (basado en `isc-dhcp-server`)
- **Servicio Windows:** Rol `DHCP Server` nativo

## Entregables y Características Principales

### 1. Instalación Idempotente y Desatendida
Los scripts evalúan el estado actual del sistema antes de realizar cambios.
- **Linux:** Verifica la existencia del paquete y, si no está presente, utiliza `zypper` para una instalación silenciosa y no interactiva.
- **Windows:** Detecta la presencia del rol DHCP. De no existir, ejecuta `Install-WindowsFeature -Name DHCP -IncludeManagementTools` de forma autónoma.

### 2. Orquestación de Configuración Dinámica
La automatización no está limitada a valores estáticos (`hardcoded`). Mediante un menú interactivo, el sistema solicita y valida:
- Nombre descriptivo del Ámbito (Scope).
- Rango inicial y final de direcciones IPv4.
- Tiempo de concesión de las IPs (*Lease Time*).
- Opciones de enrutamiento (Gateway) y resolución de nombres (DNS).
- *Linux:* Uso de `dhcpd -t` para validar la sintaxis del archivo `/etc/dhcpd.conf` antes de aplicar cambios.

### 3. Módulo de Monitoreo y Validación
Se incluye una suite de diagnóstico integrada en el menú principal para:
- Consultar el estado del servicio (`systemctl status dhcpd` / `Get-Service dhcpserver`) en tiempo real.
- Listar las concesiones activas, leyendo directamente de `/var/lib/dhcp/db/dhcpd.leases` en Linux o usando `Get-DhcpServerv4Lease` en Windows.

## Instrucciones de Ejecución

### Entorno Linux (OpenSUSE)
1. Clona el repositorio:
   ```bash
   git clone [https://github.com/LuisD48/adm-sistemas-prac2.git](https://github.com/LuisD48/adm-sistemas-prac2.git)
   cd adm-sistemas-prac2
