defmodule DesktopIntegrationServer.FileStorage do
  @moduledoc """
  Main module for file storage operations. Delegates to a configured adapter.
  """
  require Logger

  # Public API functions
  def upload_file(local_path, remote_name, opts \\ []) do
    call_adapter_func(configured_adapter_module(), :upload_file, [local_path, remote_name, opts])
  end

  def download_file(remote_name, local_path, opts \\ []) do
    call_adapter_func(configured_adapter_module(), :download_file, [remote_name, local_path, opts])
  end

  def list_files(remote_path, opts \\ []) do
    call_adapter_func(configured_adapter_module(), :list_files, [remote_path, opts])
  end

  # Private helper to get the configured adapter module
  defp configured_adapter_module do
    Application.get_env(:desktop_integration_server, __MODULE__, [])
    |> Keyword.fetch!(:adapter)
  end

  # Private helper to initialize and call the adapter function
  defp call_adapter_func(adapter_module, func_name, args) do
    full_config = Application.get_env(:desktop_integration_server, __MODULE__, [])

    adapter_specific_config_key =
      case adapter_module do
        DesktopIntegrationServer.FileStorage.SFTPAdapter -> :sftp_config
        # Example for a future LocalAdapter if you add one:
        # DesktopIntegrationServer.FileStorage.LocalAdapter -> :local_config
        _ ->
          Logger.error("Unknown FileStorage adapter configured: #{inspect(adapter_module)}. Check :adapter and :<adapter_name>_config in your config files.")
          raise "Unknown FileStorage adapter: #{inspect(adapter_module)}"
      end

    adapter_config = Keyword.get(full_config, adapter_specific_config_key, [])

    case adapter_module.init(adapter_config) do
      {:ok, initialized_adapter_state} ->
        apply(adapter_module, func_name, [initialized_adapter_state | args])
      {:error, reason} ->
        Logger.error("Failed to initialize FileStorage adapter #{inspect(adapter_module)}: #{inspect(reason)}")
        {:error, {:adapter_init_failed, adapter_module, reason}}
    end
  end
end

defmodule DesktopIntegrationServer.FileStorage.Adapter do
  @moduledoc """
  Behaviour for file storage adapters.
  """

  @doc "Initializes the adapter with its specific configuration.
  The returned state will be passed as the first argument to other callbacks."
  @callback init(config :: keyword()) :: {:ok, state :: any()} | {:error, reason :: any()}

  @doc "Uploads a local file to the remote storage."
  @callback upload_file(state :: any(), local_path :: Path.t(), remote_name :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, reason :: any()} # Returns remote path or identifier

  @doc "Downloads a remote file to the local filesystem."
  @callback download_file(state :: any(), remote_name :: String.t(), local_path :: Path.t(), opts :: keyword()) ::
              {:ok, Path.t()} | {:error, reason :: any()} # Returns local path

  @doc "Lists files/directories in a remote path."
  @callback list_files(state :: any(), remote_path :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, reason :: any()} # List of file/dir names as strings
end
