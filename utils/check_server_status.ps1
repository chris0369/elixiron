# PowerShell Script to Check Server Status for electro_test

Write-Host "Checking server status..." -ForegroundColor Green
Write-Host ""

# --- Setup Path Variables ---
# Get the project root directory (parent of utils directory)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

Write-Host "Script location: $scriptDir" -ForegroundColor Gray
Write-Host "Project root:    $projectRoot" -ForegroundColor Gray
Write-Host ""

# Server endpoints configuration
$elixirServerPort = 4001
$sftpHealthPort = 2223
$elixirServerHealth = "http://localhost:$elixirServerPort/health"
$elixirServerStatus = "http://localhost:$elixirServerPort/status"
$sftpServerHealth = "http://localhost:$sftpHealthPort/health"
$sftpServerStatus = "http://localhost:$sftpHealthPort/status"

# Function to make HTTP request with error handling
function Get-ServerStatus {
    param(
        [string]$Url,
        [string]$ServerName,
        [string]$Type = "health"
    )
    
    try {
        $response = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 5
        return @{
            Success = $true
            Data = $response
            ServerName = $ServerName
            Type = $Type
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
            ServerName = $ServerName
            Type = $Type
        }
    }
}

# Function to display server status
function Show-ServerStatus {
    param($StatusResult)
    
    $serverName = $StatusResult.ServerName
    $type = $StatusResult.Type
    
    if ($StatusResult.Success) {
        $data = $StatusResult.Data
        $status = $data.status
        $timestamp = $data.timestamp
        
        if ($status -eq "healthy") {
            Write-Host "[OK] $serverName ($type): " -NoNewline -ForegroundColor Green
            Write-Host "$status" -ForegroundColor Green
        } else {
            Write-Host "[WARN] $serverName ($type): " -NoNewline -ForegroundColor Yellow
            Write-Host "$status" -ForegroundColor Yellow
        }
        
        if ($type -eq "health") {
            Write-Host "  Uptime: $($data.uptime_seconds)s" -ForegroundColor Gray
            
            # Show IPsec status
            if ($data.ipsec_status) {
                $ipsecStatus = $data.ipsec_status.status
                if ($ipsecStatus -eq "active") {
                    Write-Host "  IPsec: " -NoNewline -ForegroundColor Gray
                    Write-Host "ACTIVE" -ForegroundColor Green
                } else {
                    Write-Host "  IPsec: " -NoNewline -ForegroundColor Gray
                    Write-Host "$ipsecStatus" -ForegroundColor Red
                }
            }
            
            # Show SFTP connectivity (for elixir server)
            if ($data.sftp_connectivity) {
                $sftpStatus = $data.sftp_connectivity.status
                if ($sftpStatus -eq "connected") {
                    Write-Host "  SFTP: " -NoNewline -ForegroundColor Gray
                    Write-Host "CONNECTED" -ForegroundColor Green
                } else {
                    Write-Host "  SFTP: " -NoNewline -ForegroundColor Gray
                    Write-Host "$sftpStatus" -ForegroundColor Red
                }
            }
            
            # Show SFTP server status (for sftp server)
            if ($data.sftp_server_status) {
                $sftpServerStatus = $data.sftp_server_status.status
                if ($sftpServerStatus -eq "running") {
                    Write-Host "  SFTP Server: " -NoNewline -ForegroundColor Gray
                    Write-Host "RUNNING" -ForegroundColor Green
                } else {
                    Write-Host "  SFTP Server: " -NoNewline -ForegroundColor Gray
                    Write-Host "$sftpServerStatus" -ForegroundColor Red
                }
            }
        }
        
        Write-Host "  Last check: $timestamp" -ForegroundColor Gray
    } else {
        Write-Host "[ERROR] $serverName ($type): " -NoNewline -ForegroundColor Red
        Write-Host "UNREACHABLE" -ForegroundColor Red
        Write-Host "  Error: $($StatusResult.Error)" -ForegroundColor Red
    }
    Write-Host ""
}

