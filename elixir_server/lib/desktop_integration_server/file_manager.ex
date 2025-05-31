defmodule DesktopIntegrationServer.FileManager do
  @moduledoc """
  High-level file management module providing comprehensive CRUD operations
  for SFTP servers. This module provides atomic operations, transaction-like
  behavior, and abstracts all SFTP communication through the existing
  FileStorage adapter infrastructure with IPsec tunnel security.

  All operations are performed through the configured FileStorage adapter,
  ensuring consistent security and connection management.
  """

  require Logger
  alias DesktopIntegrationServer.FileStorage

  @type file_info :: %{
    name: String.t(),
    type: :file | :directory | :symlink,
    size: non_neg_integer(),
    modified: DateTime.t(),
    permissions: String.t(),
    path: String.t()
  }

  @type operation_result :: {:ok, any()} | {:error, atom() | String.t()}
  @type batch_result :: {:ok, [operation_result()]} | {:error, {atom(), [operation_result()]}}

  # ============================================================================
  # CREATE Operations
  # ============================================================================

  @doc """
  Creates a new file on the remote SFTP server with the specified content.

  ## Parameters
  - `remote_path`: Remote file path where the file will be created
  - `content`: File content as binary or string
  - `opts`: Optional parameters
    - `:mode`: File permissions (default: 0o644)
    - `:overwrite`: Whether to overwrite existing files (default: false)
    - `:create_dirs`: Whether to create parent directories (default: true)

  ## Returns
  - `{:ok, remote_path}` on success
  - `{:error, reason}` on failure

  ## Examples
      iex> FileManager.create_file("/home/user/test.txt", "Hello World")
      {:ok, "/home/user/test.txt"}

      iex> FileManager.create_file("/home/user/config.json", Jason.encode!(%{key: "value"}))
      {:ok, "/home/user/config.json"}
  """
  @spec create_file(String.t(), binary(), keyword()) :: operation_result()
  def create_file(remote_path, content, opts \\ []) do
    overwrite = Keyword.get(opts, :overwrite, false)
    create_dirs = Keyword.get(opts, :create_dirs, true)

    Logger.info("[FileManager] Creating file: #{remote_path}")

    with :ok <- validate_remote_path(remote_path),
         :ok <- check_file_exists_if_no_overwrite(remote_path, overwrite),
         :ok <- ensure_parent_directories(remote_path, create_dirs),
         {:ok, temp_file} <- create_temp_file_with_content(content),
         {:ok, _} <- FileStorage.upload_file(temp_file, remote_path),
         :ok <- File.rm(temp_file) do
      Logger.info("[FileManager] File created successfully: #{remote_path}")
      {:ok, remote_path}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to create file #{remote_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Creates a new directory on the remote SFTP server.

  ## Parameters
  - `remote_path`: Remote directory path to create
  - `opts`: Optional parameters
    - `:recursive`: Whether to create parent directories (default: true)
    - `:mode`: Directory permissions (default: 0o755)

  ## Returns
  - `{:ok, remote_path}` on success
  - `{:error, reason}` on failure
  """
  @spec create_directory(String.t(), keyword()) :: operation_result()
  def create_directory(remote_path, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)

    Logger.info("[FileManager] Creating directory: #{remote_path}")

    with :ok <- validate_remote_path(remote_path),
         :ok <- create_directory_impl(remote_path, recursive) do
      Logger.info("[FileManager] Directory created successfully: #{remote_path}")
      {:ok, remote_path}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to create directory #{remote_path}: #{inspect(reason)}")
        error
    end
  end

  # ============================================================================
  # READ Operations
  # ============================================================================

  @doc """
  Reads the content of a file from the remote SFTP server.

  ## Parameters
  - `remote_path`: Remote file path to read
  - `opts`: Optional parameters
    - `:encoding`: Content encoding (:binary, :utf8) (default: :utf8)
    - `:max_size`: Maximum file size to read in bytes (default: 10MB)

  ## Returns
  - `{:ok, content}` on success
  - `{:error, reason}` on failure
  """
  @spec read_file(String.t(), keyword()) :: {:ok, binary() | String.t()} | {:error, any()}
  def read_file(remote_path, opts \\ []) do
    encoding = Keyword.get(opts, :encoding, :utf8)
    max_size = Keyword.get(opts, :max_size, 10 * 1024 * 1024) # 10MB default

    Logger.info("[FileManager] Reading file: #{remote_path}")

    with :ok <- validate_remote_path(remote_path),
         {:ok, file_info} <- get_file_info(remote_path),
         :ok <- validate_file_size(file_info, max_size),
         {:ok, temp_file} <- create_temp_file(),
         {:ok, _} <- FileStorage.download_file(remote_path, temp_file),
         {:ok, content} <- read_temp_file_content(temp_file, encoding),
         :ok <- File.rm(temp_file) do
      Logger.info("[FileManager] File read successfully: #{remote_path} (#{byte_size(content)} bytes)")
      {:ok, content}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to read file #{remote_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Lists files and directories in the specified remote path with detailed information.

  ## Parameters
  - `remote_path`: Remote directory path to list (default: ".")
  - `opts`: Optional parameters
    - `:detailed`: Whether to include detailed file information (default: true)
    - `:recursive`: Whether to list subdirectories recursively (default: false)
    - `:filter`: Filter function for files (default: nil)
    - `:sort_by`: Sort criteria (:name, :size, :modified) (default: :name)

  ## Returns
  - `{:ok, [file_info()]}` on success with detailed info
  - `{:ok, [String.t()]}` on success with simple names only
  - `{:error, reason}` on failure
  """
  @spec list_files(String.t(), keyword()) :: {:ok, [file_info()] | [String.t()]} | {:error, any()}
  def list_files(remote_path \\ ".", opts \\ []) do
    detailed = Keyword.get(opts, :detailed, true)
    recursive = Keyword.get(opts, :recursive, false)
    filter_fn = Keyword.get(opts, :filter)
    sort_by = Keyword.get(opts, :sort_by, :name)

    Logger.info("[FileManager] Listing files in: #{remote_path}")

    with :ok <- validate_remote_path(remote_path),
         {:ok, files} <- FileStorage.list_files(remote_path),
         {:ok, processed_files} <- process_file_list(files, remote_path, detailed, recursive),
         {:ok, filtered_files} <- apply_file_filter(processed_files, filter_fn),
         {:ok, sorted_files} <- sort_files(filtered_files, sort_by) do
      Logger.info("[FileManager] Listed #{length(sorted_files)} files in: #{remote_path}")
      {:ok, sorted_files}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to list files in #{remote_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Gets detailed information about a specific file or directory.

  ## Parameters
  - `remote_path`: Remote file/directory path

  ## Returns
  - `{:ok, file_info()}` on success
  - `{:error, reason}` on failure
  """
  @spec get_file_info(String.t()) :: {:ok, file_info()} | {:error, any()}
    def get_file_info(remote_path) do
    Logger.debug("[FileManager] Getting file info for: #{remote_path}")

    with :ok <- validate_remote_path(remote_path),
         {:ok, file_info} <- FileStorage.get_file_info(remote_path) do
      {:ok, file_info}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to get file info for #{remote_path}: #{inspect(reason)}")
        error
    end
  end

  # ============================================================================
  # UPDATE Operations
  # ============================================================================

  @doc """
  Updates the content of an existing file on the remote SFTP server.

  ## Parameters
  - `remote_path`: Remote file path to update
  - `content`: New file content as binary or string
  - `opts`: Optional parameters
    - `:backup`: Whether to create a backup before updating (default: true)
    - `:atomic`: Whether to use atomic update (temp file + rename) (default: true)

  ## Returns
  - `{:ok, remote_path}` on success
  - `{:error, reason}` on failure
  """
  @spec update_file(String.t(), binary(), keyword()) :: operation_result()
  def update_file(remote_path, content, opts \\ []) do
    backup = Keyword.get(opts, :backup, true)
    atomic = Keyword.get(opts, :atomic, true)

    Logger.info("[FileManager] Updating file: #{remote_path}")

    with :ok <- validate_remote_path(remote_path),
         {:ok, _} <- verify_file_exists(remote_path),
         {:ok, backup_path} <- create_backup_if_requested(remote_path, backup),
         {:ok, _} <- perform_atomic_update(remote_path, content, atomic) do
      Logger.info("[FileManager] File updated successfully: #{remote_path}")
      if backup_path, do: Logger.info("[FileManager] Backup created: #{backup_path}")
      {:ok, remote_path}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to update file #{remote_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Moves/renames a file or directory on the remote SFTP server.

  ## Parameters
  - `source_path`: Current remote path
  - `destination_path`: New remote path
  - `opts`: Optional parameters
    - `:overwrite`: Whether to overwrite destination if it exists (default: false)
    - `:create_dirs`: Whether to create parent directories (default: true)

  ## Returns
  - `{:ok, destination_path}` on success
  - `{:error, reason}` on failure
  """
  @spec move_file(String.t(), String.t(), keyword()) :: operation_result()
  def move_file(source_path, destination_path, opts \\ []) do
    overwrite = Keyword.get(opts, :overwrite, false)
    create_dirs = Keyword.get(opts, :create_dirs, true)

    Logger.info("[FileManager] Moving file: #{source_path} -> #{destination_path}")

    with :ok <- validate_remote_path(source_path),
         :ok <- validate_remote_path(destination_path),
         {:ok, _} <- verify_file_exists(source_path),
         :ok <- check_file_exists_if_no_overwrite(destination_path, overwrite),
         :ok <- ensure_parent_directories(destination_path, create_dirs),
         {:ok, _} <- perform_move_operation(source_path, destination_path) do
      Logger.info("[FileManager] File moved successfully: #{source_path} -> #{destination_path}")
      {:ok, destination_path}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to move file #{source_path} -> #{destination_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Copies a file on the remote SFTP server.

  ## Parameters
  - `source_path`: Source remote path
  - `destination_path`: Destination remote path
  - `opts`: Optional parameters
    - `:overwrite`: Whether to overwrite destination if it exists (default: false)
    - `:create_dirs`: Whether to create parent directories (default: true)

  ## Returns
  - `{:ok, destination_path}` on success
  - `{:error, reason}` on failure
  """
  @spec copy_file(String.t(), String.t(), keyword()) :: operation_result()
  def copy_file(source_path, destination_path, opts \\ []) do
    overwrite = Keyword.get(opts, :overwrite, false)
    create_dirs = Keyword.get(opts, :create_dirs, true)

    Logger.info("[FileManager] Copying file: #{source_path} -> #{destination_path}")

    with :ok <- validate_remote_path(source_path),
         :ok <- validate_remote_path(destination_path),
         {:ok, _} <- verify_file_exists(source_path),
         :ok <- check_file_exists_if_no_overwrite(destination_path, overwrite),
         :ok <- ensure_parent_directories(destination_path, create_dirs),
         {:ok, temp_file} <- create_temp_file(),
         {:ok, _} <- FileStorage.download_file(source_path, temp_file),
         {:ok, _} <- FileStorage.upload_file(temp_file, destination_path),
         :ok <- File.rm(temp_file) do
      Logger.info("[FileManager] File copied successfully: #{source_path} -> #{destination_path}")
      {:ok, destination_path}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to copy file #{source_path} -> #{destination_path}: #{inspect(reason)}")
        error
    end
  end

  # ============================================================================
  # DELETE Operations
  # ============================================================================

  @doc """
  Deletes a file from the remote SFTP server.

  ## Parameters
  - `remote_path`: Remote file path to delete
  - `opts`: Optional parameters
    - `:backup`: Whether to create a backup before deletion (default: false)
    - `:force`: Whether to force deletion without confirmation (default: true)

  ## Returns
  - `{:ok, remote_path}` on success
  - `{:error, reason}` on failure
  """
  @spec delete_file(String.t(), keyword()) :: operation_result()
  def delete_file(remote_path, opts \\ []) do
    backup = Keyword.get(opts, :backup, false)

    Logger.info("[FileManager] Deleting file: #{remote_path}")

    with :ok <- validate_remote_path(remote_path),
         {:ok, _} <- verify_file_exists(remote_path),
         {:ok, backup_path} <- create_backup_if_requested(remote_path, backup),
         {:ok, _} <- perform_delete_operation(remote_path) do
      Logger.info("[FileManager] File deleted successfully: #{remote_path}")
      if backup_path, do: Logger.info("[FileManager] Backup created before deletion: #{backup_path}")
      {:ok, remote_path}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to delete file #{remote_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Deletes a directory from the remote SFTP server.

  ## Parameters
  - `remote_path`: Remote directory path to delete
  - `opts`: Optional parameters
    - `:recursive`: Whether to delete directory contents recursively (default: false)
    - `:force`: Whether to force deletion without confirmation (default: false)

  ## Returns
  - `{:ok, remote_path}` on success
  - `{:error, reason}` on failure
  """
  @spec delete_directory(String.t(), keyword()) :: operation_result()
  def delete_directory(remote_path, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)

    Logger.info("[FileManager] Deleting directory: #{remote_path} (recursive: #{recursive})")

    with :ok <- validate_remote_path(remote_path),
         :ok <- perform_directory_deletion(remote_path, recursive) do
      Logger.info("[FileManager] Directory deleted successfully: #{remote_path}")
      {:ok, remote_path}
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to delete directory #{remote_path}: #{inspect(reason)}")
        error
    end
  end

  # ============================================================================
  # BATCH Operations
  # ============================================================================

  @doc """
  Performs multiple file operations atomically. If any operation fails,
  all previous operations are rolled back where possible.

  ## Parameters
  - `operations`: List of operation tuples
    - `{:create_file, remote_path, content, opts}`
    - `{:update_file, remote_path, content, opts}`
    - `{:delete_file, remote_path, opts}`
    - `{:move_file, source_path, dest_path, opts}`
    - `{:copy_file, source_path, dest_path, opts}`

  ## Returns
  - `{:ok, [operation_result()]}` on success
  - `{:error, {failed_operation, [operation_result()]}}` on failure with partial results
  """
  @spec batch_operations([tuple()]) :: batch_result()
  def batch_operations(operations) do
    Logger.info("[FileManager] Starting batch operation with #{length(operations)} operations")

    case perform_batch_operations(operations, [], []) do
      {:ok, results} ->
        Logger.info("[FileManager] Batch operation completed successfully")
        {:ok, results}
             {:error, {failed_op, _results}} = error ->
         Logger.error("[FileManager] Batch operation failed at: #{inspect(failed_op)}")
         error
    end
  end

  # ============================================================================
  # UTILITY Operations
  # ============================================================================

  @doc """
  Checks if a file or directory exists on the remote SFTP server.

  ## Parameters
  - `remote_path`: Remote path to check

  ## Returns
  - `{:ok, true}` if exists
  - `{:ok, false}` if doesn't exist
  - `{:error, reason}` on error
  """
  @spec exists?(String.t()) :: {:ok, boolean()} | {:error, any()}
    def exists?(remote_path) do
    Logger.debug("[FileManager] Checking existence of: #{remote_path}")

    with :ok <- validate_remote_path(remote_path),
         result <- FileStorage.exists?(remote_path) do
      result
    else
      {:error, reason} = error ->
        Logger.error("[FileManager] Failed to check existence of #{remote_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Gets the total size of a directory (including subdirectories).

  ## Parameters
  - `remote_path`: Remote directory path

  ## Returns
  - `{:ok, size_in_bytes}` on success
  - `{:error, reason}` on failure
  """
  @spec get_directory_size(String.t()) :: {:ok, non_neg_integer()} | {:error, any()}
  def get_directory_size(remote_path) do
    Logger.info("[FileManager] Calculating directory size for: #{remote_path}")

    with {:ok, files} <- list_files(remote_path, detailed: true, recursive: true) do
      total_size = Enum.reduce(files, 0, fn file, acc ->
        if file.type == :file, do: acc + file.size, else: acc
      end)

      Logger.info("[FileManager] Directory size calculated: #{remote_path} = #{total_size} bytes")
      {:ok, total_size}
    end
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  defp validate_remote_path(path) when is_binary(path) and path != "", do: :ok
  defp validate_remote_path(_), do: {:error, :invalid_path}

  defp check_file_exists_if_no_overwrite(_path, true), do: :ok
  defp check_file_exists_if_no_overwrite(path, false) do
    case FileStorage.exists?(path) do
      {:ok, true} -> {:error, :file_exists}
      {:ok, false} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_parent_directories(_path, false), do: :ok
  defp ensure_parent_directories(path, true) do
    parent_dir = Path.dirname(path)
    if parent_dir != "." and parent_dir != "/" do
      create_directory(parent_dir, recursive: true)
    else
      :ok
    end
  end

  defp create_temp_file_with_content(content) do
    with {:ok, temp_file} <- create_temp_file(),
         :ok <- File.write(temp_file, content) do
      {:ok, temp_file}
    end
  end

  defp create_temp_file do
    temp_dir = System.tmp_dir!()
    temp_file = Path.join(temp_dir, "filemanager_#{:erlang.unique_integer([:positive])}.tmp")
    {:ok, temp_file}
  end

    defp create_directory_impl(remote_path, recursive) do
    if recursive do
      # Create parent directories first
      parent_dir = Path.dirname(remote_path)
      if parent_dir != "." and parent_dir != "/" do
        case create_directory_impl(parent_dir, true) do
          :ok -> FileStorage.create_directory(remote_path)
          {:error, :eexist} -> FileStorage.create_directory(remote_path) # Parent exists, continue
          {:error, reason} -> {:error, reason}
        end
      else
        case FileStorage.create_directory(remote_path) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    else
      case FileStorage.create_directory(remote_path) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp verify_file_exists(remote_path) do
    case FileStorage.exists?(remote_path) do
      {:ok, true} -> {:ok, :exists}
      {:ok, false} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_backup_if_requested(_path, false), do: {:ok, nil}
  defp create_backup_if_requested(path, true) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    backup_path = "#{path}.backup.#{timestamp}"

    case copy_file(path, backup_path) do
      {:ok, _} -> {:ok, backup_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_atomic_update(remote_path, content, true) do
    temp_remote_path = "#{remote_path}.tmp.#{:erlang.unique_integer([:positive])}"

    with {:ok, _} <- create_file(temp_remote_path, content, overwrite: true),
         {:ok, _} <- move_file(temp_remote_path, remote_path, overwrite: true) do
      {:ok, remote_path}
    else
      {:error, reason} ->
        # Cleanup temp file if it exists
        delete_file(temp_remote_path)
        {:error, reason}
    end
  end

  defp perform_atomic_update(remote_path, content, false) do
    create_file(remote_path, content, overwrite: true)
  end

  defp perform_move_operation(source_path, destination_path) do
    case FileStorage.move_file(source_path, destination_path) do
      {:ok, _} -> {:ok, destination_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_delete_operation(remote_path) do
    case FileStorage.delete_file(remote_path) do
      {:ok, _} -> {:ok, remote_path}
      {:error, reason} -> {:error, reason}
    end
  end

    defp perform_directory_deletion(remote_path, recursive) do
    if recursive do
      with {:ok, files} <- list_files(remote_path, detailed: true) do
        # Delete all files first, then directories
        files
        |> Enum.filter(&(&1.type == :file))
        |> Enum.each(&delete_file(&1.path))

        files
        |> Enum.filter(&(&1.type == :directory))
        |> Enum.each(&delete_directory(&1.path, recursive: true))

        # Finally delete the directory itself
        case FileStorage.delete_directory(remote_path) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    else
      case FileStorage.delete_directory(remote_path) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp process_file_list(files, base_path, detailed, recursive) do
    if detailed do
      processed = Enum.map(files, fn file_name ->
        file_path = Path.join(base_path, file_name)
        %{
          name: file_name,
          type: :file, # Would need SFTP stat to determine actual type
          size: 0,     # Would need SFTP stat for real size
          modified: DateTime.utc_now(),
          permissions: "644",
          path: file_path
        }
      end)

      if recursive do
        # Would need to implement recursive directory traversal
        {:ok, processed}
      else
        {:ok, processed}
      end
    else
      {:ok, files}
    end
  end

  defp apply_file_filter(files, nil), do: {:ok, files}
  defp apply_file_filter(files, filter_fn) when is_function(filter_fn) do
    {:ok, Enum.filter(files, filter_fn)}
  end

  defp sort_files(files, :name) when is_list(files) and length(files) > 0 do
    if is_map(hd(files)) do
      {:ok, Enum.sort_by(files, & &1.name)}
    else
      {:ok, Enum.sort(files)}
    end
  end

  defp sort_files(files, :size) when is_list(files) and length(files) > 0 do
    if is_map(hd(files)) do
      {:ok, Enum.sort_by(files, & &1.size, :desc)}
    else
      {:ok, files} # Can't sort by size if we don't have detailed info
    end
  end

  defp sort_files(files, :modified) when is_list(files) and length(files) > 0 do
    if is_map(hd(files)) do
      {:ok, Enum.sort_by(files, & &1.modified, {:desc, DateTime})}
    else
      {:ok, files} # Can't sort by modified if we don't have detailed info
    end
  end

  defp sort_files(files, _), do: {:ok, files}

  defp read_temp_file_content(temp_file, :binary) do
    File.read(temp_file)
  end

  defp read_temp_file_content(temp_file, :utf8) do
    case File.read(temp_file) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_file_size(%{size: size}, max_size) when size > max_size do
    {:error, :file_too_large}
  end
  defp validate_file_size(_, _), do: :ok

  defp perform_batch_operations([], results, _rollback_ops) do
    {:ok, Enum.reverse(results)}
  end

  defp perform_batch_operations([op | rest], results, rollback_ops) do
    case execute_single_operation(op) do
      {:ok, result} ->
        rollback_op = create_rollback_operation(op, result)
        perform_batch_operations(rest, [result | results], [rollback_op | rollback_ops])

      {:error, _reason} ->
        # Perform rollback
        Enum.each(rollback_ops, &execute_rollback_operation/1)
        {:error, {op, Enum.reverse(results)}}
    end
  end

  defp execute_single_operation({:create_file, path, content, opts}) do
    create_file(path, content, opts)
  end

  defp execute_single_operation({:update_file, path, content, opts}) do
    update_file(path, content, opts)
  end

  defp execute_single_operation({:delete_file, path, opts}) do
    delete_file(path, opts)
  end

  defp execute_single_operation({:move_file, source, dest, opts}) do
    move_file(source, dest, opts)
  end

  defp execute_single_operation({:copy_file, source, dest, opts}) do
    copy_file(source, dest, opts)
  end

  defp execute_single_operation(unknown_op) do
    {:error, {:unknown_operation, unknown_op}}
  end

  defp create_rollback_operation({:create_file, path, _content, _opts}, _result) do
    {:delete_file, path, []}
  end

  defp create_rollback_operation({:delete_file, path, _opts}, _result) do
    # Can't easily rollback a delete without backup
    {:noop, path}
  end

  defp create_rollback_operation({:move_file, source, dest, _opts}, _result) do
    {:move_file, dest, source, []}
  end

  defp create_rollback_operation({:copy_file, _source, dest, _opts}, _result) do
    {:delete_file, dest, []}
  end

  defp create_rollback_operation(_, _), do: {:noop, nil}

  defp execute_rollback_operation({:noop, _}), do: :ok
  defp execute_rollback_operation(rollback_op) do
    case execute_single_operation(rollback_op) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("[FileManager] Rollback operation failed: #{inspect(rollback_op)}, reason: #{inspect(reason)}")
        :ok
    end
  end
end
