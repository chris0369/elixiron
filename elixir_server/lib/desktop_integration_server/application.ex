defmodule DesktopIntegrationServer.Application do
  # Defines application start-up behavior
  use Application

  def start(_type, _args) do
    # Read the port from the application environment
    port = Application.get_env(:desktop_integration_server, :websocket_port)

    # Define the Plug pipeline with the WebSocket handler and IPsec manager
    children = [
      # Start IPsec manager first to establish secure tunnel
      {DesktopIntegrationServer.IPsecManager, []},

      {Plug.Cowboy,
        scheme: :http,
        plug: {DesktopIntegrationServer.Router, []},
        options: [port: port] # Use the configured port
      }
    ]

    # Start the web server under a supervisor
    opts = [strategy: :one_for_one, name: DesktopIntegrationServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule DesktopIntegrationServer.Router do
  # Basic Plug router (optional, could handle HTTP requests)
  use Plug.Router
  import Plug.Conn # Import Plug.Conn for upgrade_adapter

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

  # Route for WebSocket upgrade - simplified
    get "/ws" do # Removed :channel_id
    require Logger
    Logger.info("[Router] WebSocket upgrade request received")
    Logger.debug("[Router] Connection details: #{inspect(conn)}")

    # Pass handler as {Module, InitialArgs, Opts} tuple for Cowboy adapter
    # No channel_id in opts anymore
    result = upgrade_adapter(conn, :websocket, {DesktopIntegrationServer.WebSocketHandler, nil, %{}}) # Passing empty opts
    Logger.debug("[Router] upgrade_adapter result: #{inspect(result)}")
    result
  end

  # Existing HTTP route
  get "/" do
    send_resp(conn, 200, "Elixir server (DesktopIntegrationServer) is running. Connect via WebSocket at /ws") # Updated message
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  # Helper functions for health checks
  defp get_health_status() do
    %{
      status: "healthy",
      service: "elixir_server",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      uptime_seconds: get_uptime_seconds(),
      ipsec_status: get_ipsec_status(),
      sftp_connectivity: check_sftp_connectivity()
    }
  end

  defp get_detailed_status() do
    %{
      service: "elixir_server",
      status: "healthy",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      uptime_seconds: get_uptime_seconds(),
      system_info: %{
        erlang_version: System.version(),
        elixir_version: System.version(),
        node_name: Node.self(),
        memory_usage: :erlang.memory(),
        process_count: :erlang.system_info(:process_count)
      },
      application_info: %{
        websocket_port: Application.get_env(:desktop_integration_server, :websocket_port),
        ipsec_enabled: get_ipsec_config()[:enabled],
        security_enforced: get_ipsec_config()[:enforce_security]
      },
      ipsec_status: get_ipsec_status(),
      sftp_connectivity: check_sftp_connectivity(),
      supervisor_status: get_supervisor_status()
    }
  end

  defp get_uptime_seconds() do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  defp get_ipsec_config() do
    Application.get_env(:desktop_integration_server, :ipsec_tunnel, [])
  end

  defp get_ipsec_status() do
    try do
      case GenServer.call(DesktopIntegrationServer.IPsecManager, :get_status, 5000) do
        {:ok, status} -> %{status: "active", details: status}
        {:error, reason} -> %{status: "error", reason: inspect(reason)}
      end
    catch
      :exit, {:timeout, _} -> %{status: "timeout", reason: "IPsec manager not responding"}
      :exit, {:noproc, _} -> %{status: "not_running", reason: "IPsec manager process not found"}
      kind, reason -> %{status: "error", reason: "#{kind}: #{inspect(reason)}"}
    end
  end

  defp check_sftp_connectivity() do
    try do
      # Quick connectivity test using the FileStorage adapter
      case DesktopIntegrationServer.FileStorage.list_files(".", []) do
        {:ok, _files} -> %{status: "connected", message: "SFTP server reachable"}
        {:error, :econnrefused} -> %{status: "connection_refused", message: "SFTP server not reachable"}
        {:error, reason} -> %{status: "error", message: "SFTP error: #{inspect(reason)}"}
      end
    catch
      kind, reason -> %{status: "error", message: "#{kind}: #{inspect(reason)}"}
    end
  end

  defp get_supervisor_status() do
    try do
      children = Supervisor.which_children(DesktopIntegrationServer.Supervisor)
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

defmodule DesktopIntegrationServer.WebSocketHandler do
  @behaviour :cowboy_websocket
  require Logger

  def init(req, opts_from_router) do
    # Add process name for easier tracking
    Process.put(:websocket_handler_stage, :init_started)

    try do
      pid = inspect(self())
      Logger.info("[WSHandler][#{pid}] HTTP init/2 called")
      Logger.debug("[WSHandler][#{pid}] Opts from router: #{inspect(opts_from_router)}")
      Logger.debug("[WSHandler][#{pid}] Request details - peer: #{inspect(req.peer)}, path: #{inspect(req.path)}, method: #{inspect(req.method)}")

      client_id = :erlang.unique_integer([:positive])
      state = %{
        client_id: client_id,
        initialized_at: DateTime.utc_now(),
        pid_at_init: pid,
        init_successful: true,
        process_start_time: System.monotonic_time()
      }

      Logger.debug("[WSHandler][#{pid}] HTTP init completed with client_id: #{client_id}")

      Process.put(:websocket_handler_stage, :init_complete)
      Process.put(:websocket_handler_state, state)

      result = {:cowboy_websocket, req, state}
      Logger.debug("[WSHandler][#{pid}] Upgrading to WebSocket")
      result
    rescue
      error ->
        pid = inspect(self())
        Logger.error("[WSHandler][#{pid}] Error in HTTP init/2: #{inspect(error)}")
        Logger.error("[WSHandler][#{pid}] Stacktrace: #{inspect(__STACKTRACE__)}")

        Process.put(:websocket_handler_stage, :init_error)

        # Return a basic state to prevent nil state issues
        emergency_state = %{client_id: 0, emergency_init: true, error: inspect(error), pid_at_init: pid}
        Process.put(:websocket_handler_state, emergency_state)

        {:cowboy_websocket, req, emergency_state}
    catch
      kind, reason ->
        pid = inspect(self())
        Logger.error("[WSHandler][#{pid}] Catch in HTTP init/2 - Kind: #{inspect(kind)}, Reason: #{inspect(reason)}")
        Logger.error("[WSHandler][#{pid}] Stacktrace: #{inspect(__STACKTRACE__)}")

        Process.put(:websocket_handler_stage, :init_catch)

        emergency_state = %{client_id: 0, emergency_init: true, catch_error: {kind, reason}, pid_at_init: pid}
        Process.put(:websocket_handler_state, emergency_state)

        {:cowboy_websocket, req, emergency_state}
    end
  end

    def websocket_init(state) do
    # This runs in the WebSocket process after the upgrade
    pid = inspect(self())
    Logger.info("[WSHandler][#{pid}] WebSocket process initialized")
    Logger.debug("[WSHandler][#{pid}] Initial state from HTTP process: #{inspect(state)}")

    # Create the proper WebSocket state (init/2 state might be nil or incomplete)
    client_id = :erlang.unique_integer([:positive])
    websocket_state = %{
      client_id: client_id,
      initialized_at: DateTime.utc_now(),
      pid_at_init: pid,
      websocket_init_successful: true,
      process_start_time: System.monotonic_time()
    }

    Process.put(:websocket_handler_stage, :websocket_init_complete)
    Process.put(:websocket_handler_state, websocket_state)

    Logger.info("[WSHandler][#{pid}] WebSocket ready with client_id: #{client_id}")

    {:ok, websocket_state}
  end

  def websocket_handle(frame, state) do
    pid = inspect(self())

    # Handle case where state is nil or invalid - try to recover or fail gracefully
    if is_map(state) and Map.has_key?(state, :client_id) do
      client_id_for_log = Map.get(state, :client_id)
      pid_at_init = Map.get(state, :pid_at_init, "PID_NOT_IN_STATE")
      log_prefix = "[WSHandler][PID:#{pid}][CID:#{client_id_for_log}][InitPID:#{pid_at_init}]"

      case frame do
        {:text, msg} ->
          Logger.info("#{log_prefix} Received TEXT: #{msg}")
          decoded_result = Jason.decode(msg)
          Logger.debug("#{log_prefix} Decoded JSON attempt: #{inspect(decoded_result)}")

          case decoded_result do
            {:ok, %{"action" => "list_files", "path" => requested_path}} ->
              Logger.info("#{log_prefix} Matched ACTION: list_files. Path: '#{requested_path}'.")
              path_to_list = if is_nil(requested_path) or requested_path == "", do: ".", else: requested_path
              Logger.info("#{log_prefix} Calling FileStorage.list_files for path: '#{path_to_list}'")
              file_list_result = DesktopIntegrationServer.FileStorage.list_files(path_to_list, [])
              Logger.debug("#{log_prefix} FileStorage.list_files result: #{inspect(file_list_result)}")

              response_payload_map =
                case file_list_result do
                  {:ok, files} ->
                    %{type: "file_list_response", path: path_to_list, files: files}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error listing files for path '#{path_to_list}': #{inspect(reason)}")
                    %{type: "file_list_error", path: path_to_list, error: "Failed to list files: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending file list response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, decoded_msg} ->
              Logger.info("#{log_prefix} Matched GENERIC JSON. Full Decoded: #{inspect(decoded_msg)}. Sending echo_response.")
              response_payload = Jason.encode!(%{type: "echo_response", payload: decoded_msg, server_note: "Elixir says hello to your JSON!"})
              Logger.info("#{log_prefix} Sending generic echo_response to client: #{response_payload}")
              {:reply, {:text, response_payload}, state}

            {:error, jason_error} ->
              Logger.warning("#{log_prefix} JSON Decode ERROR: #{inspect(jason_error)}. Original message: #{msg}. Sending echo_response for non-JSON.")
              response_payload = Jason.encode!(%{type: "echo_response", payload: msg, server_note: "Elixir received non-JSON text: #{msg}"})
              Logger.info("#{log_prefix} Sending non-JSON echo_response to client: #{response_payload}")
              {:reply, {:text, response_payload}, state}
          end

        {:binary, _msg_binary} ->
          Logger.info("#{log_prefix} Received BINARY data.")
          response_payload = Jason.encode!(%{type: "binary_ack", server_note: "Elixir received binary data."})
          Logger.info("#{log_prefix} Sending binary_ack to client: #{response_payload}")
          {:reply, {:text, response_payload}, state}

        other_frame ->
          Logger.debug("#{log_prefix} Received OTHER frame: #{inspect(other_frame)}")
          {:ok, state}
      end
    else
      # State is nil or invalid - this indicates init/2 may not have been called properly
      Logger.error("[WSHandler][#{pid}] Invalid or missing state in websocket_handle")
      Logger.error("[WSHandler][#{pid}] State: #{inspect(state)}, Frame: #{inspect(frame)}")

      # Check process dictionary for debugging
      process_stage = Process.get(:websocket_handler_stage, :unknown)
      process_state = Process.get(:websocket_handler_state, :not_found)

      Logger.error("[WSHandler][#{pid}] Process stage: #{inspect(process_stage)}")
      Logger.error("[WSHandler][#{pid}] Process state: #{inspect(process_state)}")

      # Try to recover by creating a new state
      recovered_state = %{
        client_id: :erlang.unique_integer([:positive]),
        initialized_at: DateTime.utc_now(),
        pid_at_init: pid,
        recovered: true
      }
      Logger.warning("[WSHandler][#{pid}] Attempting state recovery: #{inspect(recovered_state)}")

      # Handle the frame with recovered state
      case frame do
        {:text, msg} ->
          Logger.info("[WSHandler][#{pid}] Handling message with recovered state: #{msg}")
          response_payload = Jason.encode!(%{type: "error_recovery", message: "Connection state was recovered", original_message: msg})
          {:reply, {:text, response_payload}, recovered_state}

        _ ->
          Logger.info("[WSHandler][#{pid}] Handling non-text frame with recovered state: #{inspect(frame)}")
          {:ok, recovered_state}
      end
    end
  end

  def websocket_info(info, state) do
    client_id_for_log = if is_map(state) and Map.has_key?(state, :client_id), do: Map.get(state, :client_id), else: "unknown_init_state"
    log_prefix = "[WSHandler][PID:#{inspect(self())}][CID:#{client_id_for_log}]"
    Logger.debug("#{log_prefix} Received INFO: #{inspect(info)}")
    {:ok, state}
  end

  def terminate(reason, state) do
    client_id_for_log = if is_map(state) and Map.has_key?(state, :client_id), do: Map.get(state, :client_id), else: "unknown_init_state"
    log_prefix = "[WSHandler][PID:#{inspect(self())}][CID:#{client_id_for_log}]"
    Logger.info("#{log_prefix} TERMINATING. Reason: #{inspect(reason)}")
    :ok
  end
end