# Function to show detailed status
function Show-DetailedStatus {
    param($StatusResult)
    
    if ($StatusResult.Success) {
        $data = $StatusResult.Data
        Write-Host "=== $($StatusResult.ServerName.ToUpper()) DETAILED STATUS ===" -ForegroundColor Cyan
        Write-Host "Service: $($data.service)" -ForegroundColor White
        Write-Host "Status: $($data.status)" -ForegroundColor White
        Write-Host "Uptime: $($data.uptime_seconds) seconds" -ForegroundColor White
        
        if ($data.system_info) {
            Write-Host ""
            Write-Host "System Information:" -ForegroundColor Yellow
            Write-Host "  Erlang Version: $($data.system_info.erlang_version)" -ForegroundColor Gray
            Write-Host "  Elixir Version: $($data.system_info.elixir_version)" -ForegroundColor Gray
            Write-Host "  Node Name: $($data.system_info.node_name)" -ForegroundColor Gray
            Write-Host "  Process Count: $($data.system_info.process_count)" -ForegroundColor Gray
        }
        
        if ($data.application_info) {
            Write-Host ""
            Write-Host "Application Configuration:" -ForegroundColor Yellow
            $data.application_info.PSObject.Properties | ForEach-Object {
                Write-Host "  $($_.Name): $($_.Value)" -ForegroundColor Gray
            }
        }
        
        if ($data.supervisor_status) {
            Write-Host ""
            Write-Host "Supervisor Status:" -ForegroundColor Yellow
            Write-Host "  Running: $($data.supervisor_status.supervisor_running)" -ForegroundColor Gray
            Write-Host "  Children Count: $($data.supervisor_status.children_count)" -ForegroundColor Gray
            
            if ($data.supervisor_status.children) {
                Write-Host "  Children:" -ForegroundColor Gray
                $data.supervisor_status.children | ForEach-Object {
                    $statusColor = if ($_.status -eq "running") { "Green" } else { "Red" }
                    Write-Host "    - $($_.id): " -NoNewline -ForegroundColor Gray
                    Write-Host "$($_.status)" -ForegroundColor $statusColor
                }
            }
        }
        Write-Host ""
    }
}

# Check Elixir Server
Write-Host "=== ELIXIR SERVER ===" -ForegroundColor Cyan
$elixirHealth = Get-ServerStatus -Url $elixirServerHealth -ServerName "Elixir Server" -Type "health"
Show-ServerStatus -StatusResult $elixirHealth

# Check SFTP Server
Write-Host "=== SFTP SERVER ===" -ForegroundColor Cyan
$sftpHealth = Get-ServerStatus -Url $sftpServerHealth -ServerName "SFTP Server" -Type "health"
Show-ServerStatus -StatusResult $sftpHealth

# Summary
Write-Host "=== SUMMARY ===" -ForegroundColor Magenta
$elixirRunning = $elixirHealth.Success -and $elixirHealth.Data.status -eq "healthy"
$sftpRunning = $sftpHealth.Success -and $sftpHealth.Data.status -eq "healthy"

if ($elixirRunning -and $sftpRunning) {
    Write-Host "All servers are healthy and running" -ForegroundColor Green
    $exitCode = 0
} elseif ($elixirRunning -or $sftpRunning) {
    Write-Host "Some servers are not responding" -ForegroundColor Yellow
    $exitCode = 1
} else {
    Write-Host "All servers are down or unreachable" -ForegroundColor Red
    $exitCode = 2
}

