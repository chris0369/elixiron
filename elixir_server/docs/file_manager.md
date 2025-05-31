# FileManager Module Documentation

## Overview

The `DesktopIntegrationServer.FileManager` module provides a high-level, comprehensive file management interface for SFTP servers. It offers atomic CRUD operations, transaction-like batch processing, and seamless integration with the existing IPsec tunnel security infrastructure.

## Architecture

```
┌─────────────────────┐    Uses    ┌─────────────────────┐    Uses    ┌─────────────────────┐
|   FileManager       | --------> |   FileStorage       | --------> |   SFTPAdapter       |
│ (High-level CRUD)   │           │ (Adapter Pattern)   │           │ (SFTP Implementation)│
└─────────────────────┘           └─────────────────────┘           └─────────────────────┘
                                                                              │
                                                                              ▼
                                                                    ┌─────────────────────┐
                                                                    │   IPsec Tunnel      │
                                                                    │ (Secure Transport)  │
                                                                    └─────────────────────┘
```

## Key Features

### 🔒 **Security by Default**
- All operations use IPsec encrypted tunnels
- No fallback to unencrypted connections
- Automatic security enforcement

### **Atomic Operations**
- File operations are atomic where possible
- Automatic backup creation for updates
- Rollback support for batch operations

### **Batch Processing**
- Multiple operations in a single transaction
- Automatic rollback on failure
- Configurable operation limits

### **Safety Features**
- Path validation and sanitization
- File size limits for read operations
- Overwrite protection (configurable)
- Automatic parent directory creation

## API Reference

### CREATE Operations

#### `create_file/3`
Creates a new file with specified content.

```elixir
# Basic file creation
{:ok, path} = FileManager.create_file("/home/user/test.txt", "Hello World")

# With options
{:ok, path} = FileManager.create_file("/home/user/config.json", 
  Jason.encode!(%{key: "value"}), 
  overwrite: true, 
  create_dirs: true
)
```

**Options:**
- `:overwrite` - Whether to overwrite existing files (default: false)
- `:create_dirs` - Whether to create parent directories (default: true)
- `:mode` - File permissions (default: 0o644)

#### `create_directory/2`
Creates a new directory.

```elixir
# Create directory with parents
{:ok, path} = FileManager.create_directory("/home/user/projects/new_project")

# Create single directory only
{:ok, path} = FileManager.create_directory("/home/user/temp", recursive: false)
```

**Options:**
- `:recursive` - Whether to create parent directories (default: true)
- `:mode` - Directory permissions (default: 0o755)

### READ Operations

#### `read_file/2`
Reads file content from the remote server.

```elixir
# Read as UTF-8 text
{:ok, content} = FileManager.read_file("/home/user/document.txt")

# Read as binary
{:ok, binary} = FileManager.read_file("/home/user/image.png", encoding: :binary)

# With size limit
{:ok, content} = FileManager.read_file("/home/user/large_file.txt", max_size: 1024 * 1024)
```

**Options:**
- `:encoding` - Content encoding (`:utf8`, `:binary`) (default: `:utf8`)
- `:max_size` - Maximum file size in bytes (default: 10MB)

#### `list_files/2`
Lists files and directories with optional detailed information.

```elixir
# Simple file listing
{:ok, files} = FileManager.list_files("/home/user", detailed: false)
# Returns: ["file1.txt", "file2.pdf", "subdirectory"]

# Detailed file listing
{:ok, files} = FileManager.list_files("/home/user", detailed: true)
# Returns: [%{name: "file1.txt", type: :file, size: 1024, ...}, ...]

# With filtering and sorting
{:ok, files} = FileManager.list_files("/home/user", 
  detailed: true,
  filter: &(&1.type == :file),
  sort_by: :size
)
```

**Options:**
- `:detailed` - Include detailed file information (default: true)
- `:recursive` - List subdirectories recursively (default: false)
- `:filter` - Filter function for files (default: nil)
- `:sort_by` - Sort criteria (`:name`, `:size`, `:modified`) (default: `:name`)

#### `get_file_info/1`
Gets detailed information about a specific file or directory.

```elixir
{:ok, info} = FileManager.get_file_info("/home/user/document.txt")
# Returns: %{
#   name: "document.txt",
#   type: :file,
#   size: 2048,
#   modified: ~U[2024-01-15 10:30:00Z],
#   permissions: "644",
#   path: "/home/user/document.txt"
# }
```

