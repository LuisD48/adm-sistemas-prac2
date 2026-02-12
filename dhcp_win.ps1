Set-Content -Path "dhcp_win.ps1" -Value @'
<#
.SYNOPSIS
    Automatización de Servidor DHCP para Windows Server
.DESCRIPTION
    Instala, configura y monitorea el rol DHCP.
    Incluye idempotencia y validación de rangos.
#>

# --- 1. FUNCIÓN DE INSTALACIÓN (IDEMPOTENCIA) ---
Function Instalar-RolDHCP {
    Write-Host "--- VERIFICANDO ESTADO DEL ROL DHCP ---" -ForegroundColor Cyan
    $dhcpInstalled = Get-WindowsFeature -Name DHCP

    if ($dhcpInstalled.Installed) {
        Write-Host "[OK] El rol DHCP ya está instalado." -ForegroundColor Green
    }
    else {
        Write-Host "[INFO] El rol DHCP no está instalado. Iniciando instalación..." -ForegroundColor Yellow
        try {
            Install-WindowsFeature DHCP -IncludeManagementTools -ErrorAction Stop
            Write-Host "[EXITO] Rol instalado correctamente." -ForegroundColor Green
        }
        catch {
            Write-Host "[ERROR] No se pudo instalar el rol: $_" -ForegroundColor Red
            Exit
        }
    }
}

# --- 2. ORQUESTACIÓN DE CONFIGURACIÓN DINÁMICA ---
Function Configurar-Ambito {
    Write-Host "`n--- CONFIGURACIÓN DEL ÁMBITO (SCOPE) ---" -ForegroundColor Cyan
    
    # Solicitar datos interactivos
    $NombreScope = Read-Host "Ingrese Nombre del Ámbito (ej. RedInterna)"
    $StartIP     = Read-Host "IP Inicial (Requisito: 192.168.100.50)"
    $EndIP       = Read-Host "IP Final   (Requisito: 192.168.100.150)"
    $SubnetMask  = "255.255.255.0"
    $Gateway     = Read-Host "Puerta de Enlace (Requisito: 192.168.100.1)"
    $DNSServer   = Read-Host "Servidor DNS (IP de tu Práctica 1)"
    
    # Validar si el ámbito ya existe para evitar errores
    $ScopeID = "192.168.100.0" # ID de red basado en la práctica
    
    if (Get-DhcpServerv4Scope -ScopeId $ScopeID -ErrorAction SilentlyContinue) {
        Write-Host "[ALERTA] Ya existe un ámbito con ID $ScopeID. Omitiendo creación." -ForegroundColor Yellow
    }
    else {
        try {
            # Crear el Ámbito
            Add-DhcpServerv4Scope -Name $NombreScope -StartRange $StartIP -EndRange $EndIP -SubnetMask $SubnetMask -State Active -ErrorAction Stop
            
            # Configurar Opciones (Router y DNS)
            Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 3 -Value $Gateway # Router
            Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 6 -Value $DNSServer # DNS
            
            Write-Host "[EXITO] Ámbito '$NombreScope' configurado correctamente." -ForegroundColor Green
            
            # Reiniciar servicio para aplicar cambios
            Restart-Service DHCPServer
        }
        catch {
            Write-Host "[ERROR] Falló la configuración: $_" -ForegroundColor Red
        }
    }
}

# --- 3. MÓDULO DE MONITOREO ---
Function Mostrar-Estado {
    Write-Host "`n--- ESTADO DEL SERVICIO ---" -ForegroundColor Cyan
    $Service = Get-Service DHCPServer
    Write-Host "Estado del Servicio: " -NoNewline
    if ($Service.Status -eq "Running") { Write-Host "ACTIVO (RUNNING)" -ForegroundColor Green } 
    else { Write-Host "DETENIDO" -ForegroundColor Red }

    Write-Host "`n--- CONCESIONES (LEASES) ACTIVAS ---" -ForegroundColor Cyan
    $Leases = Get-DhcpServerv4Lease -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue
    if ($Leases) {
        $Leases | Select-Object IPAddress,HostName,ClientId,LeaseExpiryTime | Format-Table -AutoSize
    } else {
        Write-Host "No hay clientes conectados aún." -ForegroundColor Gray
    }
}

# --- EJECUCIÓN PRINCIPAL ---
Clear-Host
Instalar-RolDHCP
Configurar-Ambito
Mostrar-Estado
Write-Host "`n[FIN] Script finalizado." -ForegroundColor Cyan
'@