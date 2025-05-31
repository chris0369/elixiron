# Elixir Server <-> Electron Integration

This document outlines how the Elixir backend (`DesktopIntegrationServer`) interacts with the Electron frontend using a simplified WebSocket setup with integrated IPsec security.

## Communication Protocol

- **Transport:** WebSocket
- **Endpoint Path:** `/ws` (Simplified, no dynamic channel ID in path)
- **Default Port:** `4001` (Configurable via `WEBSOCKET_PORT` environment variable in `config/runtime.exs` for releases)
- **Format:** JSON encoded Text Messages (UTF-8)
- **Security:** IPsec encrypted tunnel to SFTP server for file operations

## Architecture Overview

```
┌─────────────────┐    WebSocket     ┌─────────────────┐
| Electron Client | <============> | Elixir Server   |
│                 │                 │ (10.0.100.1)    │
└─────────────────┘                 └─────────────────┘
                                             │
                                             │ IPsec Tunnel
                                             │ (Encrypted)
                                             ▼
                                    ┌─────────────────┐
                                    │  SFTP Server    │
                                    │ (10.0.100.2)    │
                                    └─────────────────┘
```

## Configuration Management

**WARNING - SIMPLIFIED APPROACH**: Single configuration file with environment variable overrides.

### Configuration Files

- **`config/config.exs`** - Static configuration with secure defaults
- **`config/runtime.exs`** - Runtime environment variable overrides  
- **No environment-specific configs** (dev.exs, prod.exs) for simplicity

### IPsec Security Configuration

**Secure by Default:**
```elixir
# config/config.exs - DEFAULT VALUES
config :desktop_integration_server, :ipsec_tunnel,
  enabled: System.get_env("IPSEC_ENABLED", "true") == "true",           # ENABLED
  enforce_security: System.get_env("IPSEC_ENFORCE_SECURITY", "true") == "true", # ENFORCED
  local_ip: System.get_env("IPSEC_LOCAL_IP", "10.0.100.1"),
  remote_ip: System.get_env("IPSEC_REMOTE_IP", "10.0.100.2"),
  psk: System.get_env("IPSEC_PSK", "elixir_sftp_tunnel_key_2024")
```

**Environment Variable Override:**
```powershell
# For testing only - disable security
$env:IPSEC_ENABLED="false"
$env:IPSEC_ENFORCE_SECURITY="false"

# Custom tunnel configuration
$env:IPSEC_LOCAL_IP="192.168.1.100"
$env:IPSEC_REMOTE_IP="192.168.1.101"
$env:IPSEC_PSK="my_secure_key"
```

## Security Features

### IPsec Tunnel Security

1. **Automatic Tunnel Establishment**:
   - IPsec manager starts with application
   - Creates encrypted tunnel to SFTP server
   - Uses AES-256 encryption and SHA-256 integrity

2. **Security Enforcement**:
   - **Default**: Blocks all SFTP traffic if tunnel fails
   - **Testing Mode**: Allows fallback with warnings
   - **Production**: Always enforced (recommended)

3. **Connection Monitoring**:
   - 30-second tunnel health checks
   - Automatic recovery attempts
   - Detailed security logging

### Security Modes

```elixir
# Secure Mode (DEFAULT) - enforce_security: true
# - Blocks connections if IPsec tunnel fails
# - No fallback to unencrypted connections
# - Recommended for all deployments

# Testing Mode - enforce_security: false  
# - Falls back to standard SFTP if tunnel fails
# - Logs security warnings
# - Only for debugging/development
```

## Server-Side Implementation (`DesktopIntegrationServer.WebSocketHandler`)

- The server listens for incoming WebSocket connections on the configured port and the fixed `/ws` path. It is designed to handle multiple concurrent connections from different clients. Cowboy, the underlying web server, typically manages each connection in a separate lightweight Erlang process, allowing for high concurrency.
- The connection is initiated via an HTTP GET request to `/ws` which is then upgraded by the `DesktopIntegrationServer.Router` using `Plug.Conn.upgrade_adapter/3`.
- The `DesktopIntegrationServer.WebSocketHandler` module implements the `:cowboy_websocket` behaviour.

