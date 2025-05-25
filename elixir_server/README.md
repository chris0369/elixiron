# Elixir WebSocket Server (Desktop Integration Backend)

This directory contains the Elixir/Mix project that provides the backend logic and WebSocket server for the Electron desktop application.

## Functionality

- Starts an HTTP server using Plug/Cowboy.
- Handles WebSocket connections on `/ws`.
- Provides secure file operations via SFTP with IPsec tunnel encryption.
- Listens for text messages on the WebSocket and processes file operations (list_files, etc.).
- The listening port is configurable via the `WEBSOCKET_PORT` environment variable (defaults to `4001`) using `config/runtime.exs` when run from a release.

## Security Features

**⚠️ SECURE BY DEFAULT**: This server implements IPsec tunneling with security enforcement:

- **IPsec Tunneling**: Encrypted communication channel to SFTP server (10.0.100.1 ↔ 10.0.100.2)
- **Security Enforcement**: Blocks all SFTP connections if encryption tunnel fails
- **AES-256 Encryption**: Industry-standard encryption for data in transit
- **Pre-shared Key Authentication**: Shared secret authentication between servers

### Default Security Configuration

```elixir
# IPsec is ENABLED and ENFORCED by default
enabled: true              # IPsec tunnel is active
enforce_security: true     # Block connections if tunnel fails
```

**To disable security for testing only:**
```powershell
$env:IPSEC_ENABLED="false"
$env:IPSEC_ENFORCE_SECURITY="false"
```

## Prerequisites

- [Elixir](https://elixir-lang.org/install.html) (v1.12+)
- [Erlang/OTP](https://www.erlang.org/downloads) (Compatible with your Elixir version)
- **SFTP Server**: Companion `sftp_server` must be running for file operations

## Setup

From the *root* project directory (`electro_test`), run:

```bash
cd elixir_server
mix deps.get
```

## Running

### Standard Secure Deployment

From within the `elixir_server` directory, run:

```bash
mix run --no-halt
```

This will:
1. Compile the project
2. Start the IPsec tunnel manager
3. Establish encrypted tunnel to SFTP server
4. Start the WebSocket server on port `4001`
5. **Block connections if tunnel fails** (secure by default)

### Configuration via Environment Variables

```powershell
# IPsec Configuration
$env:IPSEC_ENABLED="true"                    # Enable IPsec tunnel
$env:IPSEC_ENFORCE_SECURITY="true"          # Block if tunnel fails
$env:IPSEC_LOCAL_IP="10.0.100.1"           # This server's tunnel IP
$env:IPSEC_REMOTE_IP="10.0.100.2"          # SFTP server's tunnel IP
$env:IPSEC_PSK="your_secure_key_here"       # Pre-shared key

# Server Configuration  
$env:WEBSOCKET_PORT="4001"                  # WebSocket server port

mix run --no-halt
```

Keep this process running while using the Electron application.

## Configuration Management

**Simplified Configuration Approach:**
- `config/config.exs` - Static configuration with secure defaults
- `config/runtime.exs` - Runtime environment variable overrides
- **No environment-specific configs** (dev.exs, prod.exs) for simplicity
- **All configuration via environment variables when needed**

### Key Configuration Files

#### config/config.exs (Secure Defaults)
```elixir
# IPsec tunnel configuration - SECURE BY DEFAULT
config :desktop_integration_server, :ipsec_tunnel,
  enabled: System.get_env("IPSEC_ENABLED", "true") == "true",
  enforce_security: System.get_env("IPSEC_ENFORCE_SECURITY", "true") == "true",
  local_ip: System.get_env("IPSEC_LOCAL_IP", "10.0.100.1"),
  remote_ip: System.get_env("IPSEC_REMOTE_IP", "10.0.100.2"),
  psk: System.get_env("IPSEC_PSK", "elixir_sftp_tunnel_key_2024")
```

#### config/runtime.exs (Runtime Overrides)
```elixir
# Dynamic port configuration for releases
websocket_port = System.get_env("PORT", "4001") |> String.to_integer()
config :desktop_integration_server, :websocket_port, websocket_port
```

## WebSocket Implementation Notes

This server implements the `:cowboy_websocket` behavior. Key implementation details:

### Required Callbacks

The WebSocket handler must implement these callbacks:

1. **`init/2`** - HTTP process callback that upgrades to WebSocket
   - Must return `{:cowboy_websocket, req, state}` 
   - Runs in HTTP request process

2. **`websocket_init/1`** - WebSocket process initialization ⚠️ **CRITICAL**
   - Called after WebSocket upgrade in a separate process
   - Must return `{:ok, state}` 
   - Always initialize fresh state here, don't rely on state from `init/2`

3. **`websocket_handle/2`** - Handles incoming WebSocket frames
4. **`websocket_info/2`** - Handles Erlang messages sent to WebSocket process

### Common Pitfalls

❌ **Missing `websocket_init/1`** - Without this callback, WebSocket handlers receive `nil` state
❌ **Wrong return values** - `init/2` must return `{:cowboy_websocket, req, state}`, not `{:ok, req, state}`
❌ **Relying on `init/2` state** - State from HTTP process may not transfer correctly

### Architecture

```
HTTP Request → init/2 (HTTP Process) → WebSocket Upgrade → websocket_init/1 (WebSocket Process) → websocket_handle/2
```

The HTTP and WebSocket processes are separate, so always initialize WebSocket state in `websocket_init/1`.

## Security Architecture

```
┌─────────────────┐    IPsec Tunnel     ┌─────────────────┐
│  elixir_server  │ ←══════════════════→ │   sftp_server   │
│  (10.0.100.1)   │   Encrypted Channel  │  (10.0.100.2)   │
│  Port: 4001     │                     │  Port: 2222     │
└─────────────────┘                     └─────────────────┘
```

### Security Modes

1. **Secure Mode (enforce_security: true)** - **DEFAULT**
   - Blocks all SFTP traffic if IPsec tunnel fails
   - Prevents accidental unencrypted data transmission
   - **Recommended for all deployments**

2. **Testing Mode (enforce_security: false)**
   - Falls back to unencrypted connections if IPsec fails
   - Logs security warnings
   - **Only for debugging/testing**

## Troubleshooting

### Security Enforcement Errors

**Error: IPsec tunnel required but not active**
```
[SFTPAdapter] SECURITY ENFORCED: IPsec tunnel not active, blocking connection
```
**Solutions:**
- Ensure `sftp_server` is running and reachable
- Check IPsec tunnel status in logs
- Verify network connectivity between tunnel IPs
- For testing only: Set `IPSEC_ENFORCE_SECURITY=false`

### Common Issues

**❌ WebSocket state is `nil`**
- **Cause:** Missing `websocket_init/1` callback
- **Solution:** Implement proper WebSocket initialization

**❌ SFTP connection blocked**
- **Cause:** IPsec tunnel not established (secure by default)
- **Solution:** Ensure both servers running with matching IPsec config

**❌ File operations fail**
- **Cause:** SFTP server not running or tunnel authentication failure
- **Solution:** Start `sftp_server` and verify PSK matches

## Integration with SFTP Server

This server requires the companion `sftp_server` to be running for file operations:

1. **Start SFTP server first**: `cd ../sftp_server && mix run --no-halt`
2. **Start Elixir server**: `mix run --no-halt`
3. **Both establish IPsec tunnel automatically**
4. **File operations use secure encrypted channel**

See `../sftp_server/README.md` for SFTP server setup instructions. 