### UPDATE Operations

#### `update_file/3`
Updates the content of an existing file.

```elixir
# Update with automatic backup
{:ok, path} = FileManager.update_file("/home/user/config.json", new_content)

# Update without backup
{:ok, path} = FileManager.update_file("/home/user/temp.txt", new_content, backup: false)

# Non-atomic update (faster but less safe)
{:ok, path} = FileManager.update_file("/home/user/large.txt", new_content, atomic: false)
```

**Options:**
- `:backup` - Create backup before updating (default: true)
- `:atomic` - Use atomic update (temp file + rename) (default: true)

#### `move_file/3`
Moves or renames a file or directory.

```elixir
# Simple move
{:ok, new_path} = FileManager.move_file("/home/user/old.txt", "/home/user/new.txt")

# Move with overwrite
{:ok, new_path} = FileManager.move_file("/home/user/file.txt", "/backup/file.txt", 
  overwrite: true,
  create_dirs: true
)
```

**Options:**
- `:overwrite` - Whether to overwrite destination (default: false)
- `:create_dirs` - Whether to create parent directories (default: true)

#### `copy_file/3`
Copies a file to a new location.

```elixir
# Simple copy
{:ok, dest_path} = FileManager.copy_file("/home/user/source.txt", "/backup/source.txt")

# Copy with options
{:ok, dest_path} = FileManager.copy_file("/home/user/important.txt", "/backup/important.txt",
  overwrite: false,
  create_dirs: true
)
```

### DELETE Operations

#### `delete_file/2`
Deletes a file from the remote server.

```elixir
# Simple deletion
{:ok, deleted_path} = FileManager.delete_file("/home/user/temp.txt")

# Delete with backup
{:ok, deleted_path} = FileManager.delete_file("/home/user/important.txt", backup: true)
```

**Options:**
- `:backup` - Create backup before deletion (default: false)
- `:force` - Force deletion without confirmation (default: true)

#### `delete_directory/2`
Deletes a directory from the remote server.

```elixir
# Delete empty directory
{:ok, deleted_path} = FileManager.delete_directory("/home/user/empty_dir")

# Recursive deletion
{:ok, deleted_path} = FileManager.delete_directory("/home/user/project", recursive: true)
```

**Options:**
- `:recursive` - Delete directory contents recursively (default: false)
- `:force` - Force deletion without confirmation (default: false)

### BATCH Operations

#### `batch_operations/1`
Performs multiple operations atomically with rollback support.

```elixir
operations = [
  {:create_file, "/home/user/file1.txt", "Content 1", []},
  {:create_file, "/home/user/file2.txt", "Content 2", []},
  {:move_file, "/home/user/old.txt", "/home/user/moved.txt", []},
  {:delete_file, "/home/user/temp.txt", []}
]

case FileManager.batch_operations(operations) do
  {:ok, results} -> 
    IO.puts("All operations completed successfully")
  {:error, {failed_op, partial_results}} -> 
    IO.puts("Operation failed: #{inspect(failed_op)}")
    IO.puts("Partial results: #{inspect(partial_results)}")
    # Previous operations have been rolled back
end
```

**Supported Operations:**
- `{:create_file, path, content, opts}`
- `{:update_file, path, content, opts}`
- `{:delete_file, path, opts}`
- `{:move_file, source, dest, opts}`
- `{:copy_file, source, dest, opts}`

### UTILITY Operations

#### `exists?/1`
Checks if a file or directory exists.

```elixir
case FileManager.exists?("/home/user/maybe_exists.txt") do
  {:ok, true} -> IO.puts("File exists")
  {:ok, false} -> IO.puts("File does not exist")
  {:error, reason} -> IO.puts("Error checking: #{inspect(reason)}")
end
```

#### `get_directory_size/1`
Calculates the total size of a directory including subdirectories.

```elixir
{:ok, size_bytes} = FileManager.get_directory_size("/home/user/projects")
IO.puts("Directory size: #{size_bytes} bytes")
```

## WebSocket Integration

The FileManager is fully integrated with the WebSocket API, providing the following actions:

