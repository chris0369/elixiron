import Config

config :logger, :console,
  format: "[$level] $message\n",
  level: :info

# Production SFTP Server Configuration
# All sensitive values must be provided via environment variables in production
config :sftp_server,
  # Network configuration - required in production
  port: String.to_integer(System.get_env("SFTP_PORT") || raise("SFTP_PORT environment variable is required in production")),
  base_path: System.get_env("SFTP_BASE_PATH") || raise("SFTP_BASE_PATH environment variable is required in production"),

  # SSH daemon paths - required in production
  system_dir: System.get_env("SFTP_SYSTEM_DIR") || raise("SFTP_SYSTEM_DIR environment variable is required in production"),
  user_dir: System.get_env("SFTP_USER_DIR") || raise("SFTP_USER_DIR environment variable is required in production"),

  # User credentials - required in production (should use proper authentication system)
  default_username: System.get_env("SFTP_DEFAULT_USERNAME") || raise("SFTP_DEFAULT_USERNAME environment variable is required in production"),
  default_password: System.get_env("SFTP_DEFAULT_PASSWORD") || raise("SFTP_DEFAULT_PASSWORD environment variable is required in production")

# Production IPsec tunnel configuration
config :sftp_server, :ipsec_tunnel,
  # Security is enforced by default in production
  enabled: System.get_env("IPSEC_ENABLED", "true") == "true",
  enforce_security: System.get_env("IPSEC_ENFORCE_SECURITY", "true") == "true",

  # Network endpoints - must be real IPs in production
  local_ip: System.get_env("IPSEC_LOCAL_IP") || raise("IPSEC_LOCAL_IP environment variable is required in production"),
  remote_ip: System.get_env("IPSEC_REMOTE_IP") || raise("IPSEC_REMOTE_IP environment variable is required in production"),
  tunnel_interface: System.get_env("IPSEC_TUNNEL_INTERFACE") || raise("IPSEC_TUNNEL_INTERFACE environment variable is required in production"),
  local_port: String.to_integer(System.get_env("IPSEC_LOCAL_PORT") || raise("IPSEC_LOCAL_PORT environment variable is required in production")),
  remote_port: String.to_integer(System.get_env("IPSEC_REMOTE_PORT") || raise("IPSEC_REMOTE_PORT environment variable is required in production")),

  # Cryptographic settings - must be provided in production
  psk: System.get_env("IPSEC_PSK") || raise("IPSEC_PSK environment variable is required in production"),
  encryption: System.get_env("IPSEC_ENCRYPTION", "aes256"),
  hash: System.get_env("IPSEC_HASH", "sha256"),
  dh_group: System.get_env("IPSEC_DH_GROUP", "modp2048")

# Production IPsec Manager Configuration
config :sftp_server, :ipsec_manager,
  # More conservative retry settings for production
  max_connection_retries: String.to_integer(System.get_env("IPSEC_MAX_RETRIES", "10")),
  initial_tunnel_delay_ms: String.to_integer(System.get_env("IPSEC_INITIAL_DELAY_MS", "10000")),
  retry_delay_ms: String.to_integer(System.get_env("IPSEC_RETRY_DELAY_MS", "30000")),
  status_check_interval_ms: String.to_integer(System.get_env("IPSEC_STATUS_CHECK_MS", "60000")),

  # More retries for security binding in production
  security_retry_attempts: String.to_integer(System.get_env("IPSEC_SECURITY_RETRY_ATTEMPTS", "5")),
  security_retry_delay_ms: String.to_integer(System.get_env("IPSEC_SECURITY_RETRY_DELAY_MS", "5000"))

# Production IPsec Daemon Configuration
config :sftp_server, :ipsec_daemon,
  # Reduced debug output for production
  charon_debug_ike: String.to_integer(System.get_env("IPSEC_DEBUG_IKE", "0")),
  charon_debug_knl: String.to_integer(System.get_env("IPSEC_DEBUG_KNL", "0")),
  charon_debug_cfg: String.to_integer(System.get_env("IPSEC_DEBUG_CFG", "0")),
  unique_ids: System.get_env("IPSEC_UNIQUE_IDS", "no"),

  # Production IKE settings
  key_exchange: System.get_env("IPSEC_KEY_EXCHANGE", "ikev2"),
  connection_type: System.get_env("IPSEC_CONNECTION_TYPE", "tunnel"),
  auto_start: System.get_env("IPSEC_AUTO_START", "add"),

  # Production DPD settings - more aggressive monitoring
  dpd_action: System.get_env("IPSEC_DPD_ACTION", "restart"),
  dpd_delay: System.get_env("IPSEC_DPD_DELAY", "15s"),
  dpd_timeout: System.get_env("IPSEC_DPD_TIMEOUT", "60s"),

  # Authentication
  auth_by: System.get_env("IPSEC_AUTH_BY", "secret")