### WebSocket Handler Implementation

#### Required Callbacks

The handler must implement all required `:cowboy_websocket` callbacks:

```elixir
defmodule DesktopIntegrationServer.WebSocketHandler do
  @behaviour :cowboy_websocket
  require Logger

  # HTTP Process - called during WebSocket upgrade
  def init(req, opts_from_router) do
    # Must return this specific tuple to upgrade to WebSocket
    {:cowboy_websocket, req, initial_state}
  end

  # WebSocket Process - CRITICAL callback for state initialization
  def websocket_init(state_from_init) do
    # This runs in the WebSocket process (different from HTTP process)
    # Always create fresh state here - don't rely on state from init/2
    websocket_state = %{
      client_id: :erlang.unique_integer([:positive]),
      initialized_at: DateTime.utc_now(),
      pid: inspect(self())
    }
    {:ok, websocket_state}
  end

  # Handle incoming WebSocket frames
  def websocket_handle(frame, state) do
    # state is guaranteed to be the one returned from websocket_init/1
    {:reply, {:text, response}, state}
  end

  # Handle Erlang messages sent to this process
  def websocket_info(info, state) do
    {:ok, state}
  end

  # Optional cleanup callback
  def terminate(reason, state) do
    :ok
  end
end
```

#### Critical Implementation Notes

**WARNING - MUST HAVE `websocket_init/1`**
- Without this callback, `websocket_handle/2` receives `nil` state
- This is the #1 cause of WebSocket handler crashes

**Process Architecture**
```
HTTP Request -> init/2 (HTTP Process) -> Upgrade -> websocket_init/1 (WebSocket Process) -> websocket_handle/2
```
- `init/2` runs in HTTP request process
- `websocket_*` callbacks run in separate WebSocket connection process
- State may not transfer reliably between processes

**Return Value Requirements**
- `init/2` -> `{:cowboy_websocket, req, state}` (NOT `{:ok, req, state}`)
- `websocket_init/1` -> `{:ok, state}`
- `websocket_handle/2` -> `{:reply, frame, state}` or `{:ok, state}`

### Message Handling

#### Connection Initiation (`websocket_init/1`)
- When a new client connects, a unique `:client_id` is generated for that specific session.
- State is properly initialized in the WebSocket process.
- IPsec tunnel status is verified for secure file operations.

#### File Operations (`websocket_handle/2`)
The server supports secure file operations via JSON messages:

**List Files Request:**
```json
{
  "action": "list_files", 
  "path": "/some/directory"
}
```

**List Files Response:**
```json
{
  "type": "file_list_response",
  "path": "/some/directory", 
  "files": ["file1.txt", "file2.pdf"]
}
```

**Security Enforcement:**
- All file operations use IPsec encrypted tunnel
- Connections blocked if tunnel inactive (when enforcement enabled)
- Security status logged: `[SECURE IPsec Tunnel]` or `[Standard Connection]`

#### Echo Messages
- Receives text messages from the Electron client.
- Logs the received message.
- Echoes the message back to the client, wrapped in a JSON structure:
  `%{type: "echo_response", payload: original_message, server_note: "Elixir says hello!"}`

### State Management
The `state` term in the WebSocket handler holds a unique `:client_id` for logging and session identification. File operations delegate to the `FileStorage` module which handles secure SFTP connections via IPsec tunnels.

## Client-Side Expectations (Electron App)

- The Electron app should connect to `ws://127.0.0.1:4001/ws`.
- Upon connection, the WebSocket is ready to handle messages immediately.
- **File Operations**: Send JSON requests for file operations (list_files, upload, download).
- **Echo Messages**: Can send plain text or JSON for general communication.
- **Security**: All file operations are automatically secured via IPsec tunnel.

