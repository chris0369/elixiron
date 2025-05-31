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
        memory_usage: :erlang.memory() |> Enum.into(%{}),
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
      # Quick connectivity test using the FileManager
      case DesktopIntegrationServer.FileManager.list_files(".", detailed: false) do
        {:ok, _files} -> %{status: "connected", message: "SFTP server reachable via FileManager"}
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
              Logger.info("#{log_prefix} Calling FileManager.list_files for path: '#{path_to_list}'")
              file_list_result = DesktopIntegrationServer.FileManager.list_files(path_to_list, detailed: false)
              Logger.debug("#{log_prefix} FileManager.list_files result: #{inspect(file_list_result)}")

              response_payload_map =
                case file_list_result do
                  {:ok, files} ->
                    %{type: "file_list_response", path: path_to_list, files: files, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error listing files for path '#{path_to_list}': #{inspect(reason)}")
                    %{type: "file_list_response", path: path_to_list, files: [], success: false, error: "Failed to list files: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending file list response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "create_file", "path" => file_path, "content" => content}} ->
              Logger.info("#{log_prefix} Matched ACTION: create_file. Path: '#{file_path}'.")
              create_result = DesktopIntegrationServer.FileManager.create_file(file_path, content)
              Logger.debug("#{log_prefix} FileManager.create_file result: #{inspect(create_result)}")

              response_payload_map =
                case create_result do
                  {:ok, created_path} ->
                    %{type: "file_create_response", path: created_path, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error creating file '#{file_path}': #{inspect(reason)}")
                    %{type: "file_create_error", path: file_path, error: "Failed to create file: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending file create response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "read_file", "path" => file_path}} ->
              Logger.info("#{log_prefix} Matched ACTION: read_file. Path: '#{file_path}'.")
              read_result = DesktopIntegrationServer.FileManager.read_file(file_path)
              Logger.debug("#{log_prefix} FileManager.read_file result: #{inspect(read_result)}")

              response_payload_map =
                case read_result do
                  {:ok, content} ->
                    %{type: "file_read_response", path: file_path, content: content, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error reading file '#{file_path}': #{inspect(reason)}")
                    %{type: "file_read_error", path: file_path, error: "Failed to read file: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending file read response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "update_file", "path" => file_path, "content" => content}} ->
              Logger.info("#{log_prefix} Matched ACTION: update_file. Path: '#{file_path}'.")
              update_result = DesktopIntegrationServer.FileManager.update_file(file_path, content)
              Logger.debug("#{log_prefix} FileManager.update_file result: #{inspect(update_result)}")

              response_payload_map =
                case update_result do
                  {:ok, updated_path} ->
                    %{type: "file_update_response", path: updated_path, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error updating file '#{file_path}': #{inspect(reason)}")
                    %{type: "file_update_error", path: file_path, error: "Failed to update file: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending file update response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "delete_file", "path" => file_path}} ->
              Logger.info("#{log_prefix} Matched ACTION: delete_file. Path: '#{file_path}'.")
              delete_result = DesktopIntegrationServer.FileManager.delete_file(file_path)
              Logger.debug("#{log_prefix} FileManager.delete_file result: #{inspect(delete_result)}")

              response_payload_map =
                case delete_result do
                  {:ok, deleted_path} ->
                    %{type: "file_delete_response", path: deleted_path, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error deleting file '#{file_path}': #{inspect(reason)}")
                    %{type: "file_delete_error", path: file_path, error: "Failed to delete file: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending file delete response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "move_file", "source" => source_path, "destination" => dest_path}} ->
              Logger.info("#{log_prefix} Matched ACTION: move_file. Source: '#{source_path}' -> Destination: '#{dest_path}'.")
              move_result = DesktopIntegrationServer.FileManager.move_file(source_path, dest_path)
              Logger.debug("#{log_prefix} FileManager.move_file result: #{inspect(move_result)}")

              response_payload_map =
                case move_result do
                  {:ok, moved_path} ->
                    %{type: "file_move_response", source: source_path, destination: moved_path, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error moving file '#{source_path}' -> '#{dest_path}': #{inspect(reason)}")
                    %{type: "file_move_error", source: source_path, destination: dest_path, error: "Failed to move file: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending file move response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "copy_file", "source" => source_path, "destination" => dest_path}} ->
              Logger.info("#{log_prefix} Matched ACTION: copy_file. Source: '#{source_path}' -> Destination: '#{dest_path}'.")
              copy_result = DesktopIntegrationServer.FileManager.copy_file(source_path, dest_path)
              Logger.debug("#{log_prefix} FileManager.copy_file result: #{inspect(copy_result)}")

              response_payload_map =
                case copy_result do
                  {:ok, copied_path} ->
                    %{type: "file_copy_response", source: source_path, destination: copied_path, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error copying file '#{source_path}' -> '#{dest_path}': #{inspect(reason)}")
                    %{type: "file_copy_error", source: source_path, destination: dest_path, error: "Failed to copy file: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending file copy response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "create_directory", "path" => dir_path}} ->
              Logger.info("#{log_prefix} Matched ACTION: create_directory. Path: '#{dir_path}'.")
              create_dir_result = DesktopIntegrationServer.FileManager.create_directory(dir_path)
              Logger.debug("#{log_prefix} FileManager.create_directory result: #{inspect(create_dir_result)}")

              response_payload_map =
                case create_dir_result do
                  {:ok, created_path} ->
                    %{type: "directory_create_response", path: created_path, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error creating directory '#{dir_path}': #{inspect(reason)}")
                    %{type: "directory_create_error", path: dir_path, error: "Failed to create directory: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending directory create response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "delete_directory", "path" => dir_path, "recursive" => recursive}} ->
              Logger.info("#{log_prefix} Matched ACTION: delete_directory. Path: '#{dir_path}', Recursive: #{recursive}.")
              delete_dir_result = DesktopIntegrationServer.FileManager.delete_directory(dir_path, recursive: recursive)
              Logger.debug("#{log_prefix} FileManager.delete_directory result: #{inspect(delete_dir_result)}")

              response_payload_map =
                case delete_dir_result do
                  {:ok, deleted_path} ->
                    %{type: "directory_delete_response", path: deleted_path, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error deleting directory '#{dir_path}': #{inspect(reason)}")
                    %{type: "directory_delete_error", path: dir_path, error: "Failed to delete directory: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending directory delete response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "get_file_info", "path" => file_path}} ->
              Logger.info("#{log_prefix} Matched ACTION: get_file_info. Path: '#{file_path}'.")
              file_info_result = DesktopIntegrationServer.FileManager.get_file_info(file_path)
              Logger.debug("#{log_prefix} FileManager.get_file_info result: #{inspect(file_info_result)}")

              response_payload_map =
                case file_info_result do
                  {:ok, file_info} ->
                    %{type: "file_info_response", path: file_path, file_info: file_info, success: true}
                  {:error, reason} ->
                    Logger.error("#{log_prefix} Error getting file info for '#{file_path}': #{inspect(reason)}")
                    %{type: "file_info_error", path: file_path, error: "Failed to get file info: #{inspect(reason)}"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending file info response/error to client: #{response_payload_json}")
              {:reply, {:text, response_payload_json}, state}

            {:ok, %{"action" => "batch_operations", "operations" => operations}} ->
              Logger.info("#{log_prefix} Matched ACTION: batch_operations. Operations count: #{length(operations)}.")

              # Convert JSON operations to tuples
              parsed_operations = Enum.map(operations, fn op ->
                case op do
                  %{"type" => "create_file", "path" => path, "content" => content} ->
                    {:create_file, path, content, []}
                  %{"type" => "update_file", "path" => path, "content" => content} ->
                    {:update_file, path, content, []}
                  %{"type" => "delete_file", "path" => path} ->
                    {:delete_file, path, []}
                  %{"type" => "move_file", "source" => source, "destination" => dest} ->
                    {:move_file, source, dest, []}
                  %{"type" => "copy_file", "source" => source, "destination" => dest} ->
                    {:copy_file, source, dest, []}
                  _ ->
                    {:unknown_operation, op}
                end
              end)

              batch_result = DesktopIntegrationServer.FileManager.batch_operations(parsed_operations)
              Logger.debug("#{log_prefix} FileManager.batch_operations result: #{inspect(batch_result)}")

              response_payload_map =
                case batch_result do
                  {:ok, results} ->
                    %{type: "batch_operations_response", results: results, success: true}
                  {:error, {failed_op, partial_results}} ->
                    Logger.error("#{log_prefix} Error in batch operations at: #{inspect(failed_op)}")
                    %{type: "batch_operations_error", failed_operation: failed_op, partial_results: partial_results, error: "Batch operation failed"}
                end
              response_payload_json = Jason.encode!(response_payload_map)
              Logger.info("#{log_prefix} Sending batch operations response/error to client: #{response_payload_json}")
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
