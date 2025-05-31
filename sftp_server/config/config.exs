import Config

# For development, create paths within the application's priv directory
# Ensure these directories exist or are creatable by the application/SSH daemon.
# sftp_server/priv/sftp_server/system_keys
# sftp_server/priv/sftp_server/user_home_template
app_base_dir = File.cwd!() # Should be C:\\repos\\electro_test\\sftp_server
app_priv_sftp_dir = Path.join([app_base_dir, "priv", "sftp_server"])

default_sftp_system_dir = Path.join(app_priv_sftp_dir, "system_keys")
default_sftp_user_dir_template = Path.join(app_priv_sftp_dir, "user_home_template")
default_sftp_base_data_path = Path.join(app_priv_sftp_dir, "sftp_data") # New default for SFTP root

# SFTP Server Configuration
config :sftp_server,
  # Network configuration
  port: String.to_integer(System.get_env("SFTP_PORT", "2222")), # SFTP server listening port
  health_port: String.to_integer(System.get_env("SFTP_HEALTH_PORT", "2223")), # Health check HTTP server port
  base_path: System.get_env("SFTP_BASE_PATH", default_sftp_base_data_path), # SFTP filesystem root

  # SSH daemon paths
  system_dir: System.get_env("SFTP_SYSTEM_DIR", default_sftp_system_dir), # SSH host keys directory
  user_dir: System.get_env("SFTP_USER_DIR", default_sftp_user_dir_template), # SSH user keys template directory

  # Default user credentials for development (should be overridden in production)
  default_username: System.get_env("SFTP_DEFAULT_USERNAME", "testuser"),
  default_password: System.get_env("SFTP_DEFAULT_PASSWORD", "testpass")

# IPsec tunnel configuration for SFTP server - SINGLE MACHINE DEVELOPMENT SETUP
# Uses loopback aliases for proper tunnel testing on one machine
config :sftp_server, :ipsec_tunnel,
  # Basic tunnel settings
  enabled: System.get_env("IPSEC_ENABLED", "true") == "true", # Enable/disable IPsec tunnel
  enforce_security: System.get_env("IPSEC_ENFORCE_SECURITY", "true") == "true", # Block startup if tunnel fails

  # Network endpoints
  local_ip: System.get_env("IPSEC_LOCAL_IP", "127.0.0.2"), # SFTP server tunnel endpoint
  remote_ip: System.get_env("IPSEC_REMOTE_IP", "127.0.0.1"), # Elixir server tunnel endpoint
  tunnel_interface: System.get_env("IPSEC_TUNNEL_INTERFACE", "SftpElixirTunnel"), # Virtual interface name
  local_port: String.to_integer(System.get_env("IPSEC_LOCAL_PORT", "2222")), # SFTP server port in tunnel
  remote_port: String.to_integer(System.get_env("IPSEC_REMOTE_PORT", "4001")), # Elixir server port in tunnel

  # Cryptographic settings
  psk: System.get_env("IPSEC_PSK", "elixir_sftp_tunnel_key_2024"), # Pre-shared key for authentication
  encryption: System.get_env("IPSEC_ENCRYPTION", "aes256"), # Encryption algorithm
  hash: System.get_env("IPSEC_HASH", "sha256"), # Hash algorithm for integrity
  dh_group: System.get_env("IPSEC_DH_GROUP", "modp2048") # Diffie-Hellman group for key exchange

# IPsec Manager Configuration
config :sftp_server, :ipsec_manager,
  # Connection management
  max_connection_retries: String.to_integer(System.get_env("IPSEC_MAX_RETRIES", "5")), # Max retries before giving up
  initial_tunnel_delay_ms: String.to_integer(System.get_env("IPSEC_INITIAL_DELAY_MS", "5000")), # Delay before first tunnel attempt
  retry_delay_ms: String.to_integer(System.get_env("IPSEC_RETRY_DELAY_MS", "10000")), # Delay between retry attempts
  status_check_interval_ms: String.to_integer(System.get_env("IPSEC_STATUS_CHECK_MS", "30000")), # Tunnel health check interval

  # Security binding retry configuration
  security_retry_attempts: String.to_integer(System.get_env("IPSEC_SECURITY_RETRY_ATTEMPTS", "3")), # Retries for secure binding
  security_retry_delay_ms: String.to_integer(System.get_env("IPSEC_SECURITY_RETRY_DELAY_MS", "2000")) # Delay between security retries

# IPsec Daemon Configuration (for ipsec.conf generation)
config :sftp_server, :ipsec_daemon,
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

IO.puts "config/config.exs loaded. SFTP server configured with single-machine development tunnel (127.0.0.2 <-> 127.0.0.1)."
