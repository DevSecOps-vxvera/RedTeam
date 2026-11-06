
<#
.SYNOPSIS
  Audita permisos en Azure DevOps utilizando credenciales
  almacenadas en Git Credential Manager.

  No solicita PAT.
  No imprime ni exporta credenciales.
  No realiza cambios en repositorios.
#>

[CmdletBinding()]
param(
    [string]$Organization = "Deprati",
    [string]$CsvPath = ".\permisos_azuredevops.csv"
)

$ErrorActionPreference = "Stop"

$Namespace = "2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87"
$BaseUrl = "https://dev.azure.com/$Organization"

# Permisos de Azure Repos Git
$Permissions = [ordered]@{
    Read              = 2
    Contribute        = 4
    ForcePush         = 8
    CreateBranch      = 16
    CreateTag         = 32
    BypassPolicies    = 128
    DeleteRepository  = 512
    EditPolicies      = 2048
    ManagePermissions = 8192
}

# Identificadores encontrados en Windows
$Targets = @(
    @{
        Nombre = "git:https://dev.azure.com/Deprati"
        Url    = "https://dev.azure.com/Deprati"
    },
    @{
        Nombre = "git:https://deprati.visualstudio.com"
        Url    = "https://deprati.visualstudio.com"
    }
)

# Recuperar credencial mediante Git Credential Manager.
# Su valor permanece en memoria y no se imprime.
function Get-GitStoredCredential {
    param([string]$Url)

    $Output = @(
        @("url=$Url", "") |
        & git -c credential.useHttpPath=true `
              -c credential.interactive=false `
              credential fill 2>$null
    )

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $Data = @{}

    foreach ($Line in $Output) {
        if ($Line -match '^([^=]+)=(.*)$') {
            $Data[$Matches[1]] = $Matches[2]
        }
    }

    $Output = $null

    if (-not $Data.ContainsKey("password")) {
        return $null
    }

    $Username = "oauth2"

    if ($Data.ContainsKey("username")) {
        $Username = $Data["username"]
    }

    return [PSCustomObject]@{
        Username = $Username
        Password = $Data["password"]
    }
}

# Consultar API usando el token obtenido en memoria.
function Invoke-AdoApi {
    param(
        [string]$Uri,
        [object]$Credential,
        [string]$Mode,
        [string]$Method = "Get",
        [string]$Body
    )

    if ($Mode -eq "Basic") {
        $Pair = "$($Credential.Username):$($Credential.Password)"
        $Encoded = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($Pair)
        )
        $Authorization = "Basic $Encoded"
        $Pair = $null
    }
    else {
        $Authorization = "Bearer $($Credential.Password)"
    }

    $Headers = @{
        Authorization = $Authorization
        Accept = "application/json"
    }

    $Params = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        ErrorAction = "Stop"
    }

    if ($Method -eq "Post") {
        $Params.ContentType = "application/json"
        $Params.Body = $Body
    }

    try {
        return Invoke-RestMethod @Params
    }
    finally {
        $Authorization = $null
        $Headers = $null
        $Encoded = $null
    }
}

function New-Result {
    param(
        [string]$Origin,
        [string]$Status,
        [object]$Repo = $null
    )

    $Record = [ordered]@{
        Credencial = $Origin
        Estado = $Status
        Proyecto = ""
        Repositorio = ""
        URL = ""
    }

    if ($Repo) {
        $Record.Proyecto = $Repo.project.name
        $Record.Repositorio = $Repo.name
        $Record.URL = $Repo.remoteUrl
    }

    foreach ($Name in $Permissions.Keys) {
        $Record[$Name] = "NO EVALUADO"
    }

    return $Record
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git for Windows no esta instalado."
}

# Evitar solicitudes interactivas de nuevas credenciales
$OldPrompt = $env:GIT_TERMINAL_PROMPT
$OldInteractive = $env:GCM_INTERACTIVE

$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "0"

$Results = @()

