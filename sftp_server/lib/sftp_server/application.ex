defmodule SftpServer.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:sftp_server, :port)
    base_path = Application.get_env(:sftp_server, :base_path)
    health_port = Application.get_env(:sftp_server, :health_port, 2223)

    children = [
      # Start IPsec manager first to establish secure tunnel
      {SftpServer.IPsecManager, []},

      {SftpServer.Server, [port: port, base_path: base_path]},

      # Add health check HTTP server
      {Plug.Cowboy,
        scheme: :http,
        plug: {SftpServer.HealthRouter, []},
        options: [port: health_port]
      }
    ]

    opts = [strategy: :one_for_one, name: SftpServer.Supervisor]
    Logger.info("Starting SFTP Server on port #{port} with IPsec security")
    Logger.info("Starting SFTP Health Check Server on port #{health_port}")
    Supervisor.start_link(children, opts)
  end
end
