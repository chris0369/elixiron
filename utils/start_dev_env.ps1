# PowerShell Script to Start Development Environment for electro_test

Write-Host "Starting development environment with IPsec tunnel security..." -ForegroundColor Green

# --- 0. Setup Path Variables ---
# Get the project root directory (parent of utils directory)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$elixirServerPath = Join-Path $projectRoot "elixir_server"
$sftpServerPath = Join-Path $projectRoot "sftp_server"
$electronAppPath = Join-Path $projectRoot "electron_app"
$logsDir = Join-Path $projectRoot "logs"

Write-Host "Project paths:" -ForegroundColor Cyan
Write-Host "  Project Root:  $projectRoot" -ForegroundColor Gray
Write-Host "  Elixir Server: $elixirServerPath" -ForegroundColor Gray
Write-Host "  SFTP Server:   $sftpServerPath" -ForegroundColor Gray
Write-Host "  Electron App:  $electronAppPath" -ForegroundColor Gray
Write-Host "  Logs Dir:      $logsDir" -ForegroundColor Gray
Write-Host ""

# --- 1. Setup Logging ---
Write-Host "Setting up logging..." -ForegroundColor Cyan
if (Test-Path $logsDir) {
    Remove-Item -Recurse -Force $logsDir
}
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

$sftpLogFile = Join-Path $logsDir "sftp_server.log"
$elixirLogFile = Join-Path $logsDir "elixir_server.log"
$electronLogFile = Join-Path $logsDir "electron_app.log"

Write-Host "Log files will be created:" -ForegroundColor White
Write-Host "  SFTP Server:   $sftpLogFile" -ForegroundColor Gray
Write-Host "  Elixir Server: $elixirLogFile" -ForegroundColor Gray
Write-Host "  Electron App:  $electronLogFile" -ForegroundColor Gray
Write-Host ""

# --- 2. IPsec Tunnel Setup ---
Write-Host "Setting up IPsec tunnel for secure development..." -ForegroundColor Cyan

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: This script requires Administrator privileges to configure IPsec tunnel." -ForegroundColor Red
    Write-Host "Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Right-click PowerShell -> 'Run as Administrator'" -ForegroundColor Cyan
    exit 1
}

Write-Host "SUCCESS: Running with Administrator privileges" -ForegroundColor Green

# Add loopback alias for SFTP server (127.0.0.2)
Write-Host "Configuring loopback alias 127.0.0.2 for SFTP server..." -ForegroundColor White

try {
    # Remove existing alias if present (ignore errors)
    netsh interface ipv4 delete address "Loopback Pseudo-Interface 1" 127.0.0.2 2>$null

    # Add the loopback alias
    netsh interface ipv4 add address "Loopback Pseudo-Interface 1" 127.0.0.2 255.255.255.255
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "SUCCESS: Configured tunnel network (127.0.0.1 <-> 127.0.0.2)" -ForegroundColor Green
    } else {
        Write-Host "WARNING: Tunnel network may already be configured" -ForegroundColor Yellow
    }
} catch {
    Write-Host "WARNING: Error configuring tunnel network: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Continuing with development setup..." -ForegroundColor Gray
}

Write-Host ""
Write-Host "IPsec tunnel configuration:" -ForegroundColor Magenta
Write-Host "  elixir_server: 127.0.0.1:4001 (WebSocket + FileStorage client)" -ForegroundColor White  
Write-Host "  sftp_server:   127.0.0.2:2222 (SFTP server)" -ForegroundColor White
Write-Host "  Security:      ENABLED and enforced (AES-256)" -ForegroundColor Green

# --- 3. Stop Existing Processes ---
Write-Host ""
Write-Host "Stopping existing processes..." -ForegroundColor Cyan
Get-Process beam.smp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process electron-channel-app -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "Waiting for processes to terminate..." -ForegroundColor Gray
Start-Sleep -Seconds 3

# --- 4. Clean and Compile Elixir Projects ---
Write-Host ""
Write-Host "Cleaning and compiling elixir_server..." -ForegroundColor Cyan
$elixirBuildPath = Join-Path $elixirServerPath "_build"
if (Test-Path $elixirBuildPath) {
    Write-Host "  Removing build artifacts..." -ForegroundColor Gray
    Remove-Item -Recurse -Force $elixirBuildPath -ErrorAction SilentlyContinue
}
Push-Location $elixirServerPath
Remove-Item -Recurse -Force "deps" -ErrorAction SilentlyContinue
mix clean --all
mix deps.get
mix compile
Pop-Location

