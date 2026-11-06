
<#
.SYNOPSIS
    Descarga un repositorio Azure DevOps y genera un ZIP.

.DESCRIPTION
    - Usa Git Credential Manager.
    - Reutiliza las credenciales Windows existentes.
    - No solicita ni muestra tokens.
    - Descarga la rama predeterminada o una especificada.
    - Genera un ZIP sin el directorio .git.
    - Elimina los archivos temporales.
    - No modifica el repositorio remoto.

.EXAMPLE
    .\download-azure-repo.ps1 `
      -Repositorio "https://dev.azure.com/Deprati/Proyecto/_git/Repo"

.EXAMPLE
    .\download-azure-repo.ps1 `
      -Repositorio "https://dev.azure.com/Deprati/Proyecto/_git/Repo" `
      -Rama "develop"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Repositorio,

    [string]$Rama,

    [string]$Destino = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

# 1. Verificar ambiente
if ($env:OS -ne "Windows_NT") {
    throw "El script esta disenado para Windows."
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git for Windows no esta instalado."
}

# 2. Validar URL
$Uri = $null

if (-not [uri]::TryCreate(
    $Repositorio,
    [System.UriKind]::Absolute,
    [ref]$Uri
)) {
    throw "La URL del repositorio no es valida."
}

if ($Uri.Scheme -ne "https") {
    throw "Solo se admiten repositorios HTTPS."
}

if (
    $Uri.Host -ne "dev.azure.com" -and
    $Uri.Host -notmatch '^[a-zA-Z0-9-]+\.visualstudio\.com$'
) {
    throw "La URL debe pertenecer a Azure DevOps."
}

if ($Uri.UserInfo) {
    throw "No incluya credenciales en la URL."
}

if ($Uri.AbsolutePath -notmatch '/_git/[^/]+/?$') {
    throw "Debe proporcionar la URL Git completa del repositorio."
}

# 3. Preparar directorios
$RepoName = [uri]::UnescapeDataString(
    $Uri.AbsolutePath.TrimEnd('/').Split('/')[-1]
)

$RepoName = $RepoName -replace '[\\/:*?"<>|]', '_'

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

if (-not (Test-Path -LiteralPath $Destino)) {
    New-Item -ItemType Directory -Path $Destino -Force |
        Out-Null
}

$Destino = (Resolve-Path -LiteralPath $Destino).Path

$ZipPath = Join-Path $Destino "$RepoName-$Timestamp.zip"

$TempRoot = Join-Path $env:TEMP (
    "RedTeamRepo-" + [guid]::NewGuid().ToString("N")
)

$ClonePath = Join-Path $TempRoot "codigo"

# 4. Evitar nuevas solicitudes de credenciales
$OldGitPrompt = $env:GIT_TERMINAL_PROMPT
$OldGcmInteractive = $env:GCM_INTERACTIVE

$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "false"

try {

    Write-Host "`n=== DESCARGA AZURE DEVOPS ===" `
        -ForegroundColor Cyan

    Write-Host "Repositorio: $RepoName"
    Write-Host "Destino: $Destino"

    New-Item -ItemType Directory -Path $TempRoot -Force |
        Out-Null

    # 5. Clonar utilizando Git Credential Manager
    Write-Host "`n[1/4] Autenticando y descargando..." `
        -ForegroundColor Yellow

    $GitArgs = @(
        "-c", "credential.helper=",
        "-c", "credential.helper=manager",
        "clone",
        "--depth", "1",
        "--single-branch"
    )

    if ($Rama) {
        $GitArgs += @("--branch", $Rama)
    }

    $GitArgs += @(
        "--",
        $Repositorio,
        $ClonePath
    )

    & git @GitArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Error de Git. Revise credenciales y permisos Read."
    }

    Write-Host "[OK] Repositorio descargado." `
        -ForegroundColor Green

    # 6. Obtener commit descargado
    Write-Host "[2/4] Verificando commit..." `
        -ForegroundColor Yellow

    $Commit = (& git -C $ClonePath rev-parse HEAD).Trim()

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo identificar el commit."
    }

    Write-Host "Commit: $Commit"

    # 7. Generar ZIP del codigo versionado
    Write-Host "[3/4] Generando ZIP..." `
        -ForegroundColor Yellow

    & git -C $ClonePath archive `
        --format=zip `
        "--output=$ZipPath" `
        HEAD

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo generar el ZIP."
    }

    # 8. Verificar archivo
    if (-not (Test-Path -LiteralPath $ZipPath)) {
        throw "El ZIP no fue generado."
    }

    $File = Get-Item -LiteralPath $ZipPath

    $Hash = Get-FileHash `
        -LiteralPath $ZipPath `
        -Algorithm SHA256

    Write-Host "[4/4] Verificacion finalizada." `
        -ForegroundColor Green

    Write-Host "`n=== RESULTADO ===" `
        -ForegroundColor Cyan

    Write-Host "Repositorio : $RepoName"
    Write-Host "Commit      : $Commit"
    Write-Host "ZIP         : $($File.FullName)"
    Write-Host "Tamano      : $([math]::Round($File.Length / 1MB, 2)) MB"
    Write-Host "SHA256      : $($Hash.Hash)"

    Write-Host "`n[OK] DESCARGA COMPLETADA" `
        -ForegroundColor Green

}
catch {
    Write-Host "`n[ERROR] $($_.Exception.Message)" `
        -ForegroundColor Red
    throw
}
finally {

    # Restaurar variables de entorno
    $env:GIT_TERMINAL_PROMPT = $OldGitPrompt
    $env:GCM_INTERACTIVE = $OldGcmInteractive

    # Eliminar clon temporal
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot `
            -Recurse -Force -ErrorAction SilentlyContinue
    }
}
