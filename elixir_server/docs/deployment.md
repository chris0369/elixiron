# Deploying the Elixir Release

This document describes how to deploy the pre-built release tarball of the `DesktopIntegrationServer`.

## Deployment Steps

1.  **Build the Release:** Follow the instructions in `release.md` to build the release and generate the `.tar.gz` file.
2.  **Transfer the Artifact:** Copy the release tarball (e.g., `desktop_integration_server-0.1.0.tar.gz`) from the build location (`_build/prod/rel/desktop_integration_server/releases/<version>/`) to the target server(s). This can be done via secure copy (SCP), USB drive, or any method suitable for transferring files, especially into air-gapped environments.
3.  **Extract the Release:** On the target server, extract the tarball into the desired installation directory:
    ```bash
    # Example on a Linux-like system
    mkdir /opt/desktop_integration_server
    tar -xzf desktop_integration_server-0.1.0.tar.gz -C /opt/desktop_integration_server
    ```
4.  **Configure the Environment:** Set any required environment variables that `config/runtime.exs` expects. This is how you configure database connections, ports, secrets, and distribution settings.
    *   **Single Node:** Set variables specific to a single instance.
    *   **Distributed/Clustered:**
        *   Set `RELEASE_DISTRIBUTION=name`
        *   Set `RELEASE_NODE_NAME=your_app_name@ip_or_hostname` (must be unique per node)
        *   Set `RELEASE_COOKIE=your_secret_cookie` (must be the same across all nodes in the cluster)
        *   Configure node connection details (e.g., via `runtime.exs` potentially reading other environment variables listing peer nodes if not using a discovery mechanism like `libcluster`).

5.  **Run the Application:** Navigate to the installation directory (e.g., `/opt/desktop_integration_server`) and use the provided scripts in the `bin/` directory to manage the application:
    *   **Start in foreground:** `bin/desktop_integration_server console` (useful for debugging)
    *   **Start as daemon:** `bin/desktop_integration_server start`
    *   **Stop:** `bin/desktop_integration_server stop`
    *   **Connect remote console:** `bin/desktop_integration_server remote_console`

## Air-Gapped Environments

The release is entirely self-contained. Once the tarball is transferred to the air-gapped machine, no internet connection or external dependencies (like Elixir or Mix) are required to run the application.

## Process Supervision

For production deployments, it is highly recommended to run the release under a process supervisor like `systemd` (Linux) or as a Windows Service. This ensures the application:
*   Starts automatically on system boot.
*   Restarts automatically if it crashes.
*   Can be managed using standard system tools (e.g., `systemctl start|stop|status your_app`).

Consult the documentation for `systemd` or Windows Services for creating appropriate service definition files that execute the `bin/desktop_integration_server start` command with the correct user and environment variables. 