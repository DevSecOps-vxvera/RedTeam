
<#
.SYNOPSIS
  Descarga un repositorio Azure DevOps y genera
  un ZIP en Descargas del equipo Windows.

.DESCRIPTION
  - Usa Git Credential Manager.
  - Acepta URLs con usuario@dev.azure.com.
  - No solicita ni muestra tokens.
  - Descarga solo la rama seleccionada.
  - Genera un ZIP local sin .git.
  - No realiza push ni modifica Azure DevOps.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repositorio,

    [string]$Rama,

    [string]$Destino = (Join-Path $env:USERPROFILE "Downloads")
)

$ErrorActionPreference = "Stop"

# ==========================================
# 1. VALIDAR SISTEMA Y GIT
# ==========================================

if ($env:OS -ne "Windows_NT") {
    throw "Este script requiere Windows."
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git for Windows no esta instalado."
}

# ==========================================
# 2. VALIDAR Y NORMALIZAR URL
# ==========================================

$ParsedUri = $null

if (-not [uri]::TryCreate(
    $Repositorio,
    [System.UriKind]::Absolute,
    [ref]$ParsedUri
)) {
    throw "URL de repositorio no valida."
}

if ($ParsedUri.Scheme -ne "https") {
    throw "Solo se aceptan URLs HTTPS."
}

$AllowedHost = (
    $ParsedUri.Host -eq "dev.azure.com" -or
    $ParsedUri.Host -match '^[a-zA-Z0-9-]+\.visualstudio\.com$'
)

if (-not $AllowedHost) {
    throw "El dominio no corresponde a Azure DevOps."
}

# Se permite usuario@host, pero no usuario:password@host.
if ($ParsedUri.UserInfo -match ':') {
    throw "La URL contiene un posible secreto. Utilice una URL sin contrasena."
}

# Normalizar URL eliminando solo el identificador de usuario
$Builder = [System.UriBuilder]::new($ParsedUri)
$Builder.UserName = ""
$Builder.Password = ""
$Builder.Query = ""
$Builder.Fragment = ""

$CleanUrl = $Builder.Uri.AbsoluteUri.TrimEnd('/')

# Verificar que corresponda a un repositorio Git
if ($Builder.Uri.AbsolutePath -notmatch '/_git/[^/]+/?$') {
    throw "Se requiere la URL Git completa con /_git/Repositorio."
}

# ==========================================
# 3. PREPARAR RUTAS LOCALES
# ==========================================

$RepoName = [uri]::UnescapeDataString(
    $Builder.Uri.AbsolutePath.TrimEnd('/').Split('/')[-1]
)

$RepoName = $RepoName -replace '[\\/:*?"<>|]', '_'

if ([string]::IsNullOrWhiteSpace($RepoName) -or
    $RepoName -in @(".", "..")) {
    throw "Nombre de repositorio no valido."
}

if (-not (Test-Path -LiteralPath $Destino)) {
    New-Item -ItemType Directory -Path $Destino -Force |
        Out-Null
}

$Destino = (Resolve-Path -LiteralPath $Destino).Path

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$UniqueId = [guid]::NewGuid().ToString("N").Substring(0, 6)

$ZipPath = Join-Path $Destino (
    "$RepoName-$Timestamp-$UniqueId.zip"
)

$TempRoot = Join-Path $env:TEMP (
    "AzureRepo-" + [guid]::NewGuid().ToString("N")
)

$ClonePath = Join-Path $TempRoot "repo"

# ==========================================
# 4. CONFIGURAR AUTENTICACION NO INTERACTIVA
# ==========================================

$OldPrompt = $env:GIT_TERMINAL_PROMPT
$OldInteractive = $env:GCM_INTERACTIVE

$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "never"

try {
    Write-Host ""
    Write-Host "===================================" -ForegroundColor Cyan
    Write-Host "    AZURE DEVOPS - BACKUP LOCAL"
    Write-Host "===================================" -ForegroundColor Cyan

    Write-Host "Repositorio: $RepoName"
    Write-Host "Destino local: $Destino"

    New-Item -ItemType Directory -Path $TempRoot -Force |
        Out-Null

    # ==========================================
    # 5. CLONAR REPOSITORIO
    # ==========================================

    Write-Host ""
    Write-Host "[1/4] Descargando repositorio..." -ForegroundColor Yellow

    $GitArgs = @(
        "-c", "credential.interactive=false",
        "clone",
        "--depth", "1",
        "--single-branch"
    )

    if (-not [string]::IsNullOrWhiteSpace($Rama)) {
        $GitArgs += @("--branch", $Rama)
    }

    $GitArgs += @(
        "--",
        $CleanUrl,
        $ClonePath
    )

    & git @GitArgs

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo clonar. Verifique Git Credential Manager y permiso Read."
    }

    Write-Host "[OK] Codigo descargado." -ForegroundColor Green

    # ==========================================
    # 6. OBTENER COMMIT
    # ==========================================

    Write-Host "[2/4] Identificando version..." -ForegroundColor Yellow

    $Commit = (& git -C $ClonePath rev-parse HEAD).Trim()

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo identificar el commit."
    }

    Write-Host "Commit: $Commit"

    # ==========================================
    # 7. GENERAR ZIP LOCAL
    # ==========================================

    Write-Host "[3/4] Creando ZIP local..." -ForegroundColor Yellow

    & git -C $ClonePath archive `
        --format=zip `
        "--output=$ZipPath" `
        HEAD

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo crear el ZIP."
    }

    # ==========================================
    # 8. VALIDAR ZIP Y HASH
    # ==========================================

    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw "El archivo ZIP no existe."
    }

    $ZipFile = Get-Item -LiteralPath $ZipPath

    if ($ZipFile.Length -eq 0) {
        throw "El ZIP generado esta vacio."
    }

    $Hash = Get-FileHash `
        -LiteralPath $ZipPath `
        -Algorithm SHA256

    Write-Host "[4/4] ZIP verificado." -ForegroundColor Green

    Write-Host ""
    Write-Host "===================================" -ForegroundColor Green
    Write-Host "      DESCARGA COMPLETADA"
    Write-Host "===================================" -ForegroundColor Green

    Write-Host "Repositorio: $RepoName"
    Write-Host "Commit: $Commit"
    Write-Host "Archivo: $($ZipFile.FullName)"
    Write-Host "Tamano: $([math]::Round($ZipFile.Length / 1MB, 2)) MB"
    Write-Host "SHA256: $($Hash.Hash)"

}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    # Restaurar configuracion Git de la sesion
    $env:GIT_TERMINAL_PROMPT = $OldPrompt
    $env:GCM_INTERACTIVE = $OldInteractive

    # Eliminar copia temporal del codigo
    if (Test-Path -LiteralPath $TempRoot) {
        try {
            Remove-Item -LiteralPath $TempRoot `
                -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "No se pudo eliminar la copia temporal: $TempRoot"
        }
    }
}
