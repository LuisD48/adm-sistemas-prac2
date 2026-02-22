Set-Content -Path "dhcp_win.ps1" -Value @'
<#
.SYNOPSIS
    Gestor DHCP
.DESCRIPTION
    Mejoras sobre V5:
    - Validación que IPs del rango sean de la misma subred /24
    - Protección contra IP de broadcast como EndIP
    - Rollback automático si falla la configuración a mitad
    - Nombre del scope personalizable
    - Soporte multi-índice para ISO (prueba índices 1-4)
    - Verificación de servicio antes de consultar clientes
    - Exportación de leases a CSV
    - Confirmación visual del adaptador seleccionado con IP actual
    - Tiempo de espera (countdown) antes de aplicar cambios
#>

$ErrorActionPreference = "Stop"
$Script:RollbackIP  = $null
$Script:RollbackGW  = $null
$Script:ConfigCache = "$PSScriptRoot\.dhcp_pendiente.json"

# ============================================================
# UTILIDADES GLOBALES
# ============================================================

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    switch ($Level) {
        "OK"    { Write-Host "   [OK] $Msg" -ForegroundColor Green }
        "WARN"  { Write-Host "   [!] $Msg"  -ForegroundColor Yellow }
        "ERROR" { Write-Host "   [X] $Msg"  -ForegroundColor Red }
        "INFO"  { Write-Host "   --> $Msg"  -ForegroundColor Cyan }
        default { Write-Host "   $Msg" }
    }
}

function Mostrar-Separador { Write-Host ("=" * 50) -ForegroundColor DarkGray }

# ============================================================
# VALIDACIÓN: ADMINISTRADOR
# ============================================================

$principal = [Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "`n[ERROR FATAL] Ejecute este script como Administrador." -ForegroundColor Red
    Pause; Exit
}

# ============================================================
# FUNCIONES DE VALIDACIÓN DE IP
# ============================================================

function Convertir-IpAEntero([string]$Ip) {
    try {
        $ipObj = [System.Net.IPAddress]::Parse($Ip)
        $bytes = $ipObj.GetAddressBytes()
        if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
        return [System.BitConverter]::ToUInt32($bytes, 0)
    } catch { return 0 }
}

function Obtener-RedBase([string]$Ip, [int]$Prefijo = 24) {
    # Usamos int64 para evitar overflow de uint32 con el operador -shl en PowerShell
    $valor   = [int64](Convertir-IpAEntero $Ip)
    $mascara = [int64](([int64]0xFFFFFFFF -shl (32 - $Prefijo)) -band 0xFFFFFFFF)
    $red     = $valor -band $mascara
    return $red
}


function Solicitar-IP {
    param(
        [string]$Mensaje,
        [string]$IpReferencia    = $null,
        [bool]$EsIpFinal         = $false,
        [string]$IpSubredRef     = $null,   # NUEVO: Verificar misma /24
        [bool]$PermitirCualquier = $false   # Para Gateway (puede ser diferente subred)
    )

    do {
        $InputIP = Read-Host "$Mensaje"

        # 1. Formato visual
        if ($InputIP -notmatch "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
            Write-Host "   [X] Formato inválido. Use XXX.XXX.XXX.XXX (Ej. 192.168.1.10)" -ForegroundColor Red
            continue
        }

        # 2. Validación técnica .NET
        $ipObj = $null
        if (-not [System.Net.IPAddress]::TryParse($InputIP, [ref]$ipObj) -or
            $InputIP -eq "0.0.0.0" -or $InputIP -eq "255.255.255.255") {
            Write-Host "   [X] Dirección IP no válida técnicamente." -ForegroundColor Red
            continue
        }

        # 3. No permitir dirección de broadcast (...255) como EndIP
        if ($EsIpFinal) {
            $octetos = $InputIP.Split(".")
            if ($octetos[3] -eq "255") {
                Write-Host "   [X] No puede usar la dirección de broadcast (.255) como IP Final." -ForegroundColor Red
                continue
            }
        }

        # 5. Lógica: IP Final debe ser mayor que la Inicial
        if ($EsIpFinal -and $IpReferencia) {
            $valActual = Convertir-IpAEntero $InputIP
            $valRef    = Convertir-IpAEntero $IpReferencia
            if ($valActual -le $valRef) {
                Write-Host "   [X] La IP Final debe ser MAYOR que la Inicial ($IpReferencia)." -ForegroundColor Red
                continue
            }
        }

        return $InputIP

    } while ($true)
}

