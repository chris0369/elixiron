# Server Status Monitoring

This document describes the health check and status monitoring capabilities for the electro_test project.

## Overview

Both the `elixir_server` and `sftp_server` expose HTTP endpoints for health checking and detailed status information. A PowerShell script is provided to easily check the status of all servers.

## Health Check Endpoints

### Elixir Server (port 4001)
- **Health Check**: `GET http://localhost:4001/health`
- **Detailed Status**: `GET http://localhost:4001/status`
- **Root**: `GET http://localhost:4001/` (basic info)
- **WebSocket**: `GET http://localhost:4001/ws` (WebSocket upgrade)

### SFTP Server (port 2223)
- **Health Check**: `GET http://localhost:2223/health`
- **Detailed Status**: `GET http://localhost:2223/status`
- **Root**: `GET http://localhost:2223/` (basic info)

Note: The SFTP server runs on port 2222 for SFTP protocol, but the health check HTTP server runs on port 2223.

## Status Checking Script

### Usage

```powershell
# Basic health check
.\check_server_status.ps1

# Detailed status information
.\check_server_status.ps1 -detailed
.\check_server_status.ps1 -d
```

### Exit Codes

- `0`: All servers are healthy and running
- `1`: Some servers are not responding
- `2`: All servers are down or unreachable

### Example Output

```
Checking server status...

=== ELIXIR SERVER ===
✓ Elixir Server (health): healthy
  Uptime: 145s
  IPsec: ACTIVE
  SFTP: CONNECTED
  Last check: 2025-01-25T17:15:30.123Z

=== SFTP SERVER ===
✓ SFTP Server (health): healthy
  Uptime: 142s
  IPsec: ACTIVE
  SFTP Server: RUNNING
  Last check: 2025-01-25T17:15:30.456Z

=== SUMMARY ===
✓ All servers are healthy and running
```

## Health Check Response Format

### Basic Health Check (`/health`)

```json
{
  "status": "healthy",
  "service": "elixir_server",
  "timestamp": "2025-01-25T17:15:30.123Z",
  "uptime_seconds": 145,
  "ipsec_status": {
    "status": "active",
    "details": { ... }
  },
  "sftp_connectivity": {
    "status": "connected",
    "message": "SFTP server reachable"
  }
}
```

### Detailed Status (`/status`)

```json
{
  "service": "elixir_server",
  "status": "healthy",
  "timestamp": "2025-01-25T17:15:30.123Z",
  "uptime_seconds": 145,
  "system_info": {
    "erlang_version": "26.2.1",
    "elixir_version": "1.16.0",
    "node_name": "nonode@nohost",
    "memory_usage": { ... },
    "process_count": 156
  },
  "application_info": {
    "websocket_port": 4001,
    "ipsec_enabled": true,
    "security_enforced": true
  },
  "ipsec_status": { ... },
  "sftp_connectivity": { ... },
  "supervisor_status": {
    "supervisor_running": true,
    "children_count": 2,
    "children": [
      {
        "id": "DesktopIntegrationServer.IPsecManager",
        "pid": "#PID<0.123.0>",
        "type": "worker",
        "modules": ["DesktopIntegrationServer.IPsecManager"],
        "status": "running"
      }
    ]
  }
}
```

## Status Information

### IPsec Status
- `active`: IPsec tunnel is established and working
- `error`: IPsec tunnel has an error
- `timeout`: IPsec manager not responding
- `not_running`: IPsec manager process not found

### SFTP Connectivity (Elixir Server)
- `connected`: SFTP server is reachable and responding
- `connection_refused`: SFTP server not reachable (port closed)
- `error`: Other SFTP connection errors

### SFTP Server Status (SFTP Server)
- `running`: SFTP daemon is running and accepting connections
- `error`: SFTP daemon has an error
- `timeout`: SFTP server process not responding
- `not_running`: SFTP server process not found

## Integration with Development Environment

The status checking script complements the `start_dev_env.ps1` script:

1. **Start Environment**: Use `start_dev_env.ps1` to start all servers
2. **Check Status**: Use `check_server_status.ps1` to verify everything is running
3. **Monitor Logs**: Check individual log files in the `logs/` directory
4. **Troubleshoot**: Use detailed status for debugging issues

## Troubleshooting

### Common Issues

1. **Connection Refused**: Server not started or port blocked
   - Check if servers are running
   - Verify firewall settings
   - Check port conflicts

2. **IPsec Not Active**: Tunnel establishment failed
   - Check administrator privileges
   - Verify network configuration
   - Review IPsec logs

3. **SFTP Not Connected**: SFTP server unreachable
   - Verify SFTP server is running on port 2222
   - Check IPsec tunnel status
   - Review SFTP server logs

### Manual Health Checks

You can also check server health manually using curl or PowerShell:

```powershell
# PowerShell
Invoke-RestMethod -Uri "http://localhost:4001/health"
Invoke-RestMethod -Uri "http://localhost:2223/health"

# curl
curl http://localhost:4001/health
curl http://localhost:2223/health
```

## Security Considerations

- Health check endpoints are HTTP (not HTTPS) for development simplicity
- No authentication is required for health checks
- Sensitive configuration details are not exposed in health responses
- IPsec tunnel status is reported but tunnel keys are not exposed

For production deployments, consider:
- Adding authentication to status endpoints
- Using HTTPS for health checks
- Limiting access to health endpoints via firewall rules
- Implementing more granular health check permissions 