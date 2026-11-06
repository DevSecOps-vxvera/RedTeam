
<#
.SYNOPSIS
    Sube un archivo directamente a GitHub.
    Sin validacion de contenido o formato.
#>

[CmdletBinding()]
param(
    [string]$FilePath = ".\keys.csv",
    [SecureString]$GitHubToken
)

$ErrorActionPreference = "Stop"

# Configuracion del repositorio
$Owner  = "DevSecOps-vxvera"
$Repo   = "RedTeam"
$Branch = "main"
$Folder = "evidencias"

try {
    # 1. Verificar existencia del archivo
    $File = Get-Item -LiteralPath $FilePath -ErrorAction Stop

    if ($File.PSIsContainer) {
        throw "La ruta indicada no corresponde a un archivo."
    }

    Write-Host "[OK] Archivo encontrado: $($File.FullName)" -ForegroundColor Green

    # 2. Solicitar GitHub PAT
    if (-not $GitHubToken) {
        $GitHubToken = Read-Host "Ingrese GitHub PAT" -AsSecureString
    }

    $PAT = [System.Net.NetworkCredential]::new(
        "",
        $GitHubToken
    ).Password

    if ([string]::IsNullOrWhiteSpace($PAT)) {
        throw "El token esta vacio."
    }

    # 3. Crear nombre unico de evidencia
    $Timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $UniqueId = [guid]::NewGuid().ToString("N").Substring(0,8)

    $RemoteName = "$($File.BaseName)-$Timestamp-$UniqueId$($File.Extension)"
    $RemotePath = "$Folder/$RemoteName"

    $EncodedName = [uri]::EscapeDataString($RemoteName)

    $ApiUrl = "https://api.github.com/repos/$Owner/$Repo/contents/$Folder/$EncodedName"

    # 4. Leer archivo original sin modificar contenido
    $Bytes = [System.IO.File]::ReadAllBytes($File.FullName)
    $ContentBase64 = [Convert]::ToBase64String($Bytes)

    # 5. Preparar solicitud GitHub
    $Headers = @{
        Authorization = "Bearer $PAT"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $Body = @{
        message = "Upload evidencia DevSecOps $Timestamp"
        content = $ContentBase64
        branch = $Branch
    } | ConvertTo-Json -Compress

    # 6. Subir archivo
    Write-Host "[INFO] Subiendo evidencia a GitHub..." -ForegroundColor Cyan

    $Response = Invoke-RestMethod `
        -Uri $ApiUrl `
        -Method Put `
        -Headers $Headers `
        -ContentType "application/json" `
        -Body $Body `
        -ErrorAction Stop

    Write-Host ""
    Write-Host "[OK] ARCHIVO PUBLICADO" -ForegroundColor Green
    Write-Host "Repositorio: $Owner/$Repo"
    Write-Host "Archivo: $RemotePath"
    Write-Host "URL: $($Response.content.html_url)"
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    $PAT = $null
    $Headers = $null
}
