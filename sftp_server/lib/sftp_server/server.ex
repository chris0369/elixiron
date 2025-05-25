defmodule SftpServer.Server do
  use GenServer
  require Logger

  # SSH Message Debug Logger - Arity 3 (no longer directly used in daemon_opts)
  # def log_ssh_message(direction, packet_type, binary_payload) do
  #   Logger.debug(
  #     "SSH MSG: #{direction} - Type: #{packet_type} - Payload: #{inspect(binary_payload)}"
  #   )
  # end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    try do
      port = Keyword.get(opts, :port)
      base_path_str = Application.get_env(:sftp_server, :base_path)
      File.mkdir_p(base_path_str)
      base_path_charlist = String.to_charlist(base_path_str)

      system_dir_str = Application.get_env(:sftp_server, :system_dir)
      File.mkdir_p(system_dir_str)
      system_dir_charlist = String.to_charlist(system_dir_str)

      # Get secure binding parameters from IPsec manager if available
      {bind_ip, security_note} = get_secure_binding_params(port)

      # Get user credentials from configuration
      default_username = Application.get_env(:sftp_server, :default_username)
      default_password = Application.get_env(:sftp_server, :default_password)

      sftp_subsystem_options = [
        {:root, base_path_charlist},
        {:file_handler, SftpServer.Subsystem, []}
      ]
      sftp_subsystem_spec = :ssh_sftpd.subsystem_spec(sftp_subsystem_options)

      daemon_opts = [
        system_dir: system_dir_charlist,
        subsystems: [sftp_subsystem_spec],
        socket_options: [{:ip, bind_ip}, {:reuseaddr, true}],
        user_passwords: [{String.to_charlist(default_username), String.to_charlist(default_password)}]
      ]

      Logger.debug("SFTP Daemon opts#{security_note}: #{inspect(daemon_opts)}")

      case :ssh.daemon(port, daemon_opts) do
        {:ok, daemon_ref} ->
          Logger.info("SFTP Server started on #{:inet.ntoa(bind_ip)}:#{port}#{security_note}")
          {:ok, %{daemon_ref: daemon_ref, base_path: base_path_str, bind_ip: bind_ip, security_note: security_note}}
        {:error, reason} ->
          Logger.error("Failed to start SFTP Server#{security_note}: #{inspect(reason)}")
          {:stop, reason}
      end
    rescue
      error ->
        Logger.error("Exception during SFTP Server initialization: #{inspect(error)}")
        {:stop, {:initialization_error, error}}
    catch
      kind, reason ->
        Logger.error("Caught #{kind} during SFTP Server initialization: #{inspect(reason)}")
        {:stop, {:initialization_error, {kind, reason}}}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      daemon_ref: inspect(state.daemon_ref),
      base_path: state.base_path,
      bind_ip: :inet.ntoa(state.bind_ip) |> List.to_string(),
      security_note: state.security_note,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    {:reply, {:ok, status}, state}
  end

  @impl true
  def terminate(_reason, %{daemon_ref: daemon_ref, security_note: security_note}) do
    Logger.info("Stopping SFTP Server#{security_note}")
    :ssh.stop_daemon(daemon_ref)
  end

  # Helper to get secure binding parameters from IPsec manager
  defp get_secure_binding_params(_default_port) do
    # Check if security enforcement is enabled
    ipsec_config = Application.get_env(:sftp_server, :ipsec_tunnel, [])
    enforce_security = Keyword.get(ipsec_config, :enforce_security, true)

    # Get retry configuration from application config
    ipsec_manager_config = Application.get_env(:sftp_server, :ipsec_manager, [])
    retry_attempts = Keyword.get(ipsec_manager_config, :security_retry_attempts, 3)
    retry_delay_ms = Keyword.get(ipsec_manager_config, :security_retry_delay_ms, 2000)

    case get_ipsec_binding_params_with_retry(enforce_security, retry_attempts, retry_delay_ms) do
      {:ok, secure_params} ->
        Logger.info("[SftpServer] Using secure IPsec tunnel binding: #{inspect(secure_params)}")
        ip_tuple = parse_ip_address(secure_params.bind_ip)
        {ip_tuple, " [SECURE IPsec Tunnel]"}

      {:error, :tunnel_not_active} when enforce_security ->
        Logger.error("[SftpServer] SECURITY ENFORCED: IPsec tunnel not active after waiting, blocking server startup")
        raise RuntimeError, "IPsec tunnel required but not active. Server startup blocked for security."

      {:error, :ipsec_disabled} when enforce_security ->
        Logger.error("[SftpServer] SECURITY ENFORCED: IPsec disabled, blocking server startup")
        raise RuntimeError, "IPsec tunnel required but disabled. Server startup blocked for security."

      {:error, :ipsec_manager_not_available} when enforce_security ->
        Logger.error("[SftpServer] SECURITY ENFORCED: IPsec manager not available after waiting, blocking server startup")
        raise RuntimeError, "IPsec tunnel required but manager not available. Server startup blocked for security."

      {:error, :tunnel_not_active} ->
        Logger.warning("[SftpServer] IPsec tunnel not active, using standard binding (security not enforced)")
        {{0,0,0,0}, " [Standard Binding]"}

      {:error, :ipsec_disabled} ->
        Logger.warning("[SftpServer] IPsec disabled by configuration, using standard binding (security not enforced)")
        {{0,0,0,0}, " [Standard Binding]"}

      {:error, :ipsec_manager_not_available} ->
        Logger.warning("[SftpServer] IPsec manager not available, using standard binding (security not enforced)")
        {{0,0,0,0}, " [Standard Binding]"}
    end
  end

  defp get_ipsec_binding_params_with_retry(enforce_security, retries, delay_ms) when retries > 0 do
    case get_ipsec_binding_params() do
      {:ok, secure_params} ->
        {:ok, secure_params}

      {:error, :ipsec_manager_not_available} when enforce_security ->
        Logger.info("[SftpServer] IPsec manager not ready, waiting #{delay_ms}ms... (#{retries} retries left)")
        Process.sleep(delay_ms)
        get_ipsec_binding_params_with_retry(enforce_security, retries - 1, delay_ms)

      {:error, :tunnel_not_active} when enforce_security ->
        Logger.info("[SftpServer] IPsec tunnel not active, waiting #{delay_ms}ms... (#{retries} retries left)")
        Process.sleep(delay_ms)
        get_ipsec_binding_params_with_retry(enforce_security, retries - 1, delay_ms)

      error_result ->
        error_result
    end
  end

  defp get_ipsec_binding_params_with_retry(_enforce_security, 0, _delay_ms) do
    # Final attempt without retry
    get_ipsec_binding_params()
  end

  defp get_ipsec_binding_params do
    try do
      case Process.whereis(SftpServer.IPsecManager) do
        nil ->
          {:error, :ipsec_manager_not_available}

        _pid ->
          case SftpServer.IPsecManager.get_secure_binding_params() do
            {:error, :ipsec_disabled} ->
              {:error, :ipsec_disabled}
            other_result ->
              other_result
          end
      end
    rescue
      error ->
        Logger.warning("[SftpServer] Error getting secure binding params: #{inspect(error)}")
        {:error, :ipsec_manager_not_available}
    end
  end

  defp parse_ip_address(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} ->
        ip_tuple

      {:error, _reason} ->
        Logger.warning("[SftpServer] Failed to parse IP address: #{ip_string}, using 0.0.0.0")
        {0,0,0,0}
    end
  end