# Function to show log entries with different verbosity levels
function Show-LogsWithVerbosity {
    param(
        [string]$LogPath,
        [string]$LogName,
        [string]$VerbosityLevel = "summary"
    )
    
    if (-not (Test-Path $LogPath)) {
        Write-Host ""
        Write-Host "=== $LogName LOGS ===" -ForegroundColor Yellow
        Write-Host "  Log file not found: $LogPath" -ForegroundColor Red
        return
    }

    try {
        $allContent = Get-Content $LogPath -ErrorAction Stop
        if (-not $allContent) {
            Write-Host ""
            Write-Host "=== $LogName LOGS ===" -ForegroundColor Yellow
            Write-Host "  (Log file is empty)" -ForegroundColor Gray
            return
        }

        $totalLines = $allContent.Count
        
        switch ($VerbosityLevel.ToLower()) {
            "summary" {
                # Show only critical info: errors, warnings, and last few status messages
                $criticalLines = $allContent | Where-Object { 
                    $_ -match "(ERROR|WARN|CRITICAL|FATAL|SUCCESS|FAIL|Started|Stopped|Listening|Connected)" 
                } | Select-Object -Last 3
                
                Write-Host ""
                Write-Host "=== $LogName LOG SUMMARY (Critical events only) ===" -ForegroundColor Yellow
                if ($criticalLines) {
                    $criticalLines | ForEach-Object {
                        Write-Host "  $_" -ForegroundColor Gray
                    }
                } else {
                    $recentLines = $allContent | Select-Object -Last 2
                    $recentLines | ForEach-Object {
                        Write-Host "  $_" -ForegroundColor Gray
                    }
                }
                Write-Host "  [Total log lines: $totalLines]" -ForegroundColor DarkGray
            }
            
            "normal" {
                # Show last 5-8 lines with some context
                $lines = [Math]::Min(8, $totalLines)
                $recentContent = $allContent | Select-Object -Last $lines
                
                Write-Host ""
                Write-Host "=== $LogName RECENT LOGS (Last $lines lines) ===" -ForegroundColor Yellow
                $recentContent | ForEach-Object {
                    Write-Host "  $_" -ForegroundColor Gray
                }
                Write-Host "  [Total log lines: $totalLines]" -ForegroundColor DarkGray
            }
            
            "detailed" {
                # Show more context but still manageable
                $lines = [Math]::Min(15, $totalLines)
                $recentContent = $allContent | Select-Object -Last $lines
                
                Write-Host ""
                Write-Host "=== $LogName DETAILED LOGS (Last $lines lines) ===" -ForegroundColor Yellow
                $recentContent | ForEach-Object {
                    Write-Host "  $_" -ForegroundColor Gray
                }
                Write-Host "  [Total log lines: $totalLines]" -ForegroundColor DarkGray
            }
            
            "verbose" {
                # Show significant portion but cap at reasonable limit
                $lines = [Math]::Min(25, $totalLines)
                $recentContent = $allContent | Select-Object -Last $lines
                
                Write-Host ""
                Write-Host "=== $LogName VERBOSE LOGS (Last $lines lines) ===" -ForegroundColor Yellow
                $recentContent | ForEach-Object {
                    Write-Host "  $_" -ForegroundColor Gray
                }
                Write-Host "  [Total log lines: $totalLines]" -ForegroundColor DarkGray
            }
        }
    }
    catch {
        Write-Host ""
        Write-Host "=== $LogName LOGS ===" -ForegroundColor Yellow
        Write-Host "  Error reading log file: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Determine verbosity level from arguments
$verbosityLevel = "summary"  # Default
if ($args -contains "-detailed" -or $args -contains "-d") {
    $verbosityLevel = "detailed"
} elseif ($args -contains "-normal" -or $args -contains "-n") {
    $verbosityLevel = "normal"
} elseif ($args -contains "-verbose" -or $args -contains "-v") {
    $verbosityLevel = "verbose"
}

# Always show log information for better diagnostics
Write-Host ""
Write-Host "=== LOG INFORMATION ===" -ForegroundColor Magenta

# Define log file paths
$elixirLogPath = Join-Path $projectRoot "logs\elixir_server.log"
$electronLogPath = Join-Path $projectRoot "logs\electron_app.log"

# Show logs based on verbosity level
Show-LogsWithVerbosity -LogPath $elixirLogPath -LogName "ELIXIR SERVER" -VerbosityLevel $verbosityLevel
Show-LogsWithVerbosity -LogPath $electronLogPath -LogName "ELECTRON APP" -VerbosityLevel $verbosityLevel

# Show detailed server status if requested
if ($verbosityLevel -eq "detailed" -or $verbosityLevel -eq "verbose") {
    Write-Host ""
    Write-Host "=== DETAILED SERVER STATUS ===" -ForegroundColor Magenta
    
    if ($elixirHealth.Success) {
        $elixirDetailed = Get-ServerStatus -Url $elixirServerStatus -ServerName "Elixir Server" -Type "status"
        Show-DetailedStatus -StatusResult $elixirDetailed
    }
    
    if ($sftpHealth.Success) {
        $sftpDetailed = Get-ServerStatus -Url $sftpServerStatus -ServerName "SFTP Server" -Type "status"
        Show-DetailedStatus -StatusResult $sftpDetailed
    }
}

Write-Host ""
Write-Host "=== USAGE INFORMATION ===" -ForegroundColor Cyan
Write-Host "Usage: .\utils\check_server_status.ps1 [VERBOSITY_LEVEL]" -ForegroundColor White
Write-Host ""
Write-Host "Verbosity Levels:" -ForegroundColor Yellow
Write-Host "  (default)     Summary mode - Critical events only (minimal output)" -ForegroundColor Gray
Write-Host "  -normal  -n   Normal mode  - Last 8 log lines + status" -ForegroundColor Gray
Write-Host "  -detailed -d  Detailed mode - Last 15 log lines + detailed server status" -ForegroundColor Gray
Write-Host "  -verbose -v   Verbose mode - Last 25 log lines + full diagnostics" -ForegroundColor Gray
Write-Host ""
Write-Host "Examples:" -ForegroundColor Yellow
Write-Host "  .\utils\check_server_status.ps1           # Quick summary" -ForegroundColor Gray
Write-Host "  .\utils\check_server_status.ps1 -normal   # Standard check" -ForegroundColor Gray
Write-Host "  .\utils\check_server_status.ps1 -detailed # Full diagnostics" -ForegroundColor Gray
Write-Host ""
Write-Host "Current verbosity level: $verbosityLevel" -ForegroundColor White
Write-Host ""
Write-Host "Health endpoints:" -ForegroundColor Gray
Write-Host "  Elixir Server: $elixirServerHealth" -ForegroundColor Gray
Write-Host "  SFTP Server:   $sftpServerHealth" -ForegroundColor Gray
Write-Host ""
Write-Host "Project structure:" -ForegroundColor Gray
Write-Host "  Script Dir:    $scriptDir" -ForegroundColor Gray
Write-Host "  Project Root:  $projectRoot" -ForegroundColor Gray

exit $exitCode 