### File Operations
```javascript
// Create file
websocket.send(JSON.stringify({
  action: "create_file",
  path: "/home/user/test.txt",
  content: "Hello World"
}));

// Read file
websocket.send(JSON.stringify({
  action: "read_file",
  path: "/home/user/test.txt"
}));

// Update file
websocket.send(JSON.stringify({
  action: "update_file",
  path: "/home/user/test.txt",
  content: "Updated content"
}));

// Delete file
websocket.send(JSON.stringify({
  action: "delete_file",
  path: "/home/user/test.txt"
}));

// Move file
websocket.send(JSON.stringify({
  action: "move_file",
  source: "/home/user/old.txt",
  destination: "/home/user/new.txt"
}));

// Copy file
websocket.send(JSON.stringify({
  action: "copy_file",
  source: "/home/user/source.txt",
  destination: "/home/user/copy.txt"
}));
```

### Directory Operations
```javascript
// Create directory
websocket.send(JSON.stringify({
  action: "create_directory",
  path: "/home/user/new_folder"
}));

// Delete directory
websocket.send(JSON.stringify({
  action: "delete_directory",
  path: "/home/user/old_folder",
  recursive: true
}));

// List files
websocket.send(JSON.stringify({
  action: "list_files",
  path: "/home/user"
}));

// Get file info
websocket.send(JSON.stringify({
  action: "get_file_info",
  path: "/home/user/document.txt"
}));
```

### Batch Operations
```javascript
websocket.send(JSON.stringify({
  action: "batch_operations",
  operations: [
    {
      type: "create_file",
      path: "/home/user/file1.txt",
      content: "Content 1"
    },
    {
      type: "create_file", 
      path: "/home/user/file2.txt",
      content: "Content 2"
    },
    {
      type: "move_file",
      source: "/home/user/old.txt",
      destination: "/home/user/moved.txt"
    }
  ]
}));
```

## Configuration

The FileManager can be configured via environment variables or `config/config.exs`:

```elixir
# config/config.exs
config :desktop_integration_server, DesktopIntegrationServer.FileManager,
  # Default operation settings
  default_file_permissions: "644",
  default_directory_permissions: "755",
  
  # Safety and limits
  max_file_size_mb: 100,
  max_batch_operations: 50,
  enable_backups: true,
  
  # Temporary file management
  temp_file_prefix: "filemanager",
  temp_file_cleanup_interval_ms: 300_000, # 5 minutes
  
  # Operation timeouts
  operation_timeout_ms: 60_000,      # 1 minute
  batch_operation_timeout_ms: 300_000 # 5 minutes
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FILE_MANAGER_DEFAULT_PERMISSIONS` | `"644"` | Default file permissions |
| `FILE_MANAGER_DEFAULT_DIR_PERMISSIONS` | `"755"` | Default directory permissions |
| `FILE_MANAGER_MAX_FILE_SIZE_MB` | `100` | Maximum file size for read operations |
| `FILE_MANAGER_MAX_BATCH_OPS` | `50` | Maximum operations in a batch |
| `FILE_MANAGER_ENABLE_BACKUPS` | `"true"` | Enable automatic backups |
| `FILE_MANAGER_TEMP_PREFIX` | `"filemanager"` | Prefix for temporary files |
| `FILE_MANAGER_CLEANUP_INTERVAL_MS` | `300000` | Temp file cleanup interval |
| `FILE_MANAGER_OPERATION_TIMEOUT_MS` | `60000` | Per-operation timeout |
| `FILE_MANAGER_BATCH_TIMEOUT_MS` | `300000` | Batch operation timeout |

## Security Features

### IPsec Tunnel Integration
- All SFTP operations automatically use the established IPsec tunnel
- No configuration required - security is transparent
- Connections blocked if tunnel is unavailable (when enforcement enabled)

### Path Validation
- All paths are validated before operations
- Protection against path traversal attacks
- Automatic path sanitization

### File Size Limits
- Configurable maximum file sizes for read operations
- Protection against memory exhaustion
- Graceful handling of oversized files

### Backup Protection
- Automatic backup creation for destructive operations
- Timestamped backup files
- Configurable backup behavior

## Error Handling

The FileManager provides comprehensive error handling with detailed error messages:

