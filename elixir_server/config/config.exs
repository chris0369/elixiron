import Config

# Configure the log level.
config :logger, level: :debug

# WebSocket server port
config :desktop_integration_server, :websocket_port, String.to_integer(System.get_env("WEBSOCKET_PORT", "4001"))

# IPsec tunnel configuration - SINGLE MACHINE DEVELOPMENT SETUP
# Uses loopback aliases for proper tunnel testing on one machine
config :desktop_integration_server, :ipsec_tunnel,
  enabled: System.get_env("IPSEC_ENABLED", "true") == "true", # Enable/disable IPsec tunnel
  enforce_security: System.get_env("IPSEC_ENFORCE_SECURITY", "true") == "true", # Block startup if tunnel fails
  local_ip: System.get_env("IPSEC_LOCAL_IP", "127.0.0.1"), # Elixir server tunnel endpoint
  remote_ip: System.get_env("IPSEC_REMOTE_IP", "127.0.0.2"), # SFTP server tunnel endpoint
  tunnel_interface: System.get_env("IPSEC_TUNNEL_INTERFACE", "ElixirSFTPTunnel"), # Virtual interface name
  local_port: String.to_integer(System.get_env("IPSEC_LOCAL_PORT", "4001")), # Elixir server port in tunnel
  remote_port: String.to_integer(System.get_env("IPSEC_REMOTE_PORT", "2222")), # SFTP server port in tunnel
  psk: System.get_env("IPSEC_PSK", "elixir_sftp_tunnel_key_2024"), # Pre-shared key for authentication
  encryption: System.get_env("IPSEC_ENCRYPTION", "aes256"), # Encryption algorithm
  hash: System.get_env("IPSEC_HASH", "sha256"), # Hash algorithm for integrity
  dh_group: System.get_env("IPSEC_DH_GROUP", "modp2048") # Diffie-Hellman group for key exchange

# IPsec Manager Configuration
config :desktop_integration_server, :ipsec_manager,
  # Connection management
  max_connection_retries: String.to_integer(System.get_env("IPSEC_MAX_RETRIES", "5")), # Max retries before giving up
  initial_tunnel_delay_ms: String.to_integer(System.get_env("IPSEC_INITIAL_DELAY_MS", "1000")), # Delay before first tunnel attempt
  retry_delay_ms: String.to_integer(System.get_env("IPSEC_RETRY_DELAY_MS", "10000")), # Delay between retry attempts
  status_check_interval_ms: String.to_integer(System.get_env("IPSEC_STATUS_CHECK_MS", "30000")), # Tunnel health check interval

  # GenServer call timeout for tunnel operations
  tunnel_operation_timeout_ms: String.to_integer(System.get_env("IPSEC_OPERATION_TIMEOUT_MS", "30000")) # Timeout for tunnel establish/teardown calls

# IPsec Daemon Configuration (for ipsec.conf generation)
config :desktop_integration_server, :ipsec_daemon,
  # StrongSwan/Charon debug settings
  charon_debug_ike: String.to_integer(System.get_env("IPSEC_DEBUG_IKE", "1")), # IKE protocol debug level
  charon_debug_knl: String.to_integer(System.get_env("IPSEC_DEBUG_KNL", "1")), # Kernel interface debug level
  charon_debug_cfg: String.to_integer(System.get_env("IPSEC_DEBUG_CFG", "0")), # Configuration debug level
  unique_ids: System.get_env("IPSEC_UNIQUE_IDS", "no"), # Allow multiple connections with same ID

  # IKE settings
  key_exchange: System.get_env("IPSEC_KEY_EXCHANGE", "ikev2"), # IKE version
  connection_type: System.get_env("IPSEC_CONNECTION_TYPE", "tunnel"), # Connection type
  auto_start: System.get_env("IPSEC_AUTO_START", "add"), # Auto-start behavior

  # Dead Peer Detection (DPD) settings
  dpd_action: System.get_env("IPSEC_DPD_ACTION", "restart"), # Action when peer is detected as dead
  dpd_delay: System.get_env("IPSEC_DPD_DELAY", "30s"), # Delay between DPD messages
  dpd_timeout: System.get_env("IPSEC_DPD_TIMEOUT", "120s"), # Timeout for DPD response

  # Authentication
  auth_by: System.get_env("IPSEC_AUTH_BY", "secret") # Authentication method

# FileStorage configuration with SFTP adapter - SECURE ONLY
config :desktop_integration_server, DesktopIntegrationServer.FileStorage,
  adapter: DesktopIntegrationServer.FileStorage.SFTPAdapter,
  sftp_config: [
    # Connection settings - will be overridden by IPsec tunnel parameters
    host: System.get_env("SFTP_HOST", "localhost"), # Fallback host (overridden by tunnel)
    port: String.to_integer(System.get_env("SFTP_PORT", "2222")), # Fallback port (overridden by tunnel)
    user: System.get_env("SFTP_USER", "testuser"), # SFTP username
    password: System.get_env("SFTP_PASSWORD", "testpass"), # SFTP password
    base_remote_path: System.get_env("SFTP_BASE_PATH", "/home/testuser"), # SFTP base directory

    # Connection timeouts and behavior
    connection_timeout_ms: String.to_integer(System.get_env("SFTP_CONNECTION_TIMEOUT_MS", "30000")), # SFTP connection timeout
    silently_accept_hosts: System.get_env("SFTP_ACCEPT_HOSTS", "true") == "true", # Accept unknown host keys
    user_interaction: System.get_env("SFTP_USER_INTERACTION", "false") == "true" # Allow user interaction
  ]

IO.puts "config/config.exs loaded. Logger level set to :debug. FileStorage and IPsec configured with single-machine development tunnel (127.0.0.1 ↔ 127.0.0.2)."
