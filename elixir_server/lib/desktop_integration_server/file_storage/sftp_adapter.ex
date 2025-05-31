defmodule DesktopIntegrationServer.FileStorage.SFTPAdapter do
  @behaviour DesktopIntegrationServer.FileStorage.Adapter
  require Logger
  import Bitwise

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def init(config) do
    {:ok, config}
  end

  # Helper to build connection parameters with mandatory IPsec tunnel support
  defp build_connection_params(_config) do
    # Check if security enforcement is enabled
    ipsec_config = Application.get_env(:desktop_integration_server, :ipsec_tunnel, [])
    enforce_security = Keyword.get(ipsec_config, :enforce_security, true)

    # Check if IPsec tunnel is available and active
    case get_secure_connection_params() do
      {:ok, secure_params} ->
        Logger.info("[SFTPAdapter] Using secure IPsec tunnel connection: #{inspect(secure_params)}")
        %{
          host: secure_params.host,
          port: secure_params.port,
          secure: true,
          tunnel_interface: secure_params.tunnel_interface
        }

      {:error, :tunnel_not_active} when enforce_security ->
        Logger.error("[SFTPAdapter] SECURITY ENFORCED: IPsec tunnel not active, blocking connection")
        raise RuntimeError, "IPsec tunnel required but not active. Connection blocked for security."

      {:error, :ipsec_disabled} when enforce_security ->
        Logger.error("[SFTPAdapter] SECURITY ENFORCED: IPsec disabled, blocking connection")
        raise RuntimeError, "IPsec tunnel required but disabled. Connection blocked for security."

      {:error, :ipsec_manager_not_available} when enforce_security ->
        Logger.error("[SFTPAdapter] SECURITY ENFORCED: IPsec manager not available, blocking connection")
        raise RuntimeError, "IPsec tunnel required but manager not available. Connection blocked for security."

      # When security is not enforced, still block connections - no fallback allowed
      {:error, reason} ->
        Logger.error("[SFTPAdapter] IPsec tunnel unavailable (#{inspect(reason)}), no fallback allowed")
        raise RuntimeError, "IPsec tunnel unavailable and no fallback connections permitted. Reason: #{inspect(reason)}"
    end
  end

  defp get_secure_connection_params do
    try do
      case Process.whereis(DesktopIntegrationServer.IPsecManager) do
        nil ->
          {:error, :ipsec_manager_not_available}

        _pid ->
          case DesktopIntegrationServer.IPsecManager.get_secure_connection_params() do
            {:error, :ipsec_disabled} ->
              {:error, :ipsec_disabled}
            other_result ->
              other_result
          end
      end
    rescue
      error ->
        Logger.warning("[SFTPAdapter] Error getting secure connection params: #{inspect(error)}")
        {:error, :ipsec_manager_not_available}
    end
  end

  # Helper to build common SSH connect options using configuration
  defp build_connect_opts(config) do
    user = Keyword.fetch!(config, :user)
    password = Keyword.get(config, :password)
    key_path = Keyword.get(config, :private_key_path)
    key_passphrase = Keyword.get(config, :private_key_passphrase)

    # Get timeout and other settings from configuration
    connection_timeout_ms = Keyword.get(config, :connection_timeout_ms, 30_000)
    silently_accept_hosts = Keyword.get(config, :silently_accept_hosts, true)
    user_interaction = Keyword.get(config, :user_interaction, false)

    opts = [
      user: String.to_charlist(user),
      silently_accept_hosts: silently_accept_hosts,
      timeout: connection_timeout_ms,
      user_interaction: user_interaction
    ]

    # Prefer key_path if available, otherwise try password (if present)
    cond do
      key_path ->
        key_opts = [user_identity_files: [String.to_charlist(key_path)]]
        key_opts = if key_passphrase, do: Keyword.put(key_opts, :user_identity_passphrase, String.to_charlist(key_passphrase)), else: key_opts
        Keyword.merge(opts, key_opts)
      password ->
        # Only add password if key_path is not provided
        Keyword.put(opts, :password, String.to_charlist(password))
      true ->
        opts
    end
  end

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def upload_file(config, local_path, remote_name, _opts \\ []) do
    conn_params = build_connection_params(config)
    host_str = conn_params.host
    port = conn_params.port
    base_remote_path = Keyword.get(config, :base_remote_path, ".")
    full_remote_path = resolve_remote_path(remote_name, base_remote_path)
    connect_opts = build_connect_opts(config)

    # All connections are now secure via IPsec tunnel
    log_prefix = "[SFTPAdapter][UploadFile][SECURE IPsec Tunnel]"

    Logger.info("#{log_prefix} Request to upload '#{local_path}' to '#{full_remote_path}' on sftp://#{config[:user]}@#{host_str}:#{port}")
    ensure_ssh_started()
    Logger.debug("#{log_prefix} Effective SFTP options for start_channel: #{inspect(connect_opts)}")

    case :ssh_sftp.start_channel(String.to_charlist(host_str), port, connect_opts) do
      {:ok, sftp_channel, ssh_conn} ->
        Logger.info("#{log_prefix} SFTP Channel and Connection established. Uploading '#{local_path}' to '#{full_remote_path}'")
        res =
          case :ssh_sftp.write_file(sftp_channel, String.to_charlist(full_remote_path), String.to_charlist(local_path)) do
            :ok ->
              Logger.info("#{log_prefix} Upload successful: #{full_remote_path}")
              {:ok, full_remote_path}
            {:error, reason} ->
              Logger.error("#{log_prefix} Upload failed: #{inspect(reason)}")
              {:error, reason}
          end
        :ssh_sftp.stop_channel(sftp_channel)
        :ssh.close(ssh_conn)
        Logger.debug("#{log_prefix} SFTP channel and connection closed for '#{full_remote_path}'")
        res
      {:error, reason} ->
        Logger.error("#{log_prefix} SFTP start_channel failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def download_file(config, remote_name, local_path, _opts \\ []) do
    conn_params = build_connection_params(config)
    host_str = conn_params.host
    port = conn_params.port
    base_remote_path = Keyword.get(config, :base_remote_path, ".")
    full_remote_path = resolve_remote_path(remote_name, base_remote_path)
    connect_opts = build_connect_opts(config)

    # All connections are now secure via IPsec tunnel
    log_prefix = "[SFTPAdapter][DownloadFile][SECURE IPsec Tunnel]"

    Logger.info("#{log_prefix} Request to download '#{full_remote_path}' to '#{local_path}' from sftp://#{config[:user]}@#{host_str}:#{port}")
    File.mkdir_p(Path.dirname(local_path))
    ensure_ssh_started()
    Logger.debug("#{log_prefix} Effective SFTP options for start_channel: #{inspect(connect_opts)}")

    case :ssh_sftp.start_channel(String.to_charlist(host_str), port, connect_opts) do
      {:ok, sftp_channel, ssh_conn} ->
        Logger.info("#{log_prefix} SFTP Channel and Connection established. Downloading '#{full_remote_path}' to '#{local_path}'")
        res =
          case :ssh_sftp.read_file(sftp_channel, String.to_charlist(full_remote_path), String.to_charlist(local_path)) do
            :ok ->
              Logger.info("#{log_prefix} Download successful: #{local_path}")
              {:ok, local_path}
            {:error, reason} ->
              Logger.error("#{log_prefix} Download failed: #{inspect(reason)}")
              {:error, reason}
          end
        :ssh_sftp.stop_channel(sftp_channel)
        :ssh.close(ssh_conn)
        Logger.debug("#{log_prefix} SFTP channel and connection closed for '#{full_remote_path}'")
        res
      {:error, reason} ->
        Logger.error("#{log_prefix} SFTP start_channel failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def list_files(config, remote_path_str, _opts \\ []) do
    conn_params = build_connection_params(config)
    host_str = conn_params.host
    port = conn_params.port
    base_remote_path = Keyword.get(config, :base_remote_path, ".")
    full_remote_path = resolve_remote_path(remote_path_str, base_remote_path)
    connect_opts = build_connect_opts(config)

    # All connections are now secure via IPsec tunnel
    log_prefix = "[SFTPAdapter][ListFiles][SECURE IPsec Tunnel]"

    Logger.info("#{log_prefix} Request to list: '#{full_remote_path}' on sftp://#{config[:user]}@#{host_str}:#{port}")
    ensure_ssh_started()
    Logger.debug("#{log_prefix} Effective SFTP options for start_channel: #{inspect(connect_opts)}")

    case :ssh_sftp.start_channel(String.to_charlist(host_str), port, connect_opts) do
      {:ok, sftp_channel, ssh_conn} ->
        Logger.info("#{log_prefix} SFTP Channel and Connection established. Listing directory: '#{full_remote_path}'")
        list_dir_result = :ssh_sftp.list_dir(sftp_channel, String.to_charlist(full_remote_path))
        Logger.debug("#{log_prefix} Raw :ssh_sftp.list_dir result for '#{full_remote_path}': #{inspect(list_dir_result)}")
        res =
          case list_dir_result do
            {:ok, files_charlists} ->
              files_strings = Enum.map(files_charlists, &List.to_string/1)
              Logger.info("#{log_prefix} Directory listing successful for '#{full_remote_path}': #{inspect(files_strings)}")
              {:ok, files_strings}
            {:error, reason} ->
              Logger.error("#{log_prefix} Directory listing failed for '#{full_remote_path}': #{inspect(reason)}")
              {:error, reason}
          end
        :ssh_sftp.stop_channel(sftp_channel)
        :ssh.close(ssh_conn)
        Logger.debug("#{log_prefix} SFTP channel and connection closed for '#{full_remote_path}'")
        res
      {:error, reason} ->
        Logger.error("#{log_prefix} SFTP start_channel failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def delete_file(config, remote_path, _opts \\ []) do
    conn_params = build_connection_params(config)
    host_str = conn_params.host
    port = conn_params.port
    base_remote_path = Keyword.get(config, :base_remote_path, ".")
    full_remote_path = resolve_remote_path(remote_path, base_remote_path)
    connect_opts = build_connect_opts(config)

    log_prefix = "[SFTPAdapter][DeleteFile][SECURE IPsec Tunnel]"

    Logger.info("#{log_prefix} Request to delete: '#{full_remote_path}' on sftp://#{config[:user]}@#{host_str}:#{port}")
    ensure_ssh_started()

    case :ssh_sftp.start_channel(String.to_charlist(host_str), port, connect_opts) do
      {:ok, sftp_channel, ssh_conn} ->
        Logger.info("#{log_prefix} SFTP Channel and Connection established. Deleting: '#{full_remote_path}'")
        res =
          case :ssh_sftp.delete(sftp_channel, String.to_charlist(full_remote_path)) do
            :ok ->
              Logger.info("#{log_prefix} Delete successful: #{full_remote_path}")
              {:ok, full_remote_path}
            {:error, reason} ->
              Logger.error("#{log_prefix} Delete failed: #{inspect(reason)}")
              {:error, reason}
          end
        :ssh_sftp.stop_channel(sftp_channel)
        :ssh.close(ssh_conn)
        Logger.debug("#{log_prefix} SFTP channel and connection closed for '#{full_remote_path}'")
        res
      {:error, reason} ->
        Logger.error("#{log_prefix} SFTP start_channel failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def create_directory(config, remote_path, _opts \\ []) do
    conn_params = build_connection_params(config)
    host_str = conn_params.host
    port = conn_params.port
    base_remote_path = Keyword.get(config, :base_remote_path, ".")
    full_remote_path = resolve_remote_path(remote_path, base_remote_path)
    connect_opts = build_connect_opts(config)

    log_prefix = "[SFTPAdapter][CreateDirectory][SECURE IPsec Tunnel]"

    Logger.info("#{log_prefix} Request to create directory: '#{full_remote_path}' on sftp://#{config[:user]}@#{host_str}:#{port}")
    ensure_ssh_started()

    case :ssh_sftp.start_channel(String.to_charlist(host_str), port, connect_opts) do
      {:ok, sftp_channel, ssh_conn} ->
        Logger.info("#{log_prefix} SFTP Channel and Connection established. Creating directory: '#{full_remote_path}'")
        res =
          case :ssh_sftp.make_dir(sftp_channel, String.to_charlist(full_remote_path)) do
            :ok ->
              Logger.info("#{log_prefix} Directory creation successful: #{full_remote_path}")
              {:ok, full_remote_path}
            {:error, reason} ->
              Logger.error("#{log_prefix} Directory creation failed: #{inspect(reason)}")
              {:error, reason}
          end
        :ssh_sftp.stop_channel(sftp_channel)
        :ssh.close(ssh_conn)
        Logger.debug("#{log_prefix} SFTP channel and connection closed for '#{full_remote_path}'")
        res
      {:error, reason} ->
        Logger.error("#{log_prefix} SFTP start_channel failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def delete_directory(config, remote_path, _opts \\ []) do
    conn_params = build_connection_params(config)
    host_str = conn_params.host
    port = conn_params.port
    base_remote_path = Keyword.get(config, :base_remote_path, ".")
    full_remote_path = resolve_remote_path(remote_path, base_remote_path)
    connect_opts = build_connect_opts(config)

    log_prefix = "[SFTPAdapter][DeleteDirectory][SECURE IPsec Tunnel]"

    Logger.info("#{log_prefix} Request to delete directory: '#{full_remote_path}' on sftp://#{config[:user]}@#{host_str}:#{port}")
    ensure_ssh_started()

    case :ssh_sftp.start_channel(String.to_charlist(host_str), port, connect_opts) do
      {:ok, sftp_channel, ssh_conn} ->
        Logger.info("#{log_prefix} SFTP Channel and Connection established. Deleting directory: '#{full_remote_path}'")
        res =
          case :ssh_sftp.del_dir(sftp_channel, String.to_charlist(full_remote_path)) do
            :ok ->
              Logger.info("#{log_prefix} Directory deletion successful: #{full_remote_path}")
              {:ok, full_remote_path}
            {:error, reason} ->
              Logger.error("#{log_prefix} Directory deletion failed: #{inspect(reason)}")
              {:error, reason}
          end
        :ssh_sftp.stop_channel(sftp_channel)
        :ssh.close(ssh_conn)
        Logger.debug("#{log_prefix} SFTP channel and connection closed for '#{full_remote_path}'")
        res
      {:error, reason} ->
        Logger.error("#{log_prefix} SFTP start_channel failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def move_file(config, source_path, destination_path, _opts \\ []) do
    conn_params = build_connection_params(config)
    host_str = conn_params.host
    port = conn_params.port
    base_remote_path = Keyword.get(config, :base_remote_path, ".")

    full_source_path = resolve_remote_path(source_path, base_remote_path)
    full_destination_path = resolve_remote_path(destination_path, base_remote_path)

    connect_opts = build_connect_opts(config)

    log_prefix = "[SFTPAdapter][MoveFile][SECURE IPsec Tunnel]"

    Logger.info("#{log_prefix} Request to move: '#{full_source_path}' -> '#{full_destination_path}' on sftp://#{config[:user]}@#{host_str}:#{port}")
    ensure_ssh_started()

    case :ssh_sftp.start_channel(String.to_charlist(host_str), port, connect_opts) do
      {:ok, sftp_channel, ssh_conn} ->
        Logger.info("#{log_prefix} SFTP Channel and Connection established. Moving: '#{full_source_path}' -> '#{full_destination_path}'")
        res =
          case :ssh_sftp.rename(sftp_channel, String.to_charlist(full_source_path), String.to_charlist(full_destination_path)) do
            :ok ->
              Logger.info("#{log_prefix} Move successful: #{full_source_path} -> #{full_destination_path}")
              {:ok, full_destination_path}
            {:error, reason} ->
              Logger.error("#{log_prefix} Move failed: #{inspect(reason)}")
              {:error, reason}
          end
        :ssh_sftp.stop_channel(sftp_channel)
        :ssh.close(ssh_conn)
        Logger.debug("#{log_prefix} SFTP channel and connection closed for move operation")
        res
      {:error, reason} ->
        Logger.error("#{log_prefix} SFTP start_channel failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def get_file_info(config, remote_path, _opts \\ []) do
    conn_params = build_connection_params(config)
    host_str = conn_params.host
    port = conn_params.port
    base_remote_path = Keyword.get(config, :base_remote_path, ".")
    full_remote_path = resolve_remote_path(remote_path, base_remote_path)
    connect_opts = build_connect_opts(config)

    log_prefix = "[SFTPAdapter][GetFileInfo][SECURE IPsec Tunnel]"

    Logger.debug("#{log_prefix} Request to get file info: '#{full_remote_path}' on sftp://#{config[:user]}@#{host_str}:#{port}")
    ensure_ssh_started()

    case :ssh_sftp.start_channel(String.to_charlist(host_str), port, connect_opts) do
      {:ok, sftp_channel, ssh_conn} ->
        Logger.debug("#{log_prefix} SFTP Channel and Connection established. Getting file info: '#{full_remote_path}'")
        res =
          case :ssh_sftp.read_file_info(sftp_channel, String.to_charlist(full_remote_path)) do
            {:ok, file_info} ->
              processed_info = %{
                name: Path.basename(full_remote_path),
                type: determine_file_type(file_info),
                size: file_info.size,
                modified: convert_erlang_datetime(file_info.mtime),
                permissions: format_permissions(file_info.mode),
                path: full_remote_path
              }
              Logger.debug("#{log_prefix} File info retrieved successfully: #{full_remote_path}")
              {:ok, processed_info}
            {:error, reason} ->
              Logger.error("#{log_prefix} File info retrieval failed: #{inspect(reason)}")
              {:error, reason}
          end
        :ssh_sftp.stop_channel(sftp_channel)
        :ssh.close(ssh_conn)
        Logger.debug("#{log_prefix} SFTP channel and connection closed for '#{full_remote_path}'")
        res
      {:error, reason} ->
        Logger.error("#{log_prefix} SFTP start_channel failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl DesktopIntegrationServer.FileStorage.Adapter
  def exists?(config, remote_path, _opts \\ []) do
    case get_file_info(config, remote_path) do
      {:ok, _} -> {:ok, true}
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  # Helper functions for file info processing
  defp determine_file_type(file_info) do
    case file_info.type do
      :regular -> :file
      :directory -> :directory
      :symlink -> :symlink
      _ -> :file
    end
  end

  defp convert_erlang_datetime({{year, month, day}, {hour, minute, second}}) do
    case DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second)) do
      {:ok, datetime} -> datetime
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp format_permissions(mode) when is_integer(mode) do
    # Convert mode to octal string representation
    # Use bitwise AND to mask to permission bits only (last 9 bits)
    Integer.to_string(mode &&& 0o777, 8)
  end

  defp format_permissions(_), do: "644"

  # Helper function to resolve remote paths correctly
  defp resolve_remote_path(remote_path, base_remote_path) do
    cond do
      # If the path is already absolute, use it as-is
      Path.type(remote_path) == :absolute ->
        remote_path

      # If the remote path already starts with the base path, don't double-join
      String.starts_with?(remote_path, base_remote_path) ->
        remote_path

      # Otherwise, join the base path with the remote path
      true ->
        Path.join(base_remote_path, remote_path)
    end
  end

  defp ensure_ssh_started do
    case Application.ensure_started(:ssh) do
      :ok -> :ok
      {:error, {reason, _}} -> Logger.warning("Failed to ensure :ssh app started: #{inspect(reason)}. It might already be running or there is an issue.")
      {:error, reason} -> Logger.warning("Failed to ensure :ssh app started: #{inspect(reason)}. It might already be running or there is an issue.")
    end
  end
end