### Expected Message Formats

**File List Request:**
```javascript
websocket.send(JSON.stringify({
  action: "list_files",
  path: "."  // or specific directory
}));
```

**Echo Request:**
```javascript
websocket.send("Hello from Electron!");
// or JSON
websocket.send(JSON.stringify({message: "Hello"}));
```

## Deployment and Security

### Standard Deployment (Secure)
```powershell
# Terminal 1: Start SFTP server
cd sftp_server
mix run --no-halt

# Terminal 2: Start Elixir server  
cd elixir_server
mix run --no-halt

# Both servers establish IPsec tunnel automatically
# File operations use encrypted channel
```

### Testing Deployment (Insecure)
```powershell
# Disable security enforcement for testing only
$env:IPSEC_ENFORCE_SECURITY="false"

# Or disable IPsec entirely
$env:IPSEC_ENABLED="false"

mix run --no-halt
```

## Troubleshooting

### Common Issues

**ERROR "Invalid or missing state in websocket_handle"**
- **Cause:** Missing `websocket_init/1` callback
- **Solution:** Implement `websocket_init/1` that returns `{:ok, state}`

**ERROR WebSocket upgrade fails silently**
- **Cause:** `init/2` returns `{:ok, req, state}` instead of `{:cowboy_websocket, req, state}`
- **Solution:** Use correct return tuple for WebSocket upgrade

**ERROR State is always `nil`**
- **Cause:** Relying on state from `init/2` instead of initializing in `websocket_init/1`
- **Solution:** Always create fresh state in `websocket_init/1`

### Security-Related Issues

**ERROR "IPsec tunnel required but not active"**
- **Cause:** IPsec tunnel failed but security enforcement enabled
- **Solution:** 
  - Ensure `sftp_server` is running and reachable
  - Check tunnel IP configuration
  - For testing: Set `IPSEC_ENFORCE_SECURITY=false`

**ERROR File operations return "Connection blocked for security"**
- **Cause:** Security enforcement preventing unencrypted fallback
- **Solution:**
  - Verify both servers have matching IPsec configuration
  - Check PSK (pre-shared key) matches
  - Ensure tunnel IPs are reachable

### Debugging Steps

1. **Check callback implementation:**
   ```bash
   grep -n "def websocket_init" lib/your_handler.ex
   ```

2. **Verify return values:**
   - `init/2` logs should show "Upgrading to WebSocket"
   - `websocket_init/1` logs should show "WebSocket ready with client_id: X"

3. **Check IPsec tunnel status:**
   - Look for `[IPsecManager]` log entries
   - Verify tunnel establishment success
   - Check for security enforcement messages

4. **Test connection flow:**
   - Router receives WebSocket upgrade request
   - HTTP init/2 is called
   - WebSocket process is initialized
   - Messages are handled without error recovery

## Best Practices

### Server-Side Security
- **Always enable IPsec** for production deployments
- **Keep security enforcement enabled** (`enforce_security: true`)
- **Use unique PSK** for each deployment environment
- **Monitor tunnel health** via application logs
- **Never disable security** in production

### WebSocket Implementation
- **Always implement `websocket_init/1`:** This is not optional for reliable WebSocket handling
- **Initialize state properly:** Create fresh state in `websocket_init/1`, don't rely on `init/2` state
- **Use correct return values:** Follow Cowboy WebSocket callback specifications exactly
- **Keep Handlers Lean:** The `WebSocketHandler` should ideally delegate complex business logic to separate modules if functionality grows.
- **Structured Data:** Using JSON for messages (as implemented) is good practice for clear contracts.
- **Error Handling:** Robust error handling within the WebSocket handler or delegated modules remains important. Consider replying with specific error messages if needed.

### Configuration Management
- **Single config.exs file** with secure defaults
- **Environment variables** for deployment-specific overrides
- **No environment-specific configs** (dev.exs, prod.exs) for simplicity
- **Document security implications** of configuration changes 