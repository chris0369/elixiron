# config/runtime.exs
import Config

# This file is loaded when the system starts and relies on
# environment variables to configure the application dynamically.

# --- Basic Application Configuration ---

# Configure the WebSocket listening port
# Reads from the PORT environment variable, defaulting to 4001.
websocket_port =
  System.get_env("PORT", "4001")
  |> String.to_integer()

# Set the websocket_port in the application environment for DesktopIntegrationServer.Application
config :desktop_integration_server, :websocket_port, websocket_port

# --- Erlang Distribution / Clustering ---

# The node name (e.g., myapp@192.168.1.100) and cookie are typically set
# via environment variables `RELEASE_NODE_NAME` and `RELEASE_COOKIE` before
# starting the release. The cookie ensures only nodes with the same
# secret can connect.

# Example: Read the cookie for potential use in other parts of the config
# (though setting it usually happens outside runtime.exs)
# Defaults to an INSECURE value - CHANGE THIS in production environments!
_release_cookie = System.get_env("RELEASE_COOKIE", "insecure_cookie_change_me")


# --- Other Runtime Configurations ---
# Add any other configuration that needs to be determined at runtime below.
# Example: Database URL
# config :my_app, MyApp.Repo, url: System.get_env("DATABASE_URL")

IO.puts("Runtime configuration loaded. WebSocket port: #{websocket_port}")