```elixir
case FileManager.create_file("/invalid/path/file.txt", "content") do
  {:ok, path} -> 
    IO.puts("Success: #{path}")
  {:error, :invalid_path} -> 
    IO.puts("Invalid path provided")
  {:error, :file_exists} -> 
    IO.puts("File already exists and overwrite is disabled")
  {:error, :enoent} -> 
    IO.puts("Parent directory does not exist")
  {:error, reason} -> 
    IO.puts("Operation failed: #{inspect(reason)}")
end
```

### Common Error Codes
- `:invalid_path` - Path validation failed
- `:file_exists` - File exists and overwrite disabled
- `:enoent` - File or directory not found
- `:eacces` - Permission denied
- `:file_too_large` - File exceeds size limit
- `:econnrefused` - SFTP server not reachable

## Performance Considerations

### Atomic Operations
- Atomic updates use temporary files and rename operations
- Slightly slower but much safer for important files
- Can be disabled for performance-critical operations

### Batch Operations
- More efficient than individual operations
- Automatic rollback adds overhead but ensures consistency
- Configurable batch size limits

### Temporary Files
- Local temporary files used for content operations
- Automatic cleanup prevents disk space issues
- Configurable cleanup intervals

## Best Practices

### File Operations
1. **Use atomic updates** for important files
2. **Enable backups** for destructive operations
3. **Validate paths** before operations
4. **Handle errors gracefully** in client code

### Batch Operations
1. **Group related operations** for better performance
2. **Keep batch sizes reasonable** (< 50 operations)
3. **Handle partial failures** appropriately
4. **Use transactions** for critical operations

### Security
1. **Never disable IPsec enforcement** in production
2. **Validate user input** before file operations
3. **Use appropriate file permissions**
4. **Monitor operation logs** for security events

## Troubleshooting

### Common Issues

**File operations fail with "IPsec tunnel required"**
- Ensure both elixir_server and sftp_server are running
- Check IPsec tunnel status in logs
- Verify tunnel configuration matches between servers

**Batch operations partially complete**
- Check individual operation errors in response
- Verify file permissions and paths
- Ensure sufficient disk space on SFTP server

**File reads fail with "file too large"**
- Increase `max_file_size_mb` configuration
- Use streaming for very large files
- Consider file compression

### Debug Logging
Enable debug logging to troubleshoot issues:

```elixir
# config/config.exs
config :logger, level: :debug
```

Look for log entries with `[FileManager]` prefix for detailed operation information.

## Integration Examples

### Electron App Integration
```javascript
class FileManagerClient {
  constructor(websocket) {
    this.ws = websocket;
  }

  async createFile(path, content) {
    return new Promise((resolve, reject) => {
      const message = {
        action: "create_file",
        path: path,
        content: content
      };
      
      this.ws.send(JSON.stringify(message));
      
      this.ws.once('message', (data) => {
        const response = JSON.parse(data);
        if (response.success) {
          resolve(response.path);
        } else {
          reject(new Error(response.error));
        }
      });
    });
  }

  async batchOperations(operations) {
    return new Promise((resolve, reject) => {
      const message = {
        action: "batch_operations",
        operations: operations
      };
      
      this.ws.send(JSON.stringify(message));
      
      this.ws.once('message', (data) => {
        const response = JSON.parse(data);
        if (response.success) {
          resolve(response.results);
        } else {
          reject({
            error: response.error,
            failedOperation: response.failed_operation,
            partialResults: response.partial_results
          });
        }
      });
    });
  }
}
```

### CLI Tool Integration
```elixir
defmodule FileManagerCLI do
  alias DesktopIntegrationServer.FileManager

  def upload_directory(local_dir, remote_dir) do
    local_files = File.ls!(local_dir)
    
    operations = Enum.map(local_files, fn file ->
      local_path = Path.join(local_dir, file)
      remote_path = Path.join(remote_dir, file)
      content = File.read!(local_path)
      
      {:create_file, remote_path, content, []}
    end)
    
    case FileManager.batch_operations(operations) do
      {:ok, results} ->
        IO.puts("Successfully uploaded #{length(results)} files")
      {:error, {failed_op, partial_results}} ->
        IO.puts("Upload failed at: #{inspect(failed_op)}")
        IO.puts("#{length(partial_results)} files uploaded before failure")
    end
  end
end
```

This comprehensive FileManager module provides a robust, secure, and feature-rich interface for all SFTP file operations while maintaining full compatibility with the existing IPsec tunnel security infrastructure. 