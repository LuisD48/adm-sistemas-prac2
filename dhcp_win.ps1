Set-Content -Path "dhcp_win.ps1" -Value @'
<#
.SYNOPSIS
    Gestor DHCP Simplificado - Tarea 2
.DESCRIPTION
    Script simple y directo para gesti?n de DHCP en Windows Server
#>

$ErrorActionPreference = "Stop"

# --- IMPORTAR M?DULO DHCP ---
try {
    Import-Module DHCPServer -ErrorAction SilentlyContinue
} catch {
    # M?dulo no disponible a?n
}

# --- VALIDAR PERMISOS DE ADMINISTRADOR ---
function Validar-EsAdministrador {
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidad)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Validar-EsAdministrador)) {
    Write-Host "`n[ERROR] Este script requiere privilegios de administrador." -ForegroundColor Red
    Write-Host "Ejecute PowerShell como Administrador." -ForegroundColor Yellow
    Pause
    Exit
}

# --- FUNCIONES AUXILIARES ---

function Validar-SintaxisIP([string]$Ip) {
    $addr = $null
    return [System.Net.IPAddress]::TryParse($Ip, [ref]$addr) -and 
           $addr.AddressFamily -eq 'InterNetwork' -and
           $Ip -ne "0.0.0.0" -and $Ip -ne "255.255.255.255"
}

function Convertir-IpAEntero([string]$Ip) {
    try {
        $ipObj = [System.Net.IPAddress]::Parse($Ip)
        $bytes = $ipObj.GetAddressBytes()
        if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
        return [System.BitConverter]::ToUInt32($bytes, 0)
    } catch { return 0 }
}

