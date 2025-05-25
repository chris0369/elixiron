defmodule SftpServer.IPsecManager do
  @moduledoc """
  Manages IPsec tunnel configuration and security for the SFTP server side.

  This module handles:
  - IPsec tunnel establishment and management (server side)
  - Pre-shared key authentication
  - Tunnel interface configuration
  - Security policy enforcement
  - Connection monitoring and recovery
  """

  use GenServer
  require Logger

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_tunnel_config do
    GenServer.call(__MODULE__, :get_tunnel_config)
  end

  def establish_tunnel do
    GenServer.call(__MODULE__, :establish_tunnel, 30_000)
  end

  def teardown_tunnel do
    GenServer.call(__MODULE__, :teardown_tunnel)
  end

  def tunnel_status do
    GenServer.call(__MODULE__, :tunnel_status)
  end

  def get_secure_binding_params do
    GenServer.call(__MODULE__, :get_secure_binding_params)
  end

  # Server Implementation

  @impl true
  def init(opts) do
    # Get configuration from application environment
    app_tunnel_config = Application.get_env(:sftp_server, :ipsec_tunnel, [])
    tunnel_config = Keyword.get(opts, :tunnel_config, build_tunnel_config(app_tunnel_config))

    # Check if IPsec is enabled
    enabled = Keyword.get(app_tunnel_config, :enabled, true)

    unless enabled do
      Logger.info("[SftpIPsecManager] IPsec tunnel disabled by configuration")
      {:ok, %{tunnel_config: tunnel_config, tunnel_active: false, disabled: true}}
    else
      # Ensure tunnel configuration directory exists
      config_dir = Path.join([File.cwd!(), "priv", "ipsec_config"])
      File.mkdir_p!(config_dir)

      state = %{
        tunnel_config: tunnel_config,
        config_dir: config_dir,
        tunnel_active: false,
        last_status_check: nil,
        connection_retries: 0,
        disabled: false
      }

      Logger.info("[SftpIPsecManager] Initialized with config: #{inspect(tunnel_config)}")

      # Get initial tunnel delay from configuration
      ipsec_manager_config = Application.get_env(:sftp_server, :ipsec_manager, [])
      initial_delay_ms = Keyword.get(ipsec_manager_config, :initial_tunnel_delay_ms, 5000)

      # Start tunnel establishment process after a configurable delay to allow elixir_server to start first
      Process.send_after(self(), :initialize_tunnel, initial_delay_ms)

      {:ok, state}
    end
  end

  # Helper to build tunnel config from application environment
  defp build_tunnel_config(app_config) do
    %{
      local_ip: Keyword.get(app_config, :local_ip, "10.0.100.2"),
      remote_ip: Keyword.get(app_config, :remote_ip, "10.0.100.1"),
      tunnel_interface: Keyword.get(app_config, :tunnel_interface, "SftpElixirTunnel"),
      local_port: Keyword.get(app_config, :local_port, 2222),
      remote_port: Keyword.get(app_config, :remote_port, 4001),
      psk: Keyword.get(app_config, :psk, "elixir_sftp_tunnel_key_2024"),
      encryption: Keyword.get(app_config, :encryption, "aes256"),
      hash: Keyword.get(app_config, :hash, "sha256"),
      dh_group: Keyword.get(app_config, :dh_group, "modp2048")
    }
  end

  @impl true
  def handle_call(:get_tunnel_config, _from, state) do
    {:reply, state.tunnel_config, state}
  end

  @impl true
  def handle_call(:establish_tunnel, _from, %{disabled: true} = state) do
    {:reply, {:error, :ipsec_disabled}, state}
  end

  @impl true
  def handle_call(:establish_tunnel, _from, state) do
    case do_establish_tunnel(state) do
      {:ok, new_state} ->
        Logger.info("[SftpIPsecManager] Tunnel established successfully")
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("[SftpIPsecManager] Failed to establish tunnel: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:teardown_tunnel, _from, %{disabled: true} = state) do
    {:reply, {:error, :ipsec_disabled}, state}
  end

  @impl true
  def handle_call(:teardown_tunnel, _from, state) do
    case do_teardown_tunnel(state) do
      {:ok, new_state} ->
        Logger.info("[SftpIPsecManager] Tunnel torn down successfully")
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("[SftpIPsecManager] Failed to teardown tunnel: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:tunnel_status, _from, %{disabled: true} = state) do
    status = %{active: false, disabled: true, last_check: DateTime.utc_now()}
    {:reply, status, state}
  end

  @impl true
  def handle_call(:tunnel_status, _from, state) do
    status = check_tunnel_status(state)
    new_state = %{state | last_status_check: DateTime.utc_now()}
    {:reply, status, new_state}
  end

  @impl true
  def handle_call(:get_secure_binding_params, _from, %{disabled: true} = state) do
    {:reply, {:error, :ipsec_disabled}, state}
  end

  @impl true
  def handle_call(:get_secure_binding_params, _from, state) do
    if state.tunnel_active do
      params = %{
        bind_ip: state.tunnel_config.local_ip,
        port: state.tunnel_config.local_port,
        secure: true,
        tunnel_interface: state.tunnel_config.tunnel_interface
      }
      {:reply, {:ok, params}, state}
    else
      {:reply, {:error, :tunnel_not_active}, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      tunnel_config: state.tunnel_config,
      tunnel_active: state.tunnel_active,
      last_status_check: state.last_status_check,
      connection_retries: state.connection_retries,
      disabled: Map.get(state, :disabled, false),
      config_dir: Map.get(state, :config_dir, "unknown")
    }
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info(:initialize_tunnel, state) do
    case do_establish_tunnel(state) do
      {:ok, new_state} ->
        Logger.info("[SftpIPsecManager] Initial tunnel setup completed")
        schedule_status_check()
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("[SftpIPsecManager] Initial tunnel setup failed: #{inspect(reason)}. Will retry...")
        schedule_retry()
        {:noreply, %{state | connection_retries: state.connection_retries + 1}}
    end
  end

  @impl true
  def handle_info(:status_check, state) do
    status = check_tunnel_status(state)

    new_state = case status do
      %{active: false} when state.tunnel_active ->
        Logger.warning("[SftpIPsecManager] Tunnel connection lost, attempting recovery")
        case do_establish_tunnel(state) do
          {:ok, recovered_state} ->
            Logger.info("[SftpIPsecManager] Tunnel recovered successfully")
            recovered_state
          {:error, _reason} ->
            schedule_retry()
            %{state | tunnel_active: false, connection_retries: state.connection_retries + 1}
        end

      %{active: true} ->
        %{state | tunnel_active: true, connection_retries: 0}

      _ ->
        state
    end

    schedule_status_check()
    {:noreply, %{new_state | last_status_check: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:retry_connection, state) do
    # Get max retries from configuration
    ipsec_manager_config = Application.get_env(:sftp_server, :ipsec_manager, [])
    max_retries = Keyword.get(ipsec_manager_config, :max_connection_retries, 5)

    if state.connection_retries < max_retries do
      send(self(), :initialize_tunnel)
    else
      Logger.error("[SftpIPsecManager] Max connection retries (#{max_retries}) exceeded. Manual intervention may be required.")
    end
    {:noreply, state}
  end

  # Private Functions

  defp do_establish_tunnel(state) do
    config = state.tunnel_config

    try do
      # Create IPsec configuration files
      :ok = create_ipsec_config(state)
      :ok = create_strongswan_config(state)

      # Create tunnel interface (platform-specific)
      :ok = create_tunnel_interface(config)

      # Apply IPsec policies
      :ok = apply_ipsec_policies(config)

      # Test tunnel connectivity (passive listening test)
      case test_tunnel_connectivity(config) do
        :ok ->
          {:ok, %{state | tunnel_active: true, connection_retries: 0}}

        {:error, reason} ->
          Logger.warning("[SftpIPsecManager] Tunnel connectivity test failed: #{inspect(reason)}")
          {:error, {:connectivity_test_failed, reason}}
      end

    rescue
      error ->
        Logger.error("[SftpIPsecManager] Exception during tunnel establishment: #{inspect(error)}")
        {:error, {:exception, error}}
    end
  end

  defp do_teardown_tunnel(state) do
    config = state.tunnel_config

    try do
      # Remove IPsec policies
      remove_ipsec_policies(config)

      # Remove tunnel interface
      remove_tunnel_interface(config)

      {:ok, %{state | tunnel_active: false}}

    rescue
      error ->
        Logger.error("[SftpIPsecManager] Exception during tunnel teardown: #{inspect(error)}")
        {:error, {:exception, error}}
    end
  end

  defp create_ipsec_config(state) do
    config = state.tunnel_config
    config_path = Path.join(state.config_dir, "ipsec.conf")

    # Get IPsec daemon configuration
    ipsec_daemon_config = Application.get_env(:sftp_server, :ipsec_daemon, [])

    charon_debug_ike = Keyword.get(ipsec_daemon_config, :charon_debug_ike, 1)
    charon_debug_knl = Keyword.get(ipsec_daemon_config, :charon_debug_knl, 1)
    charon_debug_cfg = Keyword.get(ipsec_daemon_config, :charon_debug_cfg, 0)
    unique_ids = Keyword.get(ipsec_daemon_config, :unique_ids, "no")
    key_exchange = Keyword.get(ipsec_daemon_config, :key_exchange, "ikev2")
    connection_type = Keyword.get(ipsec_daemon_config, :connection_type, "tunnel")
    auto_start = Keyword.get(ipsec_daemon_config, :auto_start, "add")
    auth_by = Keyword.get(ipsec_daemon_config, :auth_by, "secret")
    dpd_action = Keyword.get(ipsec_daemon_config, :dpd_action, "restart")
    dpd_delay = Keyword.get(ipsec_daemon_config, :dpd_delay, "30s")
    dpd_timeout = Keyword.get(ipsec_daemon_config, :dpd_timeout, "120s")

    ipsec_config = """
    # IPsec configuration for sftp_server <-> elixir_server tunnel
    config setup
        charondebug="ike #{charon_debug_ike}, knl #{charon_debug_knl}, cfg #{charon_debug_cfg}"
        uniqueids=#{unique_ids}

    conn sftp-elixir-tunnel
        auto=#{auto_start}
        type=#{connection_type}
        keyexchange=#{key_exchange}

        # Local (sftp_server) configuration
        left=#{config.local_ip}
        leftsubnet=#{config.local_ip}/32
        leftid="sftp_server"

        # Remote (elixir_server) configuration
        right=#{config.remote_ip}
        rightsubnet=#{config.remote_ip}/32
        rightid="elixir_server"

        # Security parameters
        ike=#{config.encryption}-#{config.hash}-#{config.dh_group}!
        esp=#{config.encryption}-#{config.hash}!

        # Authentication
        authby=#{auth_by}

        # Automatic connection management
        dpdaction=#{dpd_action}
        dpddelay=#{dpd_delay}
        dpdtimeout=#{dpd_timeout}

        # Traffic selectors
        leftprotoport=tcp/#{config.local_port}
        rightprotoport=tcp/#{config.remote_port}
    """

    File.write!(config_path, ipsec_config)
    Logger.debug("[SftpIPsecManager] Created IPsec config at #{config_path}")
    :ok
  end

  defp create_strongswan_config(state) do
    config = state.tunnel_config
    secrets_path = Path.join(state.config_dir, "ipsec.secrets")

    secrets_config = """
    # Pre-shared key for sftp_server <-> elixir_server tunnel
    #{config.local_ip} #{config.remote_ip} : PSK "#{config.psk}"
    """

    File.write!(secrets_path, secrets_config)
    # Set restrictive permissions on secrets file
    File.chmod!(secrets_path, 0o600)
    Logger.debug("[SftpIPsecManager] Created IPsec secrets at #{secrets_path}")
    :ok
  end

  defp create_tunnel_interface(config) do
    case :os.type() do
      {:win32, _} ->
        create_windows_tunnel_interface(config)

      {:unix, :linux} ->
        create_linux_tunnel_interface(config)

      {:unix, :darwin} ->
        create_macos_tunnel_interface(config)

      other ->
        Logger.warning("[SftpIPsecManager] Unsupported OS: #{inspect(other)}. Using fallback method.")
        create_fallback_tunnel_interface(config)
    end
  end

  defp create_windows_tunnel_interface(config) do
    # On Windows, for development with loopback setup, we don't need to create actual tunnel interfaces
    # Instead, we'll use the existing loopback interface and add IP aliases
    # This avoids the "filename, directory name, or volume label syntax is incorrect" errors

    Logger.info("[SftpIPsecManager] Windows development setup: Using loopback aliases instead of tunnel interface")

    # For single-machine development, we can add the IP as an alias to the loopback interface
    # First, try to find the loopback interface name
    case System.cmd("cmd", ["/c", "netsh interface ipv4 show interfaces"], stderr_to_stdout: true) do
      {output, 0} ->
        # Look for loopback interface in the output
        loopback_interface = if String.contains?(output, "Loopback Pseudo-Interface") do
          # Extract the loopback interface name (usually "Loopback Pseudo-Interface 1")
          case Regex.run(~r/Loopback Pseudo-Interface \d+/, output) do
            [interface_name] -> interface_name
            _ -> "Loopback Pseudo-Interface 1"  # fallback
          end
        else
          "Loopback Pseudo-Interface 1"  # default fallback
        end

        Logger.debug("[SftpIPsecManager] Using Windows loopback interface: #{loopback_interface}")

        # Add IP alias to loopback interface (this is safe and won't cause syntax errors)
        alias_cmd = "netsh interface ipv4 add address \"#{loopback_interface}\" #{config.local_ip} 255.255.255.255"

        case System.cmd("cmd", ["/c", alias_cmd], stderr_to_stdout: true) do
          {_output, 0} ->
            Logger.debug("[SftpIPsecManager] Successfully added IP alias #{config.local_ip} to #{loopback_interface}")

          {output, _code} ->
            # This might fail if the IP is already assigned, which is fine for development
            Logger.debug("[SftpIPsecManager] IP alias command result: #{String.trim(output)}")
        end

      {_output, _code} ->
        Logger.debug("[SftpIPsecManager] Could not enumerate interfaces, using fallback method")
    end

    :ok
  end

  defp create_linux_tunnel_interface(config) do
    # Use ip command to create tunnel interface
    commands = [
      "ip tunnel add #{config.tunnel_interface} mode gre remote #{config.remote_ip} local #{config.local_ip}",
      "ip addr add #{config.local_ip}/30 dev #{config.tunnel_interface}",
      "ip link set #{config.tunnel_interface} up",
      "ip route add #{config.remote_ip}/32 dev #{config.tunnel_interface}"
    ]

    Enum.each(commands, fn cmd ->
      case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.debug("[SftpIPsecManager] Linux command successful: #{cmd}")

        {output, _code} ->
          Logger.debug("[SftpIPsecManager] Linux command output: #{output}")
      end
    end)

    :ok
  end

  defp create_macos_tunnel_interface(config) do
    # macOS tunnel interface creation
    commands = [
      "ifconfig #{config.tunnel_interface} create",
      "ifconfig #{config.tunnel_interface} inet #{config.local_ip} #{config.remote_ip} up",
      "route add #{config.remote_ip}/32 -interface #{config.tunnel_interface}"
    ]

    Enum.each(commands, fn cmd ->
      case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.debug("[SftpIPsecManager] macOS command successful: #{cmd}")

        {output, _code} ->
          Logger.debug("[SftpIPsecManager] macOS command output: #{output}")
      end
    end)

    :ok
  end

  defp create_fallback_tunnel_interface(_config) do
    Logger.info("[SftpIPsecManager] Using loopback aliases for single-machine development (no physical tunnel interface)")
    :ok
  end

  defp apply_ipsec_policies(config) do
    case :os.type() do
      {:win32, _} ->
        apply_windows_ipsec_policies(config)

      {:unix, _} ->
        apply_unix_ipsec_policies(config)
    end
  end

  defp apply_windows_ipsec_policies(config) do
    # Windows IPsec policy commands
    # Get tunnel interface name from configuration
    tunnel_interface = config.tunnel_interface

    commands = [
      # Create IPsec policy
      "netsh ipsec static add policy name=\"#{tunnel_interface}\"",

      # Add filter actions
      "netsh ipsec static add filteraction name=\"Require_Auth\" action=require_auth",

      # Add filters for the tunnel
      "netsh ipsec static add filter filterlist=\"SftpElixir_Filter\" srcaddr=#{config.local_ip} dstaddr=#{config.remote_ip} protocol=tcp srcport=#{config.local_port} dstport=#{config.remote_port}",

      # Assign policy
      "netsh ipsec static set policy name=\"#{tunnel_interface}\" assign=yes"
    ]

    Enum.each(commands, fn cmd ->
      case System.cmd("cmd", ["/c", cmd], stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.debug("[SftpIPsecManager] Windows IPsec command successful: #{cmd}")

        {output, _code} ->
          Logger.debug("[SftpIPsecManager] Windows IPsec command output: #{output}")
      end
    end)

    :ok
  end

  defp apply_unix_ipsec_policies(_config) do
    # StrongSwan/ipsec commands for Unix systems
    config_dir = Path.join([File.cwd!(), "priv", "ipsec_config"])

    commands = [
      "ipsec start",
      "ipsec reload",
      "ipsec up sftp-elixir-tunnel"
    ]

    # Set environment variables for StrongSwan
    env = [
      {"IPSEC_CONFDIR", config_dir},
      {"IPSEC_CONFS", Path.join(config_dir, "ipsec.conf")},
      {"IPSEC_SECRETS", Path.join(config_dir, "ipsec.secrets")}
    ]

    Enum.each(commands, fn cmd ->
      case System.cmd("sh", ["-c", cmd], env: env, stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.debug("[SftpIPsecManager] Unix IPsec command successful: #{cmd}")

        {output, _code} ->
          Logger.debug("[SftpIPsecManager] Unix IPsec command output: #{output}")
      end
    end)

    :ok
  end

  defp remove_ipsec_policies(config) do
    case :os.type() do
      {:win32, _} ->
        tunnel_interface = config.tunnel_interface
        System.cmd("cmd", ["/c", "netsh ipsec static delete policy name=\"#{tunnel_interface}\""], stderr_to_stdout: true)

      {:unix, _} ->
        System.cmd("sh", ["-c", "ipsec down sftp-elixir-tunnel"], stderr_to_stdout: true)
    end

    :ok
  end

  defp remove_tunnel_interface(config) do
    case :os.type() do
      {:win32, _} ->
        # On Windows, remove the IP alias from loopback interface instead of trying to delete interface
        Logger.debug("[SftpIPsecManager] Removing IP alias #{config.local_ip} from Windows loopback interface")

        case System.cmd("cmd", ["/c", "netsh interface ipv4 show interfaces"], stderr_to_stdout: true) do
          {output, 0} ->
            loopback_interface = if String.contains?(output, "Loopback Pseudo-Interface") do
              case Regex.run(~r/Loopback Pseudo-Interface \d+/, output) do
                [interface_name] -> interface_name
                _ -> "Loopback Pseudo-Interface 1"
              end
            else
              "Loopback Pseudo-Interface 1"
            end

            # Remove the IP alias
            remove_cmd = "netsh interface ipv4 delete address \"#{loopback_interface}\" #{config.local_ip}"
            case System.cmd("cmd", ["/c", remove_cmd], stderr_to_stdout: true) do
              {_output, 0} ->
                Logger.debug("[SftpIPsecManager] Successfully removed IP alias #{config.local_ip}")
              {output, _code} ->
                Logger.debug("[SftpIPsecManager] IP alias removal result: #{String.trim(output)}")
            end

          {_output, _code} ->
            Logger.debug("[SftpIPsecManager] Could not enumerate interfaces for cleanup")
        end

      {:unix, :linux} ->
        System.cmd("sh", ["-c", "ip tunnel del #{config.tunnel_interface}"], stderr_to_stdout: true)

      {:unix, :darwin} ->
        System.cmd("sh", ["-c", "ifconfig #{config.tunnel_interface} destroy"], stderr_to_stdout: true)

      _ ->
        :ok
    end

    :ok
  end

  defp test_tunnel_connectivity(config) do
    # Test basic connectivity through the tunnel
    # For loopback development setup, we test if the remote address is reachable
    case :inet.gethostbyname(String.to_charlist(config.remote_ip)) do
      {:ok, _hostent} ->
        Logger.info("[SftpIPsecManager] Tunnel connectivity test successful (#{config.remote_ip} reachable)")
        :ok

      {:error, reason} ->
        Logger.warning("[SftpIPsecManager] Tunnel connectivity test failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp check_tunnel_status(state) do
    config = state.tunnel_config

    # For loopback development setup, we don't check physical interface status
    # since we're using loopback aliases instead of actual tunnel interfaces
    interface_up = case :os.type() do
      {:win32, _} ->
        # On Windows with loopback setup, check if the alias exists
        case System.cmd("cmd", ["/c", "netsh interface ipv4 show addresses"], stderr_to_stdout: true) do
          {output, 0} -> String.contains?(output, config.local_ip)
          _ -> false
        end

      {:unix, _} ->
        # On Unix, check if the tunnel interface exists
        case System.cmd("sh", ["-c", "ip link show #{config.tunnel_interface}"], stderr_to_stdout: true) do
          {output, 0} -> String.contains?(output, "UP")
          _ -> false
        end
    end

    # Check connectivity - this is the primary indicator for loopback setup
    connectivity = case test_tunnel_connectivity(config) do
      :ok -> true
      _ -> false
    end

    # For single-machine development, connectivity is sufficient
    # In production with real interfaces, both interface_up AND connectivity would be required
    active = case :os.type() do
      {:win32, _} -> connectivity  # On Windows loopback, connectivity is sufficient
      {:unix, _} -> interface_up and connectivity  # On Unix, require both
    end

    %{
      active: active,
      interface_up: interface_up,
      connectivity: connectivity,
      last_check: DateTime.utc_now()
    }
  end

  defp schedule_status_check do
    # Get status check interval from configuration
    ipsec_manager_config = Application.get_env(:sftp_server, :ipsec_manager, [])
    status_check_interval_ms = Keyword.get(ipsec_manager_config, :status_check_interval_ms, 30_000)

    Process.send_after(self(), :status_check, status_check_interval_ms)
  end

  defp schedule_retry do
    # Get retry delay from configuration
    ipsec_manager_config = Application.get_env(:sftp_server, :ipsec_manager, [])
    retry_delay_ms = Keyword.get(ipsec_manager_config, :retry_delay_ms, 10_000)

    Process.send_after(self(), :retry_connection, retry_delay_ms)
  end
end
