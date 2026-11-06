
<#
.SYNOPSIS
    Ejecuta scan.ps1 y sube keys.csv a GitHub.

.DESCRIPTION
    - Audita nombres de credenciales DevOps.
    - Genera keys.csv.
    - Valida que contenga solo nombres de variables.
    - Solicita GitHub PAT de forma segura.
    - Publica evidencia en DevSecOps-vxvera/RedTeam.
    - No envia valores de credenciales.

.EXAMPLE
    .\upload-evidence.ps1 -AllUsers

.EXAMPLE
    .\upload-evidence.ps1 -UploadOnly -CsvPath "C:\Auditoria\keys.csv"
#>

[CmdletBinding()]
param(
    [string]$ScanPath = (Join-Path $PSScriptRoot "scan.ps1"),
    [string]$CsvPath = (Join-Path $env:TEMP "keys.csv"),
    [switch]$AllUsers,
    [switch]$UploadOnly,
    [SecureString]$GitHubToken
)

$ErrorActionPreference = "Stop"

$Owner  = "DevSecOps-vxvera"
$Repo   = "RedTeam"
$Branch = "main"

# 1. Validar sistema operativo
if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
    throw "Esta version de la auditoria requiere Windows."
}

# 2. Ejecutar auditoria, salvo que ya exista la evidencia
if (-not $UploadOnly) {

    if (-not (Test-Path -LiteralPath $ScanPath -PathType Leaf)) {
        throw "No se encontro scan.ps1 en: $ScanPath"
    }

    Write-Host "[1/4] Ejecutando auditoria DevSecOps..."

    $Folder = Split-Path -Parent $CsvPath

    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force |
            Out-Null
    }

    # Eliminar evidencia anterior para no subir datos obsoletos
    if (Test-Path -LiteralPath $CsvPath) {
        Remove-Item -LiteralPath $CsvPath -Force
    }

    & $ScanPath -AllUsers:$AllUsers -CsvPath $CsvPath
}

# 3. Validar evidencia
Write-Host "[2/4] Validando nombres de claves..."

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    throw "La auditoria no genero el archivo CSV esperado."
}

$FileInfo = Get-Item -LiteralPath $CsvPath

if ($FileInfo.Length -gt 1MB) {
    throw "El CSV supera el limite de seguridad de 1 MB."
}

$FirstLine = Get-Content -LiteralPath $CsvPath -TotalCount 1

if (-not $FirstLine) {
    throw "El CSV esta vacio. No se publicara evidencia."
}

$Header = $FirstLine.Trim().Trim([char]0xFEFF).Trim('"')

if ($Header -ne "NombreKey") {
    throw "El CSV debe contener exclusivamente la columna NombreKey."
}

$Rows = @(Import-Csv -LiteralPath $CsvPath)

$Names = @()

foreach ($Row in $Rows) {

    if (@($Row.PSObject.Properties).Count -ne 1) {
        throw "Se detectaron columnas inesperadas. Carga cancelada."
    }

    $Name = ([string]$Row.NombreKey).Trim()

    # Admitir solo nombres de variables o identificadores.
    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_.-]{0,127}$') {
        throw "Se detecto una entrada incompatible con un nombre de clave."
    }

    # Rechazar prefijos habituales de tokens reales
    if ($Name -match '^(gh[pousr]_|github_pat_|AKIA[A-Z0-9]{16}$|ASIA[A-Z0-9]{16}$)') {
        throw "Posible valor secreto identificado. Carga cancelada."
    }

    $Names += $Name
}

$Names = @($Names | Sort-Object -Unique)

# Reconstruir CSV seguro, sin otras columnas
$CsvLines = @('"NombreKey"')

foreach ($Name in $Names) {
    $CsvLines += '"' + $Name + '"'
}

$SafeCsv = ($CsvLines -join "`r`n") + "`r`n"

Write-Host "Nombres validados: $($Names.Count)"

# 4. Obtener token
Write-Host "[3/4] Autenticacion con GitHub..."

if (-not $GitHubToken) {
    $GitHubToken = Read-Host "Ingrese GitHub PAT" -AsSecureString
}

$PAT = [System.Net.NetworkCredential]::new(
    "",
    $GitHubToken
).Password

if ([string]::IsNullOrWhiteSpace($PAT)) {
    throw "El token no puede estar vacio."
}

# 5. Crear identificador unico de evidencia
$Timestamp = (Get-Date).ToUniversalTime().ToString(
    "yyyyMMddTHHmmssZ"
)

$UniqueId = (New-Guid).ToString("N").Substring(0, 8)

$RemotePath = "evidencias/keys-$Timestamp-$UniqueId.csv"

$ApiUrl = "https://api.github.com/repos/$Owner/$Repo/contents/$RemotePath"

# 6. Preparar contenido de la API
$EncodedContent = [Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes($SafeCsv)
)

$Body = @{
    message = "Evidencia auditoria DevSecOps $Timestamp"
    content = $EncodedContent
    branch  = $Branch
} | ConvertTo-Json -Compress

$Headers = @{
    Authorization          = "Bearer $PAT"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# 7. Publicar evidencia
Write-Host "[4/4] Publicando evidencia..."

try {

    $Response = Invoke-RestMethod `
        -Uri $ApiUrl `
        -Method Put `
        -Headers $Headers `
        -ContentType "application/json" `
        -Body $Body `
        -ErrorAction Stop

    Write-Host ""
    Write-Host "EVIDENCIA PUBLICADA CORRECTAMENTE" -ForegroundColor Green
    Write-Host "Repositorio: $Owner/$Repo"
    Write-Host "Archivo: $RemotePath"
    Write-Host "Total de nombres: $($Names.Count)"
    Write-Host "URL: $($Response.content.html_url)"
}
catch {
    Write-Host "ERROR: no se pudo publicar la evidencia." -ForegroundColor Red
    Write-Host "Verifique permisos Contents (write), PAT y rama main."
    throw "La API de GitHub rechazo la publicacion."
}
finally {
    $PAT = $null
    $Headers = $null
    $GitHubToken.Dispose()
}