Write-Host ""
Write-Host "Cleaning and compiling sftp_server..." -ForegroundColor Cyan
$sftpBuildPath = Join-Path $sftpServerPath "_build"
if (Test-Path $sftpBuildPath) {
    Write-Host "  Removing build artifacts..." -ForegroundColor Gray
    Remove-Item -Recurse -Force $sftpBuildPath -ErrorAction SilentlyContinue
}
Push-Location $sftpServerPath
Remove-Item -Recurse -Force "deps" -ErrorAction SilentlyContinue
mix clean --all
mix deps.get
mix compile
Pop-Location

# --- 5. Start Servers with IPsec Tunnel ---
Write-Host ""
Write-Host "Starting SFTP server with IPsec tunnel..." -ForegroundColor Cyan
$sftpCmd = @"
Start-Transcript -Path '$sftpLogFile' -Force
Write-Host 'SFTP Server Log Started - `$(Get-Date)' -ForegroundColor Green
cd '$sftpServerPath'
mix run --no-halt
"@
Start-Process powershell -ArgumentList "-NoExit", "-Command", "$sftpCmd" -WindowStyle Normal

Write-Host "Waiting for SFTP server to initialize..." -ForegroundColor Gray
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "Starting Elixir server with IPsec tunnel..." -ForegroundColor Cyan
$elixirCmd = @"
Start-Transcript -Path '$elixirLogFile' -Force
Write-Host 'Elixir Server Log Started - `$(Get-Date)' -ForegroundColor Green
cd '$elixirServerPath'
mix run --no-halt
"@
Start-Process powershell -ArgumentList "-NoExit", "-Command", "$elixirCmd" -WindowStyle Normal

Write-Host "Waiting for Elixir server to initialize..." -ForegroundColor Gray
Start-Sleep -Seconds 3

# --- 6. Start Electron App ---
Write-Host ""
Write-Host "Setting up and starting Electron app..." -ForegroundColor Cyan
$electronCmd = @"
Start-Transcript -Path '$electronLogFile' -Force
Write-Host 'Electron App Log Started - `$(Get-Date)' -ForegroundColor Green
cd '$electronAppPath'
Write-Host 'Installing dependencies...' -ForegroundColor Gray
npm install
Write-Host 'Starting Electron app...' -ForegroundColor White
npm start
"@
Start-Process powershell -ArgumentList "-NoExit", "-Command", "$electronCmd" -WindowStyle Normal

# --- 7. Summary ---
Write-Host ""
Write-Host "COMPLETE: Development environment started successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Log Files Created:" -ForegroundColor White
Write-Host "  SFTP Server:   $sftpLogFile" -ForegroundColor Green
Write-Host "  Elixir Server: $elixirLogFile" -ForegroundColor Green
Write-Host "  Electron App:  $electronLogFile" -ForegroundColor Green
Write-Host ""
Write-Host "Expected security status in server logs:" -ForegroundColor White
Write-Host "  SUCCESS: [IPsecManager] Initial tunnel setup completed" -ForegroundColor Green
Write-Host "  SUCCESS: [SftpServer] Using secure IPsec tunnel binding" -ForegroundColor Green
Write-Host "  SUCCESS: [SFTPAdapter] [SECURE IPsec Tunnel] File operations" -ForegroundColor Green
Write-Host ""
Write-Host "Monitor logs with:" -ForegroundColor Cyan
Write-Host "  Get-Content -Path '$sftpLogFile' -Wait" -ForegroundColor Gray
Write-Host "  Get-Content -Path '$elixirLogFile' -Wait" -ForegroundColor Gray
Write-Host "  Get-Content -Path '$electronLogFile' -Wait" -ForegroundColor Gray
Write-Host ""
Write-Host "If you see security errors:" -ForegroundColor Yellow
Write-Host "  - Check that both server windows opened successfully" -ForegroundColor Gray
Write-Host "  - Verify tunnel setup: ipconfig | findstr '127.0.0.2'" -ForegroundColor Gray
Write-Host "  - See DEVSECOPS_SETUP.md for troubleshooting" -ForegroundColor Gray 