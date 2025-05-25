# SFTP Server

A production-ready SFTP server implementation in Elixir.

**Note:** Currently, this server is configured to allow connections without password authentication (anonymous access). User management and authentication features are temporarily removed.

## Features

- Configurable port and base directory
- Full SFTP protocol support (file upload, download, directory listing, etc.)
- Environment-based configuration
- Supervisor-managed processes for reliability

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd sftp_server

# Get dependencies
mix deps.get

# Compile
mix compile
```

## Configuration

The server can be configured through environment variables:

- `SFTP_PORT`: Port number (default: 2222)
- `SFTP_BASE_PATH`: Base directory for SFTP operations (SFTP root for connected users)
- `SFTP_SYSTEM_DIR`: SSH system directory (for host keys, default: `priv/sftp_server/system_keys` relative to project root)
- `SFTP_USER_DIR`: Default user directory (SFTP home, currently not strictly enforced without user-specific auth, default: `priv/sftp_server/user_home_template` relative to project root)

For development, defaults are provided. For production, these environment variables are recommended.

## Usage

### Development

Ensure the `priv/sftp_server/system_keys` and `priv/sftp_server/user_home_template` directories exist.

```bash
# Start the server in development mode
mix run --no-halt
```

### Production

```bash
# Set required environment variables
export SFTP_PORT=2222
export SFTP_BASE_PATH=/path/to/sftp/root
export SFTP_SYSTEM_DIR=/path/to/system_keys # Ensure this is secure and persistent
export SFTP_USER_DIR=/path/to/user/home_template # Ensure this is secure and persistent

# Start the server in production mode
MIX_ENV=prod mix run --no-halt
```

### Managing Users

User management and password authentication are currently not implemented. The server will allow connections from any user (anonymous).

## Client Connection

Connect using any SFTP client. Since there's no password authentication, any username/password might be accepted by the client, but the server won't validate them.

```bash
sftp -P 2222 some_username@localhost
```

## Security Considerations

1.  **ANONYMOUS ACCESS**: As currently configured, this server allows anonymous SFTP access. This is NOT secure for production environments unless this is the explicit desired behavior for a public-access read-only (or controlled write) SFTP server.
2.  In production:
    *   Set up proper SSH host keys in a persistent and secure `SFTP_SYSTEM_DIR`.
    *   Configure firewall rules.
    *   Use secure file permissions for `SFTP_BASE_PATH` and any user-specific directories if you extend this.
    *   Monitor access logs.
    *   **Implement proper authentication before exposing to untrusted networks.**

## License

[Your License]