try {
    Write-Host "`n=== AUDITORIA AZURE DEVOPS ===" -ForegroundColor Cyan

    foreach ($Target in $Targets) {

        $Credential = $null

        Write-Host "`nCredencial: $($Target.Nombre)" -ForegroundColor Yellow

        try {
            $Credential = Get-GitStoredCredential -Url $Target.Url

            if (-not $Credential) {
                Write-Warning "No se obtuvo una credencial almacenada."
                $Results += [PSCustomObject](New-Result `
                    -Origin $Target.Nombre `
                    -Status "SIN CREDENCIAL")
                continue
            }

            Write-Host "[OK] Credencial obtenida mediante Git." `
                -ForegroundColor Green

            # Probar autenticacion con API REST
            $RepoResponse = $null
            $SelectedMode = $null

            foreach ($Mode in @("Basic", "Bearer")) {
                try {
                    $RepoResponse = Invoke-AdoApi `
                        -Uri "$BaseUrl/_apis/git/repositories?api-version=7.1" `
                        -Credential $Credential `
                        -Mode $Mode

                    $SelectedMode = $Mode
                    break
                }
                catch {
                    # Intentar el siguiente mecanismo de autenticacion
                }
            }

            if (-not $SelectedMode) {
                Write-Warning "No se pudo autenticar contra la API."
                $Results += [PSCustomObject](New-Result `
                    -Origin $Target.Nombre `
                    -Status "API NO DISPONIBLE")
                continue
            }

            $Repos = @($RepoResponse.value)

            Write-Host "[OK] Repositorios visibles: $($Repos.Count)" `
                -ForegroundColor Green

            if ($Repos.Count -eq 0) {
                $Results += [PSCustomObject](New-Result `
                    -Origin $Target.Nombre `
                    -Status "SIN REPOSITORIOS")
                continue
            }

            foreach ($Repo in $Repos) {

                Write-Host "Evaluando: $($Repo.project.name)/$($Repo.name)"

                $Record = New-Result `
                    -Origin $Target.Nombre `
                    -Status "AUTENTICADO" `
                    -Repo $Repo

                $SecurityToken = "repoV2/$($Repo.project.id)/$($Repo.id)"

                $Evaluations = @(
                    foreach ($Permission in $Permissions.GetEnumerator()) {
                        @{
                            securityNamespaceId = $Namespace
                            token = $SecurityToken
                            permissions = [int]$Permission.Value
                        }
                    }
                )

                $Body = @{
                    alwaysAllowAdministrators = $false
                    evaluations = $Evaluations
                } | ConvertTo-Json -Depth 8

                try {
                    # Esta API evalua permisos; no los modifica.
                    $EvaluationResponse = Invoke-AdoApi `
                        -Uri "$BaseUrl/_apis/security/permissionevaluationbatch?api-version=7.1" `
                        -Credential $Credential `
                        -Mode $SelectedMode `
                        -Method "Post" `
                        -Body $Body

                    $Map = @{}

                    foreach ($Evaluation in $EvaluationResponse.evaluations) {
                        $Key = [string]$Evaluation.permissions

                        $Map[$Key] = if ($Evaluation.value) {
                            "SI"
                        }
                        else {
                            "NO"
                        }
                    }

                    foreach ($Permission in $Permissions.GetEnumerator()) {
                        $Key = [string]$Permission.Value

                        if ($Map.ContainsKey($Key)) {
                            $Record[$Permission.Key] = $Map[$Key]
                        }
                    }

                    $Record.Estado = "EVALUADO"
                }
                catch {
                    $Record.Estado = "PERMISOS NO EVALUADOS"
                    Write-Warning "La API no permitio evaluar los permisos."
                }

                $Results += [PSCustomObject]$Record
            }
        }
        finally {
            if ($Credential) {
                $Credential.Password = $null
                $Credential = $null
            }
        }
    }
}
finally {
    $env:GIT_TERMINAL_PROMPT = $OldPrompt
    $env:GCM_INTERACTIVE = $OldInteractive
}

# Exportar resultados sin credenciales
$Results | Export-Csv `
    -LiteralPath $CsvPath `
    -NoTypeInformation `
    -Encoding UTF8

Write-Host "`n=== RESULTADOS ===" -ForegroundColor Cyan

$Results |
    Format-Table Credencial, Proyecto, Repositorio,
                 Estado, Read, Contribute, ManagePermissions `
                 -AutoSize

Write-Host "`nEvidencia guardada en: $CsvPath" -ForegroundColor Green
