defmodule SftpServer.HealthRouter do
  use Plug.Router
  import Plug.Conn
  require Logger

  plug :match
  plug :dispatch

  # Health check endpoint
  get "/health" do
    health_status = get_health_status()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(health_status))
  end

  # Detailed status endpoint
  get "/status" do
    detailed_status = get_detailed_status()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(detailed_status))
  end

  # Root endpoint
  get "/" do
    send_resp(conn, 200, "SFTP Server Health Check API is running. Use /health or /status endpoints.")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  # Helper functions for health checks
  defp get_health_status() do
    %{
      status: "healthy",
      service: "sftp_server",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      uptime_seconds: get_uptime_seconds(),
      ipsec_status: get_ipsec_status(),
      sftp_server_status: get_sftp_server_status()
    }
  end

  defp get_detailed_status() do
    %{
      service: "sftp_server",
      status: "healthy",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      uptime_seconds: get_uptime_seconds(),
      system_info: %{
        erlang_version: System.version(),
        elixir_version: System.version(),
        node_name: Node.self(),
        memory_usage: :erlang.memory() |> Enum.into(%{}),
        process_count: :erlang.system_info(:process_count)
      },
      application_info: %{
        sftp_port: Application.get_env(:sftp_server, :port),
        health_port: Application.get_env(:sftp_server, :health_port, 2223),
        base_path: Application.get_env(:sftp_server, :base_path),
        ipsec_enabled: get_ipsec_config()[:enabled],
        security_enforced: get_ipsec_config()[:enforce_security]
      },
      ipsec_status: get_ipsec_status(),
      sftp_server_status: get_sftp_server_status(),
      supervisor_status: get_supervisor_status()
    }
  end

  defp get_uptime_seconds() do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  defp get_ipsec_config() do
    Application.get_env(:sftp_server, :ipsec_tunnel, [])
  end

  defp get_ipsec_status() do
    try do
      case GenServer.call(SftpServer.IPsecManager, :get_status, 5000) do
        {:ok, status} -> %{status: "active", details: status}
        {:error, reason} -> %{status: "error", reason: inspect(reason)}
      end
    catch
      :exit, {:timeout, _} -> %{status: "timeout", reason: "IPsec manager not responding"}
      :exit, {:noproc, _} -> %{status: "not_running", reason: "IPsec manager process not found"}
      kind, reason -> %{status: "error", reason: "#{kind}: #{inspect(reason)}"}
    end
  end

  defp get_sftp_server_status() do
    try do
      case GenServer.call(SftpServer.Server, :get_status, 5000) do
        {:ok, status} -> %{status: "running", details: status}
        {:error, reason} -> %{status: "error", reason: inspect(reason)}
      end
    catch
      :exit, {:timeout, _} -> %{status: "timeout", reason: "SFTP server not responding"}
      :exit, {:noproc, _} -> %{status: "not_running", reason: "SFTP server process not found"}
      kind, reason -> %{status: "error", reason: "#{kind}: #{inspect(reason)}"}
    end
  end

  defp get_supervisor_status() do
    try do
      children = Supervisor.which_children(SftpServer.Supervisor)
      %{
        supervisor_running: true,
        children_count: length(children),
        children: Enum.map(children, fn {id, pid, type, modules} ->
          %{
            id: id,
            pid: inspect(pid),
            type: type,
            modules: modules,
            status: if(is_pid(pid) and Process.alive?(pid), do: "running", else: "stopped")
          }
        end)
      }
    catch
      kind, reason -> %{supervisor_running: false, error: "#{kind}: #{inspect(reason)}"}
    end
  end
end
