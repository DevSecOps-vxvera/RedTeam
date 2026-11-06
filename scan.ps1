
<#
.SYNOPSIS
    Auditoria de nombres de credenciales DevOps en Windows.

.DESCRIPTION
    Identifica nombres de claves y tokens en:
      - Variables de entorno de proceso, usuario y equipo
      - Archivos de configuracion conocidos
      - Archivos de proyectos (opcional)
      - Windows Credential Manager (metadatos opcionales)

    Nunca imprime ni exporta valores de credenciales.

.EXAMPLE
    .\Audit-DevOpsKeys.ps1

.EXAMPLE
    .\Audit-DevOpsKeys.ps1 -AllUsers

.EXAMPLE
    .\Audit-DevOpsKeys.ps1 -ProjectPath "C:\Proyectos"

.EXAMPLE
    .\Audit-DevOpsKeys.ps1 -CsvPath "C:\Auditoria\keys.csv"
#>

[CmdletBinding()]
param(
    [switch]$AllUsers,
    [switch]$CredentialManager,
    [string]$ProjectPath,
    [string]$CsvPath
)

$ErrorActionPreference = "Stop"

# Coleccion de nombres, sin valores
$Names = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

# Patrones que indican variables relacionadas con credenciales
$KeyPattern = '(?i)(TOKEN|SECRET|PASSWORD|PASSWD|_PWD|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIAL|AUTH|PAT$|SAS[_-]?TOKEN|KEY_ID|CLIENT_ID|TENANT_ID|SUBSCRIPTION_ID)'

$KnownKeys = @(
    'GOOGLE_APPLICATION_CREDENTIALS',
    'KUBECONFIG',
    'DOCKER_CONFIG',
    'AWS_PROFILE',
    'AWS_SHARED_CREDENTIALS_FILE',
    'TF_CLI_CONFIG_FILE',
    'credential_process',
    'auths',
    'credsStore',
    'credHelpers'
)

function Add-KeyName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    $Name = $Name.Trim()

    if ($Name -match $script:KeyPattern -or
        $Name -in $script:KnownKeys) {

        [void]$script:Names.Add($Name)
    }
}

function Scan-Environment {

    foreach ($Scope in @(
        'Process',
        'User',
        'Machine'
    )) {

        try {
            $Variables = [Environment]::GetEnvironmentVariables(
                [EnvironmentVariableTarget]::$Scope
            )

            foreach ($Name in $Variables.Keys) {
                Add-KeyName -Name ([string]$Name)
            }
        }
        catch {
            Write-Verbose "No se pudo consultar el ambito $Scope"
        }
    }
}

function Scan-ConfigFile {
    param([string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return
    }

    try {
        $File = Get-Item -LiteralPath $FilePath

        # Evitar archivos grandes o caches binarios
        if ($File.Length -gt 2MB) {
            return
        }

        # Se analiza cada linea sin imprimir su contenido
        Get-Content -LiteralPath $FilePath -ErrorAction Stop |
        ForEach-Object {

            $Line = $_

            if ($Line -match '^\s*[#;]') {
                return
            }

            # JSON, YAML, INI, ENV, TOML
            if ($Line -match '^\s*["'']?([A-Za-z_][A-Za-z0-9_.-]*)["'']?\s*[:=]') {

                Add-KeyName -Name $Matches[1]
            }

            # npmrc: //registry/:_authToken=...
            if ($Line -match '(?i):(_authToken)\s*=') {
                Add-KeyName -Name $Matches[1]
            }

            # Variables exportadas por shells
            if ($Line -match '^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)\s*=') {
                Add-KeyName -Name $Matches[1]
            }
        }
    }
    catch {
        Write-Verbose "Archivo omitido por error de lectura."
    }
}

function Scan-UserProfiles {

    $Profiles = @($env:USERPROFILE)

    if ($AllUsers) {

        $Profiles = @(
            Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notin @(
                    'Public',
                    'Default',
                    'Default User',
                    'All Users'
                )
            } |
            Select-Object -ExpandProperty FullName
        )
    }

    $RelativeFiles = @(
        '.aws\credentials',
        '.aws\config',
        '.azure\azureProfile.json',
        '.azure\accessTokens.json',
        '.config\gcloud\application_default_credentials.json',
        '.config\gh\hosts.yml',
        'AppData\Roaming\GitHub CLI\hosts.yml',
        '.docker\config.json',
        '.kube\config',
        '.npmrc',
        '.pypirc',
        '.terraformrc',
        '.gitconfig',
        '.env',
        '.env.local',
        '.env.production',
        'AppData\Roaming\Code\User\settings.json'
    )

    foreach ($Profile in $Profiles) {

        foreach ($RelativeFile in $RelativeFiles) {

            $FullPath = Join-Path $Profile $RelativeFile

            Scan-ConfigFile -FilePath $FullPath
        }
    }
}

function Scan-Project {
    param([string]$Path)

    if (-not $Path) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "La ruta del proyecto no existe."
    }

    $Extensions = @(
        '.json', '.yaml', '.yml', '.ini',
        '.config', '.properties', '.tfvars',
        '.toml', '.ps1'
    )

    Get-ChildItem -LiteralPath $Path -File -Recurse `
        -ErrorAction SilentlyContinue |
    Where-Object {

        $_.FullName -notmatch '[\\/](node_modules|\.git|\.venv|vendor)[\\/]' -and
        (
            $_.Extension -in $Extensions -or
            $_.Name -match '^\.env($|\.)' -or
            $_.Name -match '\.tfvars\.json$' -or
            $_.Name -eq '.npmrc'
        )
    } |
    ForEach-Object {
        Scan-ConfigFile -FilePath $_.FullName
    }
}

function Scan-CredentialManager {

    # Solo se consultan los nombres de destino.
    # No se solicitan ni se leen contrasenas.

    try {
        $Output = & cmdkey.exe /list 2>$null

        foreach ($Line in $Output) {

            if ($Line -match '^\s*(Target|Destino)\s*:\s*(.+)$') {

                $TargetName = $Matches[2].Trim()

                if ($TargetName -match '(?i)(git|github|gitlab|azure|aws|docker|devops|terraform|jenkins|vault|bitbucket)') {

                    [void]$script:Names.Add(
                        "CredentialManager:$TargetName"
                    )
                }
            }
        }
    }
    catch {
        Write-Verbose "Credential Manager no disponible."
    }
}

# -------- EJECUCION --------

Scan-Environment
Scan-UserProfiles
Scan-Project -Path $ProjectPath

if ($CredentialManager) {
    Scan-CredentialManager
}

# Resultado: UNA SOLA COLUMNA CON NOMBRES
$Report = @(
    $Names |
    Sort-Object |
    ForEach-Object {
        [PSCustomObject]@{
            NombreKey = $_
        }
    }
)

if ($CsvPath) {

    $Report | Export-Csv `
        -LiteralPath $CsvPath `
        -NoTypeInformation `
        -Encoding UTF8
}

$Report | Format-Table -AutoSize

Write-Host "Total de nombres identificados: $($Report.Count)"