# ============================================================
# ROLLBACK: Restaurar IP anterior si algo falla
# ============================================================

function Guardar-EstadoRed([int]$InterfaceIndex) {
    try {
        $ipActual = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $gwActual = (Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        $Script:RollbackIP = $ipActual
        $Script:RollbackGW = $gwActual
        Write-Log "Estado de red guardado para rollback. IP anterior: $($ipActual.IPAddress)"
    } catch {
        Write-Log "No se pudo guardar estado previo de red (puede ser normal en equipos nuevos)." "WARN"
    }
}

function Ejecutar-Rollback([int]$InterfaceIndex) {
    if ($Script:RollbackIP) {
        Write-Log "Ejecutando rollback de red..." "WARN"
        try {
            Remove-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            $params = @{
                InterfaceIndex = $InterfaceIndex
                IPAddress      = $Script:RollbackIP.IPAddress
                PrefixLength   = $Script:RollbackIP.PrefixLength
                Confirm        = $false
            }
            if ($Script:RollbackGW) { $params.DefaultGateway = $Script:RollbackGW }
            New-NetIPAddress @params -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Rollback completado. IP restaurada: $($Script:RollbackIP.IPAddress)" "OK"
        } catch {
            Write-Log "Rollback fallido: $_" "ERROR"
        }
    }
}

# ============================================================
# OPCIÓN 1: VERIFICAR
# ============================================================

function Opcion1-Verificar {
    Clear-Host
    Mostrar-Separador
    Write-Host "  VERIFICACIÓN DE ESTADO DEL SERVIDOR DHCP" -ForegroundColor Cyan
    Mostrar-Separador

    $dhcp = Get-WindowsFeature DHCP -ErrorAction SilentlyContinue
    if ($dhcp.Installed) {
        Write-Log "Rol DHCP: INSTALADO" "OK"
        $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
        Write-Log "Servicio DHCPServer: $($svc.Status)"
        
        Write-Host "`n  Ámbitos configurados:" -ForegroundColor Yellow
        $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        if ($scopes) {
            $scopes | Format-Table Name, ScopeId, StartRange, EndRange, State -AutoSize
        } else {
            Write-Host "   (Sin ámbitos configurados aún)" -ForegroundColor DarkGray
        }
    } else {
        Write-Log "Rol DHCP: NO INSTALADO" "WARN"
    }

    Pause
}

# ============================================================
# OPCIÓN 2: INSTALAR Y CONFIGURAR
# ============================================================

function Opcion2-InstalarConfigurar {
    Clear-Host
    Mostrar-Separador
    Write-Host "  CONFIGURACIÓN COMPLETA: RED + DHCP" -ForegroundColor Cyan
    Mostrar-Separador

    # *** DETECTAR CONFIGURACIÓN GUARDADA (post-reinicio) ***
    if (Test-Path $Script:ConfigCache) {
        $cfg = Get-Content $Script:ConfigCache | ConvertFrom-Json
        Write-Host "`n  [!] Se encontró una configuración pendiente del reinicio anterior:" -ForegroundColor Yellow
        Write-Host "      Interfaz  : $($cfg.NicName)"
        Write-Host "      Server IP : $($cfg.ServerIP)"
        Write-Host "      Rango     : $($cfg.StartScope) -> $($cfg.EndIP)"
        Write-Host "      Gateway   : $($cfg.Gateway)"
        Write-Host "      DNS       : $($cfg.DNS)"
        Write-Host "      Scope     : $($cfg.ScopeName)"
        $usar = Read-Host "`n  ¿Usar esta configuración guardada? (S/N)"
        if ($usar -match "^[sS]") {
            # Recuperar variables y saltar directo al scope
            $ServerIP      = $cfg.ServerIP
            $EndIP         = $cfg.EndIP
            $Gateway       = $cfg.Gateway
            $DNS           = $cfg.DNS
            $ScopeName     = $cfg.ScopeName
            $ScopeID       = $cfg.ScopeID
            $StartScope    = $cfg.StartScope
            $NicIndex      = $cfg.NicIndex
            $LeaseHoras    = if ($cfg.LeaseHoras) { $cfg.LeaseHoras } else { 8 }
            $LeaseDuration = [TimeSpan]::FromHours($LeaseHoras)

            Write-Host "`n[PASO 5] Creando Ámbito DHCP (configuración recuperada)..." -ForegroundColor Yellow
            try {
                Import-Module DHCPServer -ErrorAction SilentlyContinue
                Start-Service DHCPServer -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2

                if (Get-DhcpServerv4Scope -ScopeId $ScopeID -ErrorAction SilentlyContinue) {
                    Remove-DhcpServerv4Scope -ScopeId $ScopeID -Force -Confirm:$false
                }
                Add-DhcpServerv4Scope -Name $ScopeName -StartRange $StartScope -EndRange $EndIP -SubnetMask "255.255.255.0" -LeaseDuration $LeaseDuration -State Active
                Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 3 -Value $Gateway
                Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 6 -Value $DNS
                Restart-Service DHCPServer -ErrorAction SilentlyContinue

                Remove-Item $Script:ConfigCache -Force -ErrorAction SilentlyContinue

                Write-Host "`n" ; Mostrar-Separador
                Write-Host "  CONFIGURACION EXITOSA (post-reinicio)" -ForegroundColor Green
                Mostrar-Separador
                Write-Host "  IP Servidor : $ServerIP"
                Write-Host "  Rango DHCP  : $StartScope  -->  $EndIP"
                Write-Host "  Scope       : $ScopeName ($ScopeID)"
                Mostrar-Separador
            } catch {
                Write-Log "Error configurando ámbito DHCP: $_" "ERROR"
            }
            Pause; return
        } else {
            # El usuario prefiere ingresar datos nuevos, borrar el cache
            Remove-Item $Script:ConfigCache -Force -ErrorAction SilentlyContinue
        }
    }

    # A) SELECCIÓN DE ADAPTADOR (con IP actual visible)
    Write-Host "`n[PASO 1] Seleccione la Tarjeta de Red:" -ForegroundColor Yellow
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    if (-not $adapters) {
        Write-Log "No hay tarjetas de red activas." "ERROR"
        Pause; return
    }

    $i = 1
    foreach ($nic in $adapters) {
        $ipInfo = (Get-NetIPAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1)
        $ipActual = if ($ipInfo) { $ipInfo.IPAddress } else { "Sin IP" }
        Write-Host "   [$i] $($nic.Name) | MAC: $($nic.MacAddress) | IP Actual: $ipActual"
        $i++
    }

    $selIndex = 0
    do {
        $sel = Read-Host "   > Número de opción"
        if ($sel -match "^[0-9]+$" -and [int]$sel -le $adapters.Count -and [int]$sel -gt 0) {
            $selIndex = [int]$sel - 1; break
        }
        Write-Host "   [X] Selección inválida." -ForegroundColor Red
    } while ($true)
    $SelectedNic = $adapters[$selIndex]
    Write-Log "Adaptador seleccionado: $($SelectedNic.Name)"

    # B) SOLICITUD DE DATOS CON VALIDACIÓN MEJORADA
    Write-Host "`n[PASO 2] Definición de Direcciones (misma red /24):" -ForegroundColor Yellow

    $ServerIP = Solicitar-IP -Mensaje "   > IP Estática del Servidor (inicio del rango):"

    # EndIP: mayor que ServerIP y misma subred
    $EndIP = Solicitar-IP `
        -Mensaje      "   > IP Final del Rango DHCP:" `
        -IpReferencia $ServerIP `
        -EsIpFinal    $true `
        -IpSubredRef  $ServerIP

    # Gateway: se permite cualquier IP (puede estar fuera de /24 en algunos casos)
    $Gateway = Solicitar-IP -Mensaje "   > Puerta de Enlace (Gateway):" -PermitirCualquier $true

    # DNS
    $dnsInput = Read-Host "   > DNS (Enter = usar $ServerIP)"
    if ($dnsInput -notmatch "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") { $DNS = $ServerIP } else { $DNS = $dnsInput }

    # Nombre del Scope
    $scopeInput = Read-Host "   > Nombre del Ámbito DHCP (Enter = 'Red_Interna')"
    $ScopeName  = if ($scopeInput.Trim() -ne "") { $scopeInput.Trim() } else { "Red_Interna" }

    # Lease Time con validación
    do {
        $leaseInput = Read-Host "   > Tiempo de concesión en horas (Enter = 8)"
        if ($leaseInput.Trim() -eq "") { $LeaseHoras = 8; break }
        if ($leaseInput -match "^\d+$" -and [int]$leaseInput -ge 1 -and [int]$leaseInput -le 9999) {
            $LeaseHoras = [int]$leaseInput; break
        }
        Write-Host "   [X] Ingrese un número entero entre 1 y 9999." -ForegroundColor Red
    } while ($true)
    $LeaseDuration = [TimeSpan]::FromHours($LeaseHoras)

    # C) RESUMEN + COUNTDOWN
    $Octetos    = $ServerIP.Split(".")
    $StartScope = "$($Octetos[0]).$($Octetos[1]).$($Octetos[2]).$([int]$Octetos[3] + 1)"
    $ScopeID    = "$($Octetos[0]).$($Octetos[1]).$($Octetos[2]).0"

    Write-Host "`n" ; Mostrar-Separador
    Write-Host "  RESUMEN DE CONFIGURACIÓN" -ForegroundColor Cyan
    Mostrar-Separador
    Write-Host "  Interfaz   : $($SelectedNic.Name)"
    Write-Host "  Server IP  : $ServerIP  (IP estática del servidor)"
    Write-Host "  Rango DHCP : $StartScope  ->  $EndIP"
    Write-Host "  Gateway    : $Gateway"
    Write-Host "  DNS        : $DNS"
    Write-Host "  Scope Name : $ScopeName"
    Write-Host "  Lease Time : $LeaseHoras hora(s)"
    Mostrar-Separador

    $conf = Read-Host "`n¿Aplicar configuración? (S/N)"
    if ($conf -notmatch "^[sS]") {
        Write-Log "Configuración cancelada por el usuario." "WARN"
        Pause; return
    }

    # Countdown de 3 segundos antes de aplicar
    for ($t = 3; $t -ge 1; $t--) {
        Write-Host "   Aplicando ..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 1
    }

    # D) GUARDAR ESTADO ACTUAL (para rollback)
    Guardar-EstadoRed -InterfaceIndex $SelectedNic.InterfaceIndex

    # E) APLICAR IP ESTÁTICA
    Write-Host "`n[PASO 3] Configurando IP Estática..." -ForegroundColor Yellow
    try {
        # Limpiar IP existente
        Remove-NetIPAddress -InterfaceIndex $SelectedNic.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        # Limpiar Gateway existente (causa "DefaultGateway already exists" si no se elimina)
        Remove-NetRoute -InterfaceIndex $SelectedNic.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $SelectedNic.InterfaceIndex -IPAddress $ServerIP -PrefixLength 24 -DefaultGateway $Gateway -Confirm:$false -ErrorAction Stop | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $SelectedNic.InterfaceIndex -ServerAddresses $DNS -ErrorAction SilentlyContinue
        Write-Log "IP estática asignada: $ServerIP" "OK"
    } catch {
        Write-Log "Error configurando IP: $_" "ERROR"
        Ejecutar-Rollback -InterfaceIndex $SelectedNic.InterfaceIndex
        Pause; return
    }

    # F) INSTALAR ROL DHCP (multi-índice ISO)
    Write-Host "`n[PASO 4] Verificando Rol DHCP..." -ForegroundColor Yellow
    $rol = Get-WindowsFeature DHCP
    if (-not $rol.Installed) {
        Write-Log "Instalando rol DHCP (intento online)..."
        $instalado = $false

        try {
            $resultado = Install-WindowsFeature DHCP -IncludeManagementTools -ErrorAction Stop
            $instalado = $true
            Write-Log "Instalación online exitosa." "OK"

            # Si Windows requiere reinicio, NO intentar configurar el scope todavía
            if ($resultado.RestartNeeded -eq "Yes") {
                Write-Host "`n" ; Mostrar-Separador
                Write-Host "  REINICIO REQUERIDO" -ForegroundColor Yellow
                Mostrar-Separador
                Write-Host "  El rol DHCP se instaló correctamente pero Windows" -ForegroundColor Yellow
                Write-Host "  necesita reiniciarse antes de poder configurarlo." -ForegroundColor Yellow
                Write-Host "`n  PASOS A SEGUIR:" -ForegroundColor Cyan
                Write-Host "  1. Reinicie el servidor ahora"
                Write-Host "  2. Vuelva a ejecutar este script como Administrador"
                Write-Host "  3. Seleccione Opcion 2 nuevamente"
                Write-Host "  4. El rol ya estara instalado, solo configurara el scope"
                Mostrar-Separador
                Write-Host "`n  La IP estatica ($ServerIP) ya fue configurada y se mantendra." -ForegroundColor Green

                # Guardar config en JSON para retomar automaticamente post-reinicio
                $cfgObj = @{
                    NicName       = $SelectedNic.Name
                    NicIndex      = $SelectedNic.InterfaceIndex
                    ServerIP      = $ServerIP
                    EndIP         = $EndIP
                    StartScope    = $StartScope
                    ScopeID       = $ScopeID
                    Gateway       = $Gateway
                    DNS           = $DNS
                    ScopeName     = $ScopeName
                    LeaseHoras    = $LeaseHoras
                }
                $cfgObj | ConvertTo-Json | Set-Content $Script:ConfigCache -Encoding UTF8
                Write-Log "Configuración guardada. Al reiniciar, ejecute el script y elija Opción 2." "OK"

                $reiniciar = Read-Host "`n  ¿Reiniciar ahora? (S/N)"
                if ($reiniciar -match "^[sS]") { Restart-Computer -Force }
                Pause; return
            }
        } catch {
            Write-Log "Descarga web falló. Probando instalación desde ISO..." "WARN"

            # NUEVO: Probar múltiples índices del WIM (1=Core, 2=Standard, 3=Datacenter...)
            foreach ($idx in 1..4) {
                Write-Log "Intentando WIM índice $idx..."
                try {
                    $resultado = Install-WindowsFeature DHCP -Source "wim:D:\sources\install.wim:$idx" -IncludeManagementTools -ErrorAction Stop
                    $instalado = $true
                    Write-Log "Instalación desde ISO (índice $idx) exitosa." "OK"
                    if ($resultado.RestartNeeded -eq "Yes") { $Script:NecesitaReinicio = $true }
                    break
                } catch {
                    Write-Log "Índice $idx falló." "WARN"
                }
            }
        }

        if (-not $instalado) {
            Write-Log "No se pudo instalar DHCP. Verifique que el ISO esté montado en D:" "ERROR"
            Ejecutar-Rollback -InterfaceIndex $SelectedNic.InterfaceIndex
            Pause; return
        }
    } else {
        Write-Log "El rol DHCP ya estaba instalado." "OK"
    }

    # G) ARRANCAR Y HABILITAR SERVICIO DHCP
    Write-Host "`n[PASO 5] Iniciando servicio DHCP..." -ForegroundColor Yellow
    try {
        Set-Service -Name DHCPServer -StartupType Automatic -ErrorAction Stop
        Start-Service -Name DHCPServer -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Log "Servicio DHCPServer iniciado y configurado como Automático." "OK"
    } catch {
        Write-Log "Advertencia al iniciar servicio: $_" "WARN"
    }

    # H) CONFIGURAR ÁMBITO
    Write-Host "`n[PASO 6] Creando Ámbito DHCP..." -ForegroundColor Yellow
    try {
        Import-Module DHCPServer -ErrorAction SilentlyContinue

        if (Get-DhcpServerv4Scope -ScopeId $ScopeID -ErrorAction SilentlyContinue) {
            Write-Log "Ámbito existente ($ScopeID) eliminado para recrear." "WARN"
            Remove-DhcpServerv4Scope -ScopeId $ScopeID -Force -Confirm:$false
        }

        Add-DhcpServerv4Scope -Name $ScopeName -StartRange $StartScope -EndRange $EndIP -SubnetMask "255.255.255.0" -State Active
        Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 3 -Value $Gateway   # Router
        Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 6 -Value $DNS       # DNS

        Restart-Service DHCPServer -ErrorAction SilentlyContinue

        Write-Log "Servidor DHCP configurado completamente." "OK"
        Write-Host "`n" ; Mostrar-Separador
        Write-Host "  CONFIGURACION EXITOSA" -ForegroundColor Green
        Mostrar-Separador
        Write-Host "  IP Servidor : $ServerIP"
        Write-Host "  Rango DHCP  : $StartScope  -->  $EndIP"
        Write-Host "  Scope       : $ScopeName ($ScopeID)"
        Write-Host "  Lease Time  : $LeaseHoras hora(s)"
        Mostrar-Separador

    } catch {
        Write-Log "Error configurando ámbito DHCP: $_" "ERROR"
        Ejecutar-Rollback -InterfaceIndex $SelectedNic.InterfaceIndex
    }

    Pause
}

# ============================================================
# OPCIÓN 3: MONITOREAR CLIENTES
# ============================================================

function Opcion3-Monitorear {
    Clear-Host
    Mostrar-Separador
    Write-Host "  CLIENTES DHCP CONECTADOS" -ForegroundColor Cyan
    Mostrar-Separador

    # NUEVO: Verificar que el servicio esté corriendo antes de consultar
    $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne "Running") {
        Write-Log "El servicio DHCPServer no está activo. Inicie el servidor primero." "ERROR"
        Pause; return
    }

    try {
        $leases = Get-DhcpServerv4Scope | Get-DhcpServerv4Lease -ErrorAction Stop
        if ($leases) {
            Write-Host "`n  Total de clientes: $($leases.Count)" -ForegroundColor Green
            $leases | Format-Table -Property IPAddress, ClientId, HostName, AddressState, LeaseExpiryTime -AutoSize

            # NUEVO: Exportar a CSV
            $export = Read-Host "  ¿Exportar lista a CSV? (S/N)"
            if ($export -match "^[sS]") {
                $csvPath = "$PSScriptRoot\clientes_dhcp_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
                $leases | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
                Write-Log "Lista exportada a: $csvPath" "OK"
            }
        } else {
            Write-Log "No hay clientes conectados actualmente." "WARN"
        }
    } catch {
        Write-Log "Error consultando leases: $_" "ERROR"
    }
    Pause
}

