# IPsec Tunnel Security Setup Guide

This guide provides a complete setup for secure IPsec tunnel development and deployment between `elixir_server` and `sftp_server`.

## Overview

**Security-First Architecture**: All SFTP file operations use encrypted IPsec tunnels with AES-256 encryption and security enforcement that blocks unencrypted fallback connections.

```
┌─────────────────┐    IPsec Tunnel     ┌─────────────────┐
|  elixir_server  | <=================> |   sftp_server   |
│   127.0.0.1     │   AES-256 Encrypted │   127.0.0.2     │
│   Port: 4001    │                     │   Port: 2222    │
└─────────────────┘                     └─────────────────┘
```

### Security Features

- **AES-256 Encryption**: Industry-standard encryption for data in transit
- **Security Enforcement**: Blocks all SFTP traffic if tunnel fails (default)
- **Pre-shared Key Authentication**: Shared secret authentication
- **Connection Monitoring**: 30-second health checks with automatic recovery
- **Single-Machine Development**: Uses loopback aliases for secure testing

## Quick Start (Development)

### 1. Automated Setup

```powershell
# Starts development environment with IPsec tunnel
.\start_dev_env.ps1
```

**What this does:**
- Configures loopback alias `127.0.0.2` (requires Administrator)
- Cleans and compiles both Elixir projects
- Starts SFTP server and Elixir server with IPsec tunnel
- Launches Electron app

### 2. Manual Setup (Alternative)

```powershell
# Setup tunnel network (run as Administrator)
.\setup_dev_tunnel.ps1

# Start servers manually
cd sftp_server; mix run --no-halt      # Terminal 1
cd elixir_server; mix run --no-halt    # Terminal 2
```

### 3. Verify Security

**Expected logs:**
```
[IPsecManager] Tunnel connectivity test successful (127.0.0.2 reachable)
[SFTPAdapter][ListFiles] [SECURE IPsec Tunnel] Request to list files...
```

## Configuration

### Default Configuration (Single Machine)

**Development defaults use loopback addresses:**

```elixir
# elixir_server (127.0.0.1)
local_ip: "127.0.0.1"
remote_ip: "127.0.0.2" 
local_port: 4001
remote_port: 2222

# sftp_server (127.0.0.2)  
local_ip: "127.0.0.2"
remote_ip: "127.0.0.1"
local_port: 2222
remote_port: 4001
```

### Environment Variables

```powershell
# Basic Configuration
$env:IPSEC_ENABLED="true"              # Enable IPsec tunnel
$env:IPSEC_ENFORCE_SECURITY="true"     # Block if tunnel fails
$env:IPSEC_PSK="your_secure_key"       # Pre-shared key

# Network Configuration (optional)
$env:IPSEC_LOCAL_IP="127.0.0.1"        # This server's IP
$env:IPSEC_REMOTE_IP="127.0.0.2"       # Remote server's IP

# Advanced Configuration (don't change unless needed)
$env:IPSEC_ENCRYPTION="aes256"
$env:IPSEC_HASH="sha256"
$env:IPSEC_DH_GROUP="modp2048"
```

## Production Deployment

### Multi-Machine Setup

```bash
# Machine 1 (elixir_server)
export IPSEC_LOCAL_IP="10.0.100.1"
export IPSEC_REMOTE_IP="10.0.100.2"
export IPSEC_PSK="$(openssl rand -base64 32)"

# Machine 2 (sftp_server)
export IPSEC_LOCAL_IP="10.0.100.2" 
export IPSEC_REMOTE_IP="10.0.100.1"
export IPSEC_PSK="same_key_as_machine_1"

# Start servers
mix run --no-halt
```

### Security Requirements

**Network Configuration:**
- Dedicated tunnel network (e.g., 10.0.100.0/24)
- Firewall blocks direct access to ports 4001, 2222
- Allow IKEv2 traffic (UDP 500, 4500)

**Deployment Checklist:**
- [ ] `IPSEC_ENFORCE_SECURITY=true`
- [ ] Unique PSK per environment
- [ ] Firewall rules configured
- [ ] Tunnel connectivity verified
- [ ] Monitoring alerts enabled

## Troubleshooting

### Common Issues

**ERROR "IPsec tunnel required but not active"**

```powershell
# Check tunnel setup
ipconfig | findstr "127.0.0.2"

# Re-run setup if needed
.\setup_dev_tunnel.ps1

# Check connectivity  
ping 127.0.0.1
ping 127.0.0.2
```

**ERROR "Access denied" (Setup Script)**

```powershell
# Run PowerShell as Administrator
# Right-click PowerShell -> "Run as Administrator"
```

**ERROR File operations fail**

```
# Verify both servers running
# Check logs for [SECURE IPsec Tunnel] vs [SECURITY ENFORCED]
# Ensure PSK matches on both servers
```

### Debug Commands

```elixir
# In Elixir console (iex -S mix)
DesktopIntegrationServer.IPsecManager.tunnel_status()
SftpServer.IPsecManager.tunnel_status()
```

```powershell
# Network connectivity tests
Test-NetConnection -ComputerName 127.0.0.1 -Port 4001
Test-NetConnection -ComputerName 127.0.0.2 -Port 2222

# Verify loopback configuration
netsh interface ipv4 show addresses
```

### Security Monitoring

**Connection Status:**
- `[SECURE IPsec Tunnel]` - SUCCESS Encrypted connection active
- `[SECURITY ENFORCED]` - ERROR Connection blocked (tunnel failed)

## CI/CD Integration

### Docker Development

```dockerfile
FROM elixir:1.15-alpine
RUN apk add --no-cache iproute2 ipsec-tools
RUN ip addr add 127.0.0.2/32 dev lo
```

### GitHub Actions

```yaml
- name: Setup IPsec Test Environment
  run: |
    sudo ip addr add 127.0.0.2/32 dev lo
    sudo sysctl -w net.ipv4.conf.all.forwarding=1
```

### Team Environment

```bash
# .env.example
IPSEC_ENABLED=true
IPSEC_ENFORCE_SECURITY=true
IPSEC_LOCAL_IP=127.0.0.1
IPSEC_REMOTE_IP=127.0.0.2
IPSEC_PSK=team_development_key_2024
```

## API Reference

### IPsec Manager Functions

```elixir
# Check tunnel status
tunnel_status() :: %{active: boolean(), interface_up: boolean(), connectivity: boolean()}

# Manual tunnel control
establish_tunnel() :: :ok | {:error, reason}
teardown_tunnel() :: :ok | {:error, reason}

# Get secure connection parameters
get_secure_connection_params() :: {:ok, params} | {:error, reason}
get_secure_binding_params() :: {:ok, params} | {:error, reason}
```

## Security Best Practices

### Development
- SUCCESS Keep security enforcement enabled
- SUCCESS Use unique PSK per team/environment
- SUCCESS Test with tunnel active (never disable IPsec)
- SUCCESS Monitor security status in logs

### Production  
- SUCCESS Generate unique PSK per deployment
- SUCCESS Use dedicated tunnel network
- SUCCESS Enable network monitoring
- SUCCESS Regular tunnel health checks
- SUCCESS Firewall rules blocking direct access

---

**WARNING - SECURITY NOTICE**: When `enforce_security` is enabled (default), ALL SFTP traffic will be blocked if the IPsec tunnel is not active. This prevents accidental data transmission over unencrypted connections. 