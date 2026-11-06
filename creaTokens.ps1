<#
    Implanta-Canary.ps1  (solo siembra)
    Crea un honeytoken (credencial AWS falsa) en el equipo de pruebas.
    No activa auditoria. Uso: equipo de pruebas autorizado.
    Segtium - Ejercicio de simulacion de cadena de suministro.
#>

[CmdletBinding()]
param(
    [string]$RutaCanary = "$env:USERPROFILE\.aws\credentials"
)

# --- 1. Asegurar el directorio destino ---
$dir = Split-Path $RutaCanary -Parent
if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# --- 2. Generar el honeytoken (credencial falsa, no es real) ---
$sufijo    = -join ((48..57) + (65..90) | Get-Random -Count 6 | ForEach-Object {[char]$_})
$contenido = @"
[default]
aws_access_key_id = AKIAZ7QX4J2NTEST0$sufijo
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCY$sufijo`DECOY
"@
Set-Content -Path $RutaCanary -Value $contenido -Encoding ASCII -Force

# --- 3. Verificacion ---
if (Test-Path $RutaCanary) {
    Write-Host "[+] Honeytoken sembrado en: $RutaCanary" -ForegroundColor Green
    Write-Host "[+] Sufijo de correlacion: $sufijo" -ForegroundColor Cyan
} else {
    Write-Error "No se pudo crear el honeytoken en $RutaCanary"
    exit 1
}