# --- [1] VERIFICAR INSTALACI?N DHCP ---
function Opcion1-VerificarDHCP {
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "   [1] VERIFICAR INSTALACI?N DHCP" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    Write-Host "`nComprobando estado del rol DHCP..." -ForegroundColor Gray
    
    $rol = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if ($rol.Installed) {
        Write-Host "`n DHCP EST? INSTALADO" -ForegroundColor Green
        
        # Mostrar estado del servicio
        $servicio = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        if ($servicio) {
            $estadoColor = if($servicio.Status -eq "Running"){"Green"}else{"Yellow"}
            Write-Host "  Estado del servicio: $($servicio.Status)" -ForegroundColor $estadoColor
        }
    } else {
        Write-Host "`n DHCP NO EST? INSTALADO" -ForegroundColor Red
        Write-Host "  Use la Opci?n [2] para instalarlo." -ForegroundColor Yellow
    }
    
    Write-Host "`nPresione cualquier tecla para volver al men?..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# --- [2] INSTALACI?N (SILENCIOSA) ---
function Opcion2-InstalarDHCP {
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "   [2] INSTALACI?N DHCP" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    # VERIFICAR SI YA EST? INSTALADO
    Write-Host "`nVerificando instalaci?n previa..." -ForegroundColor Gray
    $rol = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if ($rol.Installed) {
        Write-Host "`n[INFO] DHCP ya est? instalado en este servidor." -ForegroundColor Yellow
        $reinstalar = Read-Host "`n?Desea REINSTALAR y RECONFIGURAR desde cero? (S/N)"
        
        if ($reinstalar -notmatch "^(s|S)$") {
            Write-Host "`n[CANCELADO] Operaci?n cancelada." -ForegroundColor Yellow
            Pause
            return
        }
        
        # DESINSTALAR PRIMERO
        Write-Host "`nDesinstalando DHCP actual..." -ForegroundColor Yellow
        try {
            # Eliminar ?mbitos primero
            Import-Module DHCPServer -ErrorAction SilentlyContinue
            Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
            
            # Desinstalar rol
            Uninstall-WindowsFeature DHCP -Remove -IncludeManagementTools -ErrorAction Stop | Out-Null
            Write-Host "[OK] Desinstalaci?n completada." -ForegroundColor Green
        } catch {
            Write-Host "[ADVERTENCIA] Error en desinstalaci?n: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    # INSTALAR DHCP
    Write-Host "`nInstalando DHCP..." -ForegroundColor Cyan
    Write-Host "(Esto puede tardar unos minutos...)" -ForegroundColor Gray
    
    try {
        $resultado = Install-WindowsFeature DHCP -IncludeManagementTools -ErrorAction Stop
        
        if ($resultado.Success) {
            Write-Host "`n DHCP INSTALADO CORRECTAMENTE" -ForegroundColor Green
            
            # Cargar m?dulo
            Import-Module DHCPServer -ErrorAction Stop
            Write-Host " M?dulo DHCP cargado" -ForegroundColor Green
            
        } else {
            throw "La instalaci?n no se complet? exitosamente"
        }
        
    } catch {
        $errorMsg = $_.Exception.Message
        
        # Verificar si es el error 0x800f081f
        if ($errorMsg -match "0x800f081f" -or $errorMsg -match "archivos de origen") {
            Write-Host "`n[ERROR 0x800f081f] No se encontraron archivos de instalaci?n." -ForegroundColor Red
            Write-Host "`nSOLUCI?N:" -ForegroundColor Yellow
            Write-Host "1. Monte el ISO de Windows Server" -ForegroundColor White
            Write-Host "2. Ejecute este comando:" -ForegroundColor White
            Write-Host "   Install-WindowsFeature DHCP -Source D:\sources\sxs -IncludeManagementTools" -ForegroundColor Cyan
            Write-Host "   (Reemplace D: con la letra de su unidad ISO)" -ForegroundColor Gray
            Pause
            return
        } else {
            Write-Host "`n[ERROR] $errorMsg" -ForegroundColor Red
            Pause
            return
        }
    }
    
    # CONFIGURACI?N DEL ?MBITO
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "   CONFIGURACI?N DEL ?MBITO DHCP" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Solicitar datos de configuraci?n
    Write-Host "`nIngrese los par?metros de configuraci?n:`n" -ForegroundColor White
    
    # Nombre del ?mbito
    do {
        $NombreScope = Read-Host "Nombre del ?mbito (ej: Red-Principal)"
        if ([string]::IsNullOrWhiteSpace($NombreScope)) {
            Write-Host "[ERROR] El nombre no puede estar vac?o." -ForegroundColor Red
        }
    } until (-not [string]::IsNullOrWhiteSpace($NombreScope))
    
    # IP Inicial (debe terminar en .50)
    do {
        $StartIP = Read-Host "IP Inicial (debe terminar en .50, ej: 192.168.100.50)"
        
        if (-not (Validar-SintaxisIP $StartIP)) {
            Write-Host "[ERROR] Formato de IP inv?lido." -ForegroundColor Red
            continue
        }
        
        $ultimoOcteto = [int]($StartIP.Split(".")[-1])
        if ($ultimoOcteto -ne 50) {
            Write-Host "[ERROR] La IP inicial DEBE terminar en .50 (termin? en .$ultimoOcteto)" -ForegroundColor Red
            $StartIP = $null
        }
    } until ($StartIP -ne $null)
    
    # IP Final (debe terminar en .150)
    do {
        $EndIP = Read-Host "IP Final   (debe terminar en .150, ej: 192.168.100.150)"
        
        if (-not (Validar-SintaxisIP $EndIP)) {
            Write-Host "[ERROR] Formato de IP inv?lido." -ForegroundColor Red
            continue
        }
        
        $ultimoOcteto = [int]($EndIP.Split(".")[-1])
        if ($ultimoOcteto -ne 150) {
            Write-Host "[ERROR] La IP final DEBE terminar en .150 (termin? en .$ultimoOcteto)" -ForegroundColor Red
            $EndIP = $null
            continue
        }
        
        # Validar que sea mayor que la inicial
        $intStart = Convertir-IpAEntero $StartIP
        $intEnd = Convertir-IpAEntero $EndIP
        
        if ($intStart -ge $intEnd) {
            Write-Host "[ERROR] La IP final debe ser mayor que la inicial." -ForegroundColor Red
            $EndIP = $null
        }
    } until ($EndIP -ne $null)
    
    # Gateway
    do {
        $Gateway = Read-Host "Gateway (ej: 192.168.100.1)"
        
        if (-not (Validar-SintaxisIP $Gateway)) {
            Write-Host "[ERROR] Formato de IP inv?lido." -ForegroundColor Red
            $Gateway = $null
        }
    } until ($Gateway -ne $null)
    
    # DNS Primario
    do {
        $DNS1 = Read-Host "DNS Primario (ej: 8.8.8.8)"
        
        if (-not (Validar-SintaxisIP $DNS1)) {
            Write-Host "[ERROR] Formato de IP inv?lido." -ForegroundColor Red
            $DNS1 = $null
        }
    } until ($DNS1 -ne $null)
    
    # DNS Secundario (opcional)
    do {
        $DNS2 = Read-Host "DNS Secundario (Opcional - Enter para omitir)"
        
        if ([string]::IsNullOrWhiteSpace($DNS2)) {
            $DNS2 = $null
            break
        }
        
        if (-not (Validar-SintaxisIP $DNS2)) {
            Write-Host "[ERROR] Formato de IP inv?lido. Presione Enter para omitir." -ForegroundColor Red
        } else {
            break
        }
    } until ($false)
    
    # Calcular m?scara
    $primerOcteto = [int]($StartIP.Split(".")[0])
    if ($primerOcteto -lt 128) { $Mascara = "255.0.0.0" }
    elseif ($primerOcteto -lt 192) { $Mascara = "255.255.0.0" }
    else { $Mascara = "255.255.255.0" }
    
    # Mostrar resumen
    Write-Host "`n--- RESUMEN DE CONFIGURACI?N ---" -ForegroundColor Cyan
    Write-Host "Nombre:   $NombreScope" -ForegroundColor White
    Write-Host "Rango:    $StartIP - $EndIP" -ForegroundColor White
    Write-Host "M?scara:  $Mascara" -ForegroundColor White
    Write-Host "Gateway:  $Gateway" -ForegroundColor White
    Write-Host "DNS 1:    $DNS1" -ForegroundColor White
    if ($DNS2) { Write-Host "DNS 2:    $DNS2" -ForegroundColor White }
    
    $confirmar = Read-Host "`n?Confirma la configuraci?n? (S/N)"
    if ($confirmar -notmatch "^(s|S)$") {
        Write-Host "`n[CANCELADO]" -ForegroundColor Yellow
        Pause
        return
    }
    
    # APLICAR CONFIGURACI?N
    Write-Host "`nAplicando configuraci?n..." -ForegroundColor Cyan
    
    try {
        # Calcular ScopeID
        $segmentos = $StartIP.Split(".")
        $ScopeID = "$($segmentos[0]).$($segmentos[1]).$($segmentos[2]).0"
        
        # Eliminar ?mbito existente si existe
        if (Get-DhcpServerv4Scope -ScopeId $ScopeID -ErrorAction SilentlyContinue) {
            Remove-DhcpServerv4Scope -ScopeId $ScopeID -Force -ErrorAction SilentlyContinue
        }
        
        # Crear ?mbito
        Add-DhcpServerv4Scope -Name $NombreScope -StartRange $StartIP -EndRange $EndIP -SubnetMask $Mascara -State Active -ErrorAction Stop
        
        # Configurar gateway
        Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 3 -Value $Gateway -ErrorAction Stop
        
        # Configurar DNS
        if ($DNS2) {
            Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 6 -Value $DNS1, $DNS2 -ErrorAction Stop
        } else {
            Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 6 -Value $DNS1 -ErrorAction Stop
        }
        
        # Reiniciar servicio
        Restart-Service DHCPServer -ErrorAction Stop
        
        Write-Host "`n" -ForegroundColor Green
        Write-Host "    DHCP CONFIGURADO CORRECTAMENTE     " -ForegroundColor Green
        Write-Host "" -ForegroundColor Green
        
        Write-Host "`nEn el cliente, ejecute:" -ForegroundColor Cyan
        Write-Host "  ipconfig /release" -ForegroundColor White
        Write-Host "  ipconfig /renew" -ForegroundColor White
        
    } catch {
        Write-Host "`n[ERROR] No se pudo aplicar la configuraci?n: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "`nPresione cualquier tecla para volver al men?..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# --- [3] MONITOREAR IPs ASIGNADAS ---
function Opcion3-MonitorearIPs {
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "   [3] MONITOREAR IPs ASIGNADAS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Verificar que DHCP est? instalado
    $rol = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    if (-not $rol -or -not $rol.Installed) {
        Write-Host "`n[ERROR] DHCP no est? instalado." -ForegroundColor Red
        Write-Host "Use la Opci?n [2] para instalarlo." -ForegroundColor Yellow
        Pause
        return
    }
    
    # Cargar m?dulo
    try {
        Import-Module DHCPServer -ErrorAction Stop
    } catch {
        Write-Host "`n[ERROR] No se pudo cargar el m?dulo DHCP." -ForegroundColor Red
        Pause
        return
    }
    
    # Obtener ?mbitos
    Write-Host "`nObteniendo informaci?n de ?mbitos..." -ForegroundColor Gray
    
    try {
        $scopes = Get-DhcpServerv4Scope -ErrorAction Stop
    } catch {
        Write-Host "`n[ERROR] No se pudieron obtener los ?mbitos." -ForegroundColor Red
        Write-Host "El servicio DHCP puede no estar iniciado." -ForegroundColor Yellow
        Pause
        return
    }
    
    if (-not $scopes) {
        Write-Host "`n[INFO] No hay ?mbitos configurados." -ForegroundColor Yellow
        Write-Host "Configure un ?mbito usando la Opci?n [2]." -ForegroundColor Gray
        Pause
        return
    }
    
    # Mostrar IPs asignadas de cada ?mbito
    foreach ($scope in $scopes) {
        Write-Host "`n--- ?mbito: $($scope.Name) [$($scope.ScopeId)] ---" -ForegroundColor Cyan
        Write-Host "Rango: $($scope.StartRange) - $($scope.EndRange)" -ForegroundColor Gray
        
        # Obtener concesiones
        $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
        
        if ($leases) {
            Write-Host "`nIPs ASIGNADAS:" -ForegroundColor Green
            Write-Host ""
            
            $leases | Select-Object `
                @{Name="Direcci?n IP";Expression={$_.IPAddress}},
                @{Name="Nombre de Host";Expression={if($_.HostName){$_.HostName}else{"(sin nombre)"}}},
                @{Name="Direcci?n MAC";Expression={$_.ClientId}},
                @{Name="Expira";Expression={$_.LeaseExpiryTime}} | 
                Format-Table -AutoSize
            
            Write-Host "Total de IPs asignadas: $($leases.Count)" -ForegroundColor Green
            
        } else {
            Write-Host "`n[INFO] No hay IPs asignadas en este ?mbito." -ForegroundColor Yellow
            Write-Host "Los clientes a?n no han solicitado direcciones IP." -ForegroundColor Gray
        }
    }
    
    Write-Host "`nPresione cualquier tecla para volver al men?..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# --- [4] RESTAURAR (DESINSTALAR TODO) ---
function Opcion4-Restaurar {
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "   [4] RESTAURAR (DESINSTALAR)" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    
    # Verificar si DHCP est? instalado
    $rol = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if (-not $rol -or -not $rol.Installed) {
        Write-Host "`n[INFO] DHCP no est? instalado." -ForegroundColor Yellow
        Write-Host "No hay nada que desinstalar." -ForegroundColor Gray
        Pause
        return
    }
    
    Write-Host "`n?ADVERTENCIA!" -ForegroundColor Yellow
    Write-Host "Esta acci?n:" -ForegroundColor White
    Write-Host "- Eliminar? TODOS los ?mbitos configurados" -ForegroundColor White
    Write-Host "- Desinstalar? completamente el rol DHCP" -ForegroundColor White
    Write-Host "- Los clientes perder?n la asignaci?n de IP" -ForegroundColor White
    
    $confirmar = Read-Host "`n?Est? SEGURO de que desea continuar? (S/N)"
    
    if ($confirmar -notmatch "^(s|S)$") {
        Write-Host "`n[CANCELADO]" -ForegroundColor Yellow
        Pause
        return
    }
    
    # Confirmaci?n adicional
    $confirmar2 = Read-Host "`nEscriba 'CONFIRMAR' para proceder"
    
    if ($confirmar2 -ne "CONFIRMAR") {
        Write-Host "`n[CANCELADO]" -ForegroundColor Yellow
        Pause
        return
    }
    
    Write-Host "`nDesinstalando DHCP..." -ForegroundColor Red
    
    try {
        # Cargar m?dulo si es posible
        Import-Module DHCPServer -ErrorAction SilentlyContinue
        
        # Eliminar ?mbitos
        Write-Host "1. Eliminando ?mbitos..." -ForegroundColor Gray
        try {
            $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
            if ($scopes) {
                foreach ($scope in $scopes) {
                    Write-Host "   - Eliminando: $($scope.Name)" -ForegroundColor Yellow
                    Remove-DhcpServerv4Scope -ScopeId $scope.ScopeId -Force -ErrorAction SilentlyContinue
                }
                Write-Host "    ?mbitos eliminados" -ForegroundColor Green
            } else {
                Write-Host "   - No hay ?mbitos configurados" -ForegroundColor Gray
            }
        } catch {
            Write-Host "   - No se pudieron eliminar ?mbitos" -ForegroundColor Gray
        }
        
        # Detener servicio
        Write-Host "2. Deteniendo servicio..." -ForegroundColor Gray
        try {
            Stop-Service DHCPServer -Force -ErrorAction SilentlyContinue
            Write-Host "    Servicio detenido" -ForegroundColor Green
        } catch {
            Write-Host "   - Servicio ya detenido" -ForegroundColor Gray
        }
        
        # Desinstalar rol
        Write-Host "3. Desinstalando rol DHCP..." -ForegroundColor Gray
        Uninstall-WindowsFeature DHCP -Remove -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Host "    Rol desinstalado" -ForegroundColor Green
        
        Write-Host "`n" -ForegroundColor Green
        Write-Host "    DHCP DESINSTALADO COMPLETAMENTE    " -ForegroundColor Green
        Write-Host "" -ForegroundColor Green
        
        Write-Host "`nEl sistema ha sido restaurado a su estado inicial." -ForegroundColor White
        
    } catch {
        Write-Host "`n[ERROR] Fallo durante la desinstalaci?n: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "`nPresione cualquier tecla para volver al men?..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# --- MEN? PRINCIPAL ---
Do {
    Clear-Host
    Write-Host "===   MENU   ===" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "[1] Verificar instalacion DHCP" -ForegroundColor White
    Write-Host "[2] Instalacion (Silenciosa)" -ForegroundColor White
    Write-Host "[3] Monitorear" -ForegroundColor White
    Write-Host "[4] Restaurar" -ForegroundColor White
    Write-Host "[5] Salir" -ForegroundColor White
    Write-Host ""
    
    $opcion = Read-Host "Seleccione una opci?n"
    
    Switch ($opcion) {
        "1" { Opcion1-VerificarDHCP }
        "2" { Opcion2-InstalarDHCP }
        "3" { Opcion3-MonitorearIPs }
        "4" { Opcion4-Restaurar }
        "5" { 
            Write-Host "`nSaliendo del script..." -ForegroundColor Cyan
            Start-Sleep -Seconds 1
            Break 
        }
        Default { 
            Write-Host "`n[ERROR] Opci?n inv?lida. Seleccione 1-5." -ForegroundColor Red
            Start-Sleep -Seconds 2
        }
    }
    
} While ($opcion -ne "5")
'@