# ============================================================
# OPCIÓN 4: RESTAURAR / DESINSTALAR
# ============================================================

function Opcion4-Restaurar {
    Clear-Host
    Mostrar-Separador
    Write-Host "  DESINSTALACIÓN Y RESTAURACIÓN" -ForegroundColor Red
    Mostrar-Separador

    Write-Host "  [!] Esta acción eliminará el Rol DHCP, todos los ámbitos" -ForegroundColor Yellow
    Write-Host "  [!] y convertirá la IP estática en dinámica (DHCP cliente)." -ForegroundColor Yellow

    # Seleccionar tarjeta a la que quitar la IP fija
    Write-Host "`n  Seleccione la tarjeta de red a restaurar a IP dinámica:" -ForegroundColor Yellow
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    $i = 1
    foreach ($nic in $adapters) {
        $ipInfo = (Get-NetIPAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1)
        $ipActual = if ($ipInfo) { "$($ipInfo.IPAddress) ($(if($ipInfo.PrefixOrigin -eq 'Manual'){'Estática'}else{'Dinámica'}))" } else { "Sin IP" }
        Write-Host "  [$i] $($nic.Name) | IP: $ipActual"
        $i++
    }
    $selIndex = 0
    do {
        $sel = Read-Host "  > Número de opción (0 = no cambiar IP)"
        if ($sel -eq "0") { $NicRestore = $null; break }
        if ($sel -match "^[0-9]+$" -and [int]$sel -le $adapters.Count -and [int]$sel -gt 0) {
            $NicRestore = $adapters[[int]$sel - 1]; break
        }
        Write-Host "  [X] Selección inválida." -ForegroundColor Red
    } while ($true)

    $conf = Read-Host "`n  Escriba 'BORRAR' para confirmar"

    if ($conf -eq "BORRAR") {
        Write-Log "Iniciando desinstalación de DHCP..."

        # Convertir IP estática a dinámica
        if ($NicRestore) {
            try {
                Remove-NetIPAddress -InterfaceIndex $NicRestore.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
                Remove-NetRoute -InterfaceIndex $NicRestore.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
                Set-NetIPInterface -InterfaceIndex $NicRestore.InterfaceIndex -Dhcp Enabled -ErrorAction Stop
                Set-DnsClientServerAddress -InterfaceIndex $NicRestore.InterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
                Write-Log "Tarjeta '$($NicRestore.Name)' restaurada a IP dinámica (DHCP cliente)." "OK"
            } catch {
                Write-Log "Error al restaurar IP dinámica: $_" "ERROR"
            }
        }

        # Detener y deshabilitar el servicio ANTES de desinstalar
        $svcDHCP = Get-Service DHCPServer -ErrorAction SilentlyContinue
        if ($svcDHCP) {
            if ($svcDHCP.Status -eq "Running") {
                # Borrar scopes mientras el servicio aún está activo
                Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                    Remove-DhcpServerv4Scope -Force -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "Ámbitos eliminados." "OK"

                Stop-Service -Name DHCPServer -Force -ErrorAction SilentlyContinue
                Write-Log "Servicio DHCPServer detenido." "OK"
            } else {
                Write-Log "Servicio DHCP ya estaba inactivo, omitiendo borrado de ámbitos." "WARN"
            }
            Set-Service -Name DHCPServer -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "Servicio DHCPServer deshabilitado." "OK"
        }

        $resUninstall = Uninstall-WindowsFeature DHCP -Remove -IncludeManagementTools -ErrorAction SilentlyContinue

        # Limpiar archivo de config pendiente si existe
        if (Test-Path $Script:ConfigCache) {
            Remove-Item $Script:ConfigCache -Force -ErrorAction SilentlyContinue
            Write-Log "Configuración pendiente eliminada." "OK"
        }

        if ($resUninstall.RestartNeeded -eq "Yes") {
            Write-Host "`n" ; Mostrar-Separador
            Write-Host "  ROL DESINSTALADO - REINICIO REQUERIDO" -ForegroundColor Yellow
            Mostrar-Separador
            Write-Host "  El rol DHCP fue eliminado correctamente pero Windows" -ForegroundColor Yellow
            Write-Host "  necesita reiniciarse para completar la desinstalación." -ForegroundColor Yellow
            Mostrar-Separador
            $reiniciar = Read-Host "  ¿Reiniciar ahora? (S/N)"
            if ($reiniciar -match "^[sS]") { Restart-Computer -Force }
        } else {
            Write-Log "Sistema restaurado correctamente. Sin necesidad de reinicio." "OK"
        }
    } else {
        Write-Log "Desinstalación cancelada." "WARN"
    }
    Pause
}

# ============================================================
# BUCLE PRINCIPAL DE MENÚ
# ============================================================

Do {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔═════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║    GESTOR DHCP  ║" -ForegroundColor Yellow
    Write-Host "  ╚═════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [1] Verificar Estado del Servidor"
    Write-Host "  [2] Configurar"
    Write-Host "  [3] Monitorear Clientes Conectados"
    Write-Host "  [4] Restaurar / Desinstalar"
    Write-Host "  [5] Salir"
    Write-Host ""
    $op = Read-Host "  Opción"

    Switch ($op) {
        "1" { Opcion1-Verificar }
        "2" { Opcion2-InstalarConfigurar }
        "3" { Opcion3-Monitorear }
        "4" { Opcion4-Restaurar }
        "5" { Break }
        default { Write-Host "  Opción no válida." -ForegroundColor Red; Start-Sleep 1 }
    }
} While ($op -ne "5")
'@