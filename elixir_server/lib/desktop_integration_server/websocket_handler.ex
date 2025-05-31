defmodule DesktopIntegrationServer.WebSocketHandler do
  @moduledoc """
  Simplified WebSocket handler that only handles WebSocket protocol concerns.

  All file operations are delegated to the FileOperationServer via message passing,
  ensuring complete process isolation.
  """

  @behaviour :cowboy_websocket
  require Logger
  alias DesktopIntegrationServer.FileOperationServer

  # WebSocket handler callbacks

  def init(req, opts_from_router) do
    pid = inspect(self())
    Logger.info("[WSHandler][#{pid}] HTTP init/2 called")
    Logger.debug("[WSHandler][#{pid}] Opts from router: #{inspect(opts_from_router)}")

    client_id = :erlang.unique_integer([:positive])
    state = %{
      client_id: client_id,
      initialized_at: DateTime.utc_now(),
      pid_at_init: pid,
      pending_requests: %{}
    }

    Logger.debug("[WSHandler][#{pid}] HTTP init completed with client_id: #{client_id}")
    {:cowboy_websocket, req, state}
  end

    def websocket_init(initial_state) do
    pid = inspect(self())
    Logger.info("[WSHandler][#{pid}] WebSocket process initialized")
    Logger.debug("[WSHandler][#{pid}] Initial state: #{inspect(initial_state)}")

    # Create fresh state for WebSocket process (state from init/2 may be nil or incomplete)
    client_id = :erlang.unique_integer([:positive])
    websocket_state = %{
      client_id: client_id,
      initialized_at: DateTime.utc_now(),
      pid_at_init: pid,
      pending_requests: %{}
    }

    Logger.info("[WSHandler][#{pid}] WebSocket ready with client_id: #{client_id}")

    # Send a welcome message to the client
    welcome_msg = %{
      type: "connection_established",
      client_id: client_id,
      server_time: DateTime.utc_now() |> DateTime.to_iso8601(),
      message: "WebSocket connection established successfully"
    }

    {:reply, {:text, Jason.encode!(welcome_msg)}, websocket_state}
  end

  def websocket_handle({:text, msg}, state) do
    client_id = state.client_id
    pid = inspect(self())
    log_prefix = "[WSHandler][PID:#{pid}][CID:#{client_id}]"

    Logger.info("#{log_prefix} Received TEXT: #{msg}")

    case Jason.decode(msg) do
      {:ok, %{"action" => action} = decoded_msg} ->
        handle_action(action, decoded_msg, state, log_prefix)

      {:ok, decoded_msg} ->
        # Handle non-action JSON messages
        Logger.info("#{log_prefix} Received non-action JSON: #{inspect(decoded_msg)}")
        response = %{
          type: "echo_response",
          payload: decoded_msg,
          server_note: "Elixir received JSON message without action"
        }
        {:reply, {:text, Jason.encode!(response)}, state}

      {:error, jason_error} ->
        # Handle invalid JSON
        Logger.warning("#{log_prefix} JSON decode error: #{inspect(jason_error)}")
        response = %{
          type: "error_response",
          error: "invalid_json",
          message: "Failed to parse JSON message",
          original_message: msg
        }
        {:reply, {:text, Jason.encode!(response)}, state}
    end
  end

  def websocket_handle({:binary, _binary_data}, state) do
    client_id = state.client_id
    pid = inspect(self())

    Logger.info("[WSHandler][PID:#{pid}][CID:#{client_id}] Received BINARY data")

    response = %{
      type: "binary_ack",
      message: "Binary data received but not supported for file operations"
    }

    {:reply, {:text, Jason.encode!(response)}, state}
  end

  def websocket_handle(frame, state) do
    client_id = state.client_id
    pid = inspect(self())

    Logger.debug("[WSHandler][PID:#{pid}][CID:#{client_id}] Received other frame: #{inspect(frame)}")
    {:ok, state}
  end

  def websocket_info({:file_operation_result, request_id, operation, result}, state) do
    client_id = state.client_id
    pid = inspect(self())
    log_prefix = "[WSHandler][PID:#{pid}][CID:#{client_id}]"

    Logger.debug("#{log_prefix} Received file operation result for #{request_id}: #{inspect(result)}")

    case Map.pop(state.pending_requests, request_id) do
      {nil, _} ->
        Logger.warning("#{log_prefix} Received result for unknown request_id: #{request_id}")
        {:ok, state}

      {original_action, updated_pending} ->
        response = build_response(operation, original_action, result)
        response_json = Jason.encode!(response)

        Logger.info("#{log_prefix} Sending file operation response for operation #{operation}: #{response_json}")

        new_state = %{state | pending_requests: updated_pending}
        {:reply, {:text, response_json}, new_state}
    end
  end

  def websocket_info(info, state) do
    client_id = state.client_id
    pid = inspect(self())

    Logger.debug("[WSHandler][PID:#{pid}][CID:#{client_id}] Received unexpected info: #{inspect(info)}")
    {:ok, state}
  end

  def terminate(reason, state) do
    client_id = state.client_id
    pid = inspect(self())

    Logger.info("[WSHandler][PID:#{pid}][CID:#{client_id}] Terminating. Reason: #{inspect(reason)}")
    :ok
  end

  # Private helper functions

  defp handle_action(action, params, state, log_prefix) do
    request_id = generate_request_id()

    Logger.info("#{log_prefix} Handling action: #{action} with request_id: #{request_id}")

    # Map WebSocket actions to FileOperationServer operations
    operation = case action do
      "list_files" -> :list_files
      "get_directory_tree" -> :get_directory_tree
      "create_file" -> :create_file
      "read_file" -> :read_file
      "update_file" -> :update_file
      "delete_file" -> :delete_file
      "move_file" -> :move_file
      "copy_file" -> :copy_file
      "create_directory" -> :create_directory
      "delete_directory" -> :delete_directory
      "get_file_info" -> :get_file_info
      "batch_operations" -> :batch_operations
      "exists" -> :exists
      "echo_json" -> :echo_json  # Add echo support for testing
      _ -> :unknown_action
    end

    case operation do
      :unknown_action ->
        Logger.warning("#{log_prefix} Unknown action: #{action}")
        response = %{
          type: "error_response",
          error: "unknown_action",
          message: "Unknown action: #{action}",
          supported_actions: [
            "list_files", "get_directory_tree", "create_file", "read_file", "update_file", "delete_file",
            "move_file", "copy_file", "create_directory", "delete_directory",
            "get_file_info", "batch_operations", "exists"
          ]
        }
        {:reply, {:text, Jason.encode!(response)}, state}

      _ ->
        # Store the request to match it with the response later
        updated_pending = Map.put(state.pending_requests, request_id, action)
        new_state = %{state | pending_requests: updated_pending}

        # Send the operation to FileOperationServer asynchronously
        FileOperationServer.execute_async(operation, params, request_id)

        # Return the state without sending a response (response will come via websocket_info)
        {:ok, new_state}
    end
  end

  defp generate_request_id do
    "req_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp build_success_response(type, action, data) do
    %{type: type, action: action, success: true} |> Map.merge(data)
  end

  defp build_error_response(action, reason) do
    %{
      type: "error_response",
      action: action,
      error: inspect(reason),
      message: "File operation failed: #{inspect(reason)}",
      success: false
    }
  end

  defp build_response(operation, original_action, result) do
    case {operation, result} do
      {:list_files, {:ok, %{path: path, files: files}}} ->
        build_success_response("file_list_response", original_action, %{path: path, files: files})

      {:get_directory_tree, {:ok, tree}} ->
        build_success_response("directory_tree_response", original_action, %{tree: tree})

      {:create_file, {:ok, created_path}} ->
        build_success_response("file_create_response", original_action, %{path: created_path})

      {:read_file, {:ok, %{path: path, content: content}}} ->
        build_success_response("file_read_response", original_action, %{path: path, content: content})

      # This case might be redundant if read_file always returns the map structure.
      # Kept for safety if FileManager.read_file can return just content.
      {:read_file, {:ok, content}} when not is_map(content) ->
        build_success_response("file_read_response", original_action, %{content: content})

      {:update_file, {:ok, updated_path}} ->
        build_success_response("file_update_response", original_action, %{path: updated_path})

      {:delete_file, {:ok, deleted_path}} ->
        build_success_response("file_delete_response", original_action, %{path: deleted_path})

      {:move_file, {:ok, moved_path}} ->
        build_success_response("file_move_response", original_action, %{destination: moved_path})

      {:copy_file, {:ok, copied_path}} ->
        build_success_response("file_copy_response", original_action, %{destination: copied_path})

      {:create_directory, {:ok, created_path}} ->
        build_success_response("directory_create_response", original_action, %{path: created_path})

      {:delete_directory, {:ok, deleted_path}} ->
        build_success_response("directory_delete_response", original_action, %{path: deleted_path})

      {:get_file_info, {:ok, file_info}} ->
        build_success_response("file_info_response", original_action, %{file_info: file_info})

      {:batch_operations, {:ok, results}} ->
        build_success_response("batch_operations_response", original_action, %{results: results})

      {:exists, {:ok, exists_bool}} -> # Renamed `exists` to `exists_bool` to avoid clash
        build_success_response("exists_response", original_action, %{exists: exists_bool})

      {:echo_json, {:ok, echo_data}} ->
        build_success_response("echo_response", original_action, %{payload: echo_data})

      {_op, {:error, reason}} -> # Catch-all for errors from any operation
        build_error_response(original_action, reason)

      # Fallback for unexpected result structures (should ideally not be hit)
      {op, unexpected_result} ->
        Logger.warning("[WSHandler] Unexpected result structure for operation #{op}: #{inspect(unexpected_result)}")
        build_error_response(original_action, {:unexpected_result_structure, op, unexpected_result})
    end
  end
end
