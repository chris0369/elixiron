defmodule DesktopIntegrationServer.PathUtils do
  @moduledoc """
  Centralized path utilities for consistent path handling across the application.

  This module ensures all paths are properly normalized and absolute, removing
  the complexity of path resolution scattered across different modules.
  """

  require Logger

  @doc """
  Normalizes a path to ensure it's absolute and properly formatted.

  ## Examples
      iex> PathUtils.normalize_path("testfile.txt")
      "/home/testuser/testfile.txt"

      iex> PathUtils.normalize_path("/home/testuser/testfile.txt")
      "/home/testuser/testfile.txt"

      iex> PathUtils.normalize_path("./subdir/file.txt")
      "/home/testuser/subdir/file.txt"
  """
  @spec normalize_path(String.t()) :: String.t()
  def normalize_path(path) when is_binary(path) do
    base_path = get_base_remote_path()

    Logger.debug("[PathUtils] normalize_path - input: '#{path}', base_path: '#{base_path}'")

    result = cond do
      # Already absolute Unix-style path
      String.starts_with?(path, "/") ->
        # Use the path as-is for Unix-style absolute paths
        # This handles both exact base path and paths within the base
        path

      # Relative path starting with ./
      String.starts_with?(path, "./") ->
        relative_part = String.slice(path, 2..-1//-1)
        Path.join(base_path, relative_part)

      # Simple relative path
      true ->
        Path.join(base_path, path)
    end

    Logger.debug("[PathUtils] normalize_path - result: '#{result}'")
    result
  end

  @doc """
  Validates that a path is safe and within allowed boundaries.

  Prevents directory traversal attacks and ensures paths stay within the configured base directory.
  """
  @spec validate_path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def validate_path(path) when is_binary(path) do
    normalized = normalize_path(path)
    base_path = get_base_remote_path()

    Logger.debug("[PathUtils] validate_path - original: '#{path}', normalized: '#{normalized}', base: '#{base_path}'")

    cond do
      # Empty path
      path == "" ->
        {:error, :empty_path}

      # Path traversal attempt
      String.contains?(path, "..") ->
        {:error, :path_traversal_attempt}

      # Path outside base directory
      not String.starts_with?(normalized, base_path) ->
        Logger.debug("[PathUtils] Path outside base - normalized '#{normalized}' does not start with base '#{base_path}'")
        {:error, :path_outside_base}

      # Valid path
      true ->
        {:ok, normalized}
    end
  end

  @doc """
  Gets the parent directory of a path.
  """
  @spec parent_dir(String.t()) :: String.t()
  def parent_dir(path) do
    normalized = normalize_path(path)
    Path.dirname(normalized)
  end

  @doc """
  Joins multiple path segments safely.
  """
  @spec safe_join([String.t()]) :: String.t()
  def safe_join(segments) when is_list(segments) do
    segments
    |> Enum.reduce("", fn segment, acc ->
      if acc == "" do
        segment
      else
        Path.join(acc, segment)
      end
    end)
    |> normalize_path()
  end

  @doc """
  Creates a backup filename with timestamp.
  """
  @spec backup_filename(String.t()) :: String.t()
  def backup_filename(original_path) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "#{original_path}.backup.#{timestamp}"
  end



  @doc """
  Validates a path and returns the normalized path.

  This is a safe version that never raises exceptions, making it suitable
  for use in WebSocket processes and other critical components.

  ## Returns
  - `{:ok, normalized_path}` if path is valid
  - `{:error, reason}` if path is invalid

  ## Examples
      iex> PathUtils.safe_validate_path("testfile.txt")
      {:ok, "/home/testuser/testfile.txt"}

      iex> PathUtils.safe_validate_path("../../../etc/passwd")
      {:error, :path_traversal_attempt}
  """
  @spec safe_validate_path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def safe_validate_path(path) when is_binary(path) do
    validate_path(path)
  end

  @doc """
  Gets the configured base remote path from application config.
  """
  @spec get_base_remote_path() :: String.t()
  def get_base_remote_path do
    Application.get_env(:desktop_integration_server, DesktopIntegrationServer.FileStorage, [])
    |> Keyword.get(:sftp_config, [])
    |> Keyword.get(:base_remote_path, "/")
  end





  @doc """
  Logs path operations for debugging.
  """
  @spec log_path_operation(String.t(), String.t(), String.t()) :: :ok
  def log_path_operation(operation, input_path, result_path) do
    Logger.debug("[PathUtils] #{operation}: '#{input_path}' -> '#{result_path}'")
    :ok
  end

  @doc """
  Validates that a path is safe for WebSocket operations.

  This function provides additional safety checks specifically designed for
  WebSocket handlers and other process-isolated components.
  """
  @spec websocket_safe_validate_path(String.t()) :: {:ok, String.t()} | {:websocket_error, atom(), String.t()}
  def websocket_safe_validate_path(path) when is_binary(path) do
    try do
      case validate_path(path) do
        {:ok, normalized_path} ->
          {:ok, normalized_path}
        {:error, reason} ->
          {:websocket_error, reason, "Path validation failed: #{inspect(reason)}"}
      end
    rescue
      error ->
        Logger.error("[PathUtils] Unexpected error in websocket_safe_validate_path: #{inspect(error)}")
        {:websocket_error, :unexpected_error, "Unexpected validation error: #{inspect(error)}"}
    catch
      kind, reason ->
        Logger.error("[PathUtils] Unexpected catch in websocket_safe_validate_path: #{inspect({kind, reason})}")
        {:websocket_error, :unexpected_catch, "Unexpected error: #{inspect({kind, reason})}"}
    end
  end

  @doc """
  Resolves path from parameters, supporting both old format (direct path) and new format (parent_path + name).

  This function handles the transition between client-server communication formats:
  - Old format: Client sends complete path
  - New format: Client sends parent_path + file_name/directory_name (better separation of concerns)

  ## Parameters
  - `params`: Map of parameters from the client
  - `name_key`: Key for the name field ("file_name" or "directory_name")

  ## Returns
  - `{:ok, resolved_path}` if path can be resolved
  - `{:error, reason}` if path cannot be resolved

  ## Examples
      iex> PathUtils.resolve_path_from_params(%{"path" => "/home/user/file.txt"}, "file_name")
      {:ok, "/home/user/file.txt"}

      iex> PathUtils.resolve_path_from_params(%{"parent_path" => "/home/user", "file_name" => "file.txt"}, "file_name")
      {:ok, "/home/user/file.txt"}
  """
  @spec resolve_path_from_params(map(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def resolve_path_from_params(params, name_key) when is_map(params) and is_binary(name_key) do
    case {Map.get(params, "path"), Map.get(params, "parent_path"), Map.get(params, name_key)} do
      {path, nil, nil} when is_binary(path) ->
        # Old format: direct path
        {:ok, path}
      {nil, parent_path, name} when is_binary(parent_path) and is_binary(name) ->
        # New format: parent path + name, let server handle path joining
        {:ok, Path.join(parent_path, name)}
      _ ->
        # Invalid parameters
        {:error, :missing_path_parameter}
    end
  end
end