end

defmodule SftpServer.Subsystem do
  @behaviour :ssh_sftpd_file_api
  require Logger

  # File operation callbacks - all must return {result, state} tuple
  def close(io_device, state) do
    result = File.close(io_device)
    {result, state}
  end

  def delete(path, state) do
    full_path = Path.join(state.root, path)
    result = case File.rm(full_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def del_dir(path, state) do
    full_path = Path.join(state.root, path)
    result = case File.rmdir(full_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def get_cwd(state) do
    {{:ok, state.root}, state}
  end

  def is_dir(path, state) do
    full_path = Path.join(state.root, path)
    result = File.dir?(full_path)
    {result, state}
  end

  def list_dir(path, state) do
    # Path is relative to the current SFTP CWD, which starts at state.root.
    # For simplicity, we assume path is always relative to state.root here.
    # A more robust implementation would track CWD changes.
    full_path = Path.join(state.root, path)
    Logger.debug("SFTP Subsystem: Listing directory '#{path}' resolved to '#{full_path}' (root: '#{state.root}')")
    result = case File.ls(full_path) do
      {:ok, files} -> {:ok, files}
      {:error, reason} ->
        Logger.error("SFTP Subsystem: Error listing '#{full_path}': #{inspect(reason)}")
        {:error, reason}
    end
    {result, state}
  end

  def make_dir(path, state) do
    full_path = Path.join(state.root, path)
    result = case File.mkdir(full_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def make_symlink(path2, path, state) do
    full_path = Path.join(state.root, path)
    full_path2 = Path.join(state.root, path2)
    result = case File.ln_s(full_path2, full_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def open(path, flags, state) do
    full_path = Path.join(state.root, path)
    Logger.debug("SFTP Subsystem: Opening file '#{path}' resolved to '#{full_path}' with flags #{inspect(flags)}")
    result = case :file.open(full_path, flags) do
      {:ok, io_device} -> {:ok, io_device}
      {:error, reason} ->
        Logger.error("SFTP Subsystem: Error opening '#{full_path}': #{inspect(reason)}")
        {:error, reason}
    end
    {result, state}
  end

  def position(io_device, offset, state) do
    result = case :file.position(io_device, offset) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def read(io_device, len, state) do
    result = case :file.read(io_device, len) do
      {:ok, data} -> {:ok, data}
      :eof -> :eof
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def read_link(path, state) do
    full_path = Path.join(state.root, path)
    result = case File.read_link(full_path) do
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def read_link_info(path, state) do
    read_file_info(path, state)
  end

  def rename(path, path2, state) do
    full_path = Path.join(state.root, path)
    full_path2 = Path.join(state.root, path2)
    result = case File.rename(full_path, full_path2) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def write(io_device, data, state) do
    result = case :file.write(io_device, data) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def write_file_info(path, info, state) do
    full_path = Path.join(state.root, path)
    result = case :file.write_file_info(full_path, info) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
    {result, state}
  end

  def read_file_info(path, state) do
    full_path = Path.join(state.root, path)
    Logger.debug("SFTP Subsystem: Reading file info for '#{path}' resolved to '#{full_path}'")
    result = case :file.read_file_info(full_path) do
      {:ok, info} -> {:ok, info}
      {:error, reason} ->
        Logger.error("SFTP Subsystem: Error reading file info for '#{full_path}': #{inspect(reason)}")
        {:error, reason}
    end
    {result, state}
  end
end
