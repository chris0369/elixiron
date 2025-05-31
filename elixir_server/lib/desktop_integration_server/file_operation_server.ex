defmodule DesktopIntegrationServer.FileOperationServer do
  @moduledoc """
  GenServer that handles all file operations in a separate, isolated process.

  This server ensures that file operations never crash WebSocket processes,
  and provides a clean async interface for file operations.
  """

  use GenServer
  require Logger
  alias DesktopIntegrationServer.FileManager
  alias DesktopIntegrationServer.PathUtils

  @type operation_request :: {
    operation :: atom(),
    params :: map(),
    reply_to :: pid(),
    request_id :: String.t()
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes a file operation asynchronously and sends the result back to the caller.
  """
  @spec execute_async(atom(), map(), String.t()) :: :ok
  def execute_async(operation, params, request_id) do
    GenServer.cast(__MODULE__, {:execute_operation, operation, params, self(), request_id})
  end

  @doc """
  Executes a file operation synchronously with a timeout.
  """
  @spec execute_sync(atom(), map(), timeout()) :: {:ok, any()} | {:error, any()}
  def execute_sync(operation, params, timeout \\ 30_000) do
    try do
      GenServer.call(__MODULE__, {:execute_operation_sync, operation, params}, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :operation_timeout}
      :exit, {:noproc, _} -> {:error, :server_not_available}
      kind, reason -> {:error, {:unexpected_error, kind, reason}}
    end
  end

  # GenServer Callbacks

    @impl true
  def init(_opts) do
    Logger.info("[FileOperationServer] Starting file operation server")

    state = %{
      operations_count: 0,
      start_time: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute_operation_sync, operation, params}, _from, state) do
    result = execute_file_operation(operation, params)
    new_state = %{state | operations_count: state.operations_count + 1}
    {:reply, result, new_state}
  end

  @impl true
  def handle_cast({:execute_operation, operation, params, reply_to, request_id}, state) do
    # Execute operation in a separate task to avoid blocking the GenServer
    Task.start(fn ->
      result = execute_file_operation(operation, params)
      send(reply_to, {:file_operation_result, request_id, operation, result})
    end)

    new_state = %{state | operations_count: state.operations_count + 1}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[FileOperationServer] Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  # Helper to execute a FileManager operation with path validation
  defp call_file_manager(params, path_keys, file_manager_fun, build_opts_fun) do
    path_values_result =
      Enum.map(path_keys, fn key ->
        case Map.fetch(params, key) do
          {:ok, path_val} -> {:ok, path_val}
          :error -> {:error, {:missing_param, key}}
        end
      end)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, val}, {:ok, acc} -> {:cont, {:ok, [val | acc]}}
        {{:error, _} = err, _}, _ -> {:halt, err}
      end)

    with {:ok, path_values_reversed} <- path_values_result,
         validated_paths_result <- Enum.map(Enum.reverse(path_values_reversed), &PathUtils.validate_path/1)
                                    |> Enum.reduce_while({:ok, []}, fn
                                      {:ok, path}, {:ok, acc} -> {:cont, {:ok, [path | acc]}}
                                      {{:error, reason}, _}, _ -> {:halt, {:error, {:path_validation_failed, reason}}}
                                    end) do
      {:ok, validated_paths_reversed} = validated_paths_result
      args = Enum.reverse(validated_paths_reversed)
      opts = if build_opts_fun, do: build_opts_fun.(params), else: []
      apply(FileManager, file_manager_fun, args ++ [opts])
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_file_manager_resolve_path(params, name_key, file_manager_fun, build_opts_fun) do
    with {:ok, path} <- PathUtils.resolve_path_from_params(params, name_key),
         {:ok, validated_path} <- PathUtils.validate_path(path) do
      opts = if build_opts_fun, do: build_opts_fun.(params), else: []
      apply(FileManager, file_manager_fun, [validated_path, opts])
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_file_operation(operation, params) do
    Logger.debug("[FileOperationServer] Executing operation: #{operation} with params: #{inspect(params)}")

    try do
      case operation do
        :list_files ->
          requested_path = Map.get(params, "path", PathUtils.get_base_remote_path())
          opts = build_list_opts(params)
          case PathUtils.validate_path(requested_path) do
            {:ok, validated_path} ->
              case FileManager.list_files(validated_path, opts) do
                {:ok, files} -> {:ok, %{path: validated_path, files: files}}
                err -> err
              end
            err -> err
          end

        :get_directory_tree ->
          requested_path = Map.get(params, "path", PathUtils.get_base_remote_path())
          max_depth = Map.get(params, "max_depth", 3)
          case PathUtils.validate_path(requested_path) do
            {:ok, validated_path} -> FileManager.get_directory_tree(validated_path, max_depth)
            err -> err
          end

        :create_file ->
          # create_file expects path, content, opts as separate arguments
          content = Map.get(params, "content", "")
          with {:ok, path} <- PathUtils.resolve_path_from_params(params, "file_name"),
               {:ok, validated_path} <- PathUtils.validate_path(path) do
            opts = build_file_opts(params)
            FileManager.create_file(validated_path, content, opts)
          end

        :read_file ->
          call_file_manager(params, ["path"], :read_file, &build_file_opts/1)

        :update_file ->
          # update_file expects path, content, opts as separate arguments
          content = Map.fetch!(params, "content")
          with {:ok, path} <- Map.fetch(params, "path"),
               {:ok, validated_path} <- PathUtils.validate_path(path) do
            opts = build_file_opts(params)
            FileManager.update_file(validated_path, content, opts)
          end

        :delete_file ->
          call_file_manager(params, ["path"], :delete_file, &build_file_opts/1)

        :move_file ->
          call_file_manager(params, ["source", "destination"], :move_file, &build_file_opts/1)

        :copy_file ->
          call_file_manager(params, ["source", "destination"], :copy_file, &build_file_opts/1)

        :create_directory ->
          call_file_manager_resolve_path(params, "directory_name", :create_directory, &build_directory_opts/1)

        :delete_directory ->
          call_file_manager(params, ["path"], :delete_directory, fn p -> [recursive: Map.get(p, "recursive", false)] end)

        :get_file_info ->
          call_file_manager(params, ["path"], :get_file_info, fn _ -> [] end) # No opts for get_file_info in FileManager

        :batch_operations ->
          operations = Map.fetch!(params, "operations")
          case validate_and_execute_batch(operations) do
            {:ok, validated_ops} -> FileManager.batch_operations(validated_ops)
            err -> err
          end

        :exists ->
          call_file_manager(params, ["path"], :exists?, fn _ -> [] end) # No opts for exists?

        :echo_json ->
          payload = Map.get(params, "payload", %{})
          Logger.info("[FileOperationServer] Echo operation with payload: #{inspect(payload)}")
          {:ok, %{echo_response: true, original_payload: payload, server_time: DateTime.utc_now() |> DateTime.to_iso8601(), message: "Echo from FileOperationServer"}}

        unknown_operation ->
          Logger.error("[FileOperationServer] Unknown operation: #{inspect(unknown_operation)}")
          {:error, {:unknown_operation, unknown_operation}}
      end
    rescue
      error ->
        Logger.error("[FileOperationServer] Error executing #{operation}: #{inspect(error)}")
        Logger.error("[FileOperationServer] Stacktrace: #{inspect(__STACKTRACE__)}")
        {:error, {:execution_error, inspect(error)}}
    catch
      kind, reason ->
        Logger.error("[FileOperationServer] Catch in #{operation}: #{inspect({kind, reason})}")
        Logger.error("[FileOperationServer] Stacktrace: #{inspect(__STACKTRACE__)}")
        {:error, {:execution_catch, kind, reason}}
    end
  end

  defp build_list_opts(params) do
    [
      detailed: Map.get(params, "detailed", false),
      recursive: Map.get(params, "recursive", false)
    ]
  end

  defp build_file_opts(params) do
    opts = []

    opts = if Map.has_key?(params, "overwrite") do
      Keyword.put(opts, :overwrite, params["overwrite"])
    else
      opts
    end

    opts = if Map.has_key?(params, "backup") do
      Keyword.put(opts, :backup, params["backup"])
    else
      opts
    end

    opts = if Map.has_key?(params, "create_dirs") do
      Keyword.put(opts, :create_dirs, params["create_dirs"])
    else
      opts
    end

    opts
  end

  defp build_directory_opts(params) do
    [
      recursive: Map.get(params, "recursive", true)
    ]
  end

  defp validate_and_execute_batch(operations) when is_list(operations) do
    try do
      validated_ops = Enum.map(operations, fn op ->
        case op do
          %{"type" => "create_file", "path" => path, "content" => content} ->
            case PathUtils.validate_path(path) do
              {:ok, validated_path} -> {:create_file, validated_path, content, []}
              {:error, reason} -> throw({:path_validation_failed, path, reason})
            end

          %{"type" => "update_file", "path" => path, "content" => content} ->
            case PathUtils.validate_path(path) do
              {:ok, validated_path} -> {:update_file, validated_path, content, []}
              {:error, reason} -> throw({:path_validation_failed, path, reason})
            end

          %{"type" => "delete_file", "path" => path} ->
            case PathUtils.validate_path(path) do
              {:ok, validated_path} -> {:delete_file, validated_path, []}
              {:error, reason} -> throw({:path_validation_failed, path, reason})
            end

          %{"type" => "move_file", "source" => source, "destination" => dest} ->
            with {:ok, validated_source} <- PathUtils.validate_path(source),
                 {:ok, validated_dest} <- PathUtils.validate_path(dest) do
              {:move_file, validated_source, validated_dest, []}
            else
              {:error, reason} -> throw({:path_validation_failed, {source, dest}, reason})
            end

          %{"type" => "copy_file", "source" => source, "destination" => dest} ->
            with {:ok, validated_source} <- PathUtils.validate_path(source),
                 {:ok, validated_dest} <- PathUtils.validate_path(dest) do
              {:copy_file, validated_source, validated_dest, []}
            else
              {:error, reason} -> throw({:path_validation_failed, {source, dest}, reason})
            end

          unknown_op ->
            throw({:unknown_batch_operation, unknown_op})
        end
      end)

      {:ok, validated_ops}
    catch
      {:path_validation_failed, path, reason} ->
        {:error, {:batch_path_validation_failed, path, reason}}
      {:unknown_batch_operation, op} ->
        {:error, {:unknown_batch_operation, op}}
    end
  end

  defp validate_and_execute_batch(_) do
    {:error, :invalid_operations_format}
  end


end
