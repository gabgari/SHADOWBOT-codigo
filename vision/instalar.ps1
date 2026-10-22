# Instalador del sistema de vision del robot (fuego, personas, vehiculos, fisuras, oxido).
# Lo ejecuta INSTALAR.bat. Instala Python 3.12, las librerias, el acceso directo y el permiso del firewall.
param([switch]$Prueba)  # -Prueba: no crea acceso directo ni regla de firewall (para probar el instalador)

$ErrorActionPreference = "Stop"
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $carpeta
# Windows falla con rutas muy largas al instalar PyTorch
if ($carpeta.Length -gt 80) {
    throw "La carpeta esta en una ruta muy larga ($carpeta). Muevela a C:\Vision_Robot y vuelve a ejecutar INSTALAR.bat"
}

function Paso($texto) { Write-Host ""; Write-Host "==> $texto" -ForegroundColor Cyan }

# 1. Python 3.12
Paso "Buscando Python 3.12..."
$py = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
if (-not (Test-Path $py)) {
    Paso "Instalando Python 3.12 (unos minutos)..."
    winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements --silent
    if (-not (Test-Path $py)) { throw "No se pudo instalar Python. Instalalo a mano desde python.org (version 3.12) y vuelve a ejecutar INSTALAR.bat" }
}
& $py --version

# 2. Entorno virtual + librerias
if (-not (Test-Path ".venv\Scripts\python.exe")) {
    Paso "Creando el entorno de Python..."
    & $py -m venv .venv
}
$vpy = Join-Path $carpeta ".venv\Scripts\python.exe"
Paso "Instalando PyTorch para CPU (descarga de ~200 MB, ten paciencia)..."
& $vpy -m pip install --upgrade pip -q
& $vpy -m pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cpu -q
if ($LASTEXITCODE -ne 0) { throw "Fallo la instalacion de PyTorch. Revisa tu internet y vuelve a ejecutar INSTALAR.bat" }
Paso "Instalando YOLO, OpenCV y el servidor..."
& $vpy -m pip install -r requirements.txt -q
if ($LASTEXITCODE -ne 0) { throw "Fallo la instalacion de librerias. Revisa tu internet y vuelve a ejecutar INSTALAR.bat" }

# 3. Prueba rapida: cargar los 4 modelos y detectar fuego en una imagen
Paso "Probando los modelos..."
& $vpy -W ignore -c "import sys; sys.argv=['x']; sys.path.insert(0, '.'); import cv2, detectar_fuego as v; m = v.cargar_modelos(); d = v.detectar(m, cv2.imread('pruebas/fire1.jpg'), 'todo'); print('Modelos OK. Fuego en la imagen de prueba:', [x['etiqueta'] for x in d])"
if ($LASTEXITCODE -ne 0) { throw "La prueba de los modelos fallo." }

if (-not $Prueba) {
    # 4. Acceso directo en el escritorio
    Paso "Creando el acceso directo 'Detector de Fuego' en el escritorio..."
    $escritorio = [Environment]::GetFolderPath("Desktop")
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut("$escritorio\Detector de Fuego.lnk")
    $s.TargetPath = Join-Path $carpeta "iniciar_detector.bat"
    $s.WorkingDirectory = $carpeta
    $s.IconLocation = "$env:SystemRoot\System32\shell32.dll,77"
    $s.Save()

    # 5. Firewall (pide permiso de administrador una vez)
    if (-not (Get-NetFirewallRule -DisplayName "Detector fuego YOLO (5000)" -ErrorAction SilentlyContinue)) {
        Paso "Abriendo el puerto 5000 en el firewall (acepta la ventana de permiso de Windows)..."
        Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command New-NetFirewallRule -DisplayName 'Detector fuego YOLO (5000)' -Direction Inbound -Protocol TCP -LocalPort 5000 -Action Allow -Profile Private,Public"
    }
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  LISTO. Usa el acceso directo del escritorio:" -ForegroundColor Green
Write-Host "        'Detector de Fuego'" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
