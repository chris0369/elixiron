# Building Elixir Releases

This document outlines the process for building a self-contained, deployable release of the `DesktopIntegrationServer` application.

## What is a Release?

An Elixir release is a self-contained package that includes:
*   Your application's compiled bytecode (`.beam` files).
*   All of your application's dependencies.
*   The entire Erlang Runtime System (ERTS).
*   Scripts to start, stop, and manage the running application.

Releases are the standard way to prepare Elixir applications for deployment. They do not require Elixir or Mix to be installed on the target machine, making them ideal for production environments, including air-gapped systems.

## Building the Release

1.  **Ensure Dependencies are Locked:** Make sure your `mix.lock` file is up-to-date by running `mix deps.get` if you've changed dependencies.
2.  **Compile:** Ensure your project compiles cleanly with `mix compile`.
3.  **Generate the Release:** Navigate to the `elixir_server` directory in your terminal and run the release task:
    ```powershell
    mix release
    ```
    This command will compile your application and bundle everything into the `_build/prod/rel/desktop_integration_server` directory (the exact path might vary slightly based on OTP/Elixir versions).

## Runtime Configuration

Environment-specific configuration (like ports, secrets, or node names for distribution) should not be compiled into the release. Instead, use the `config/runtime.exs` file. This file is evaluated *when the release starts*, allowing you to read configuration from environment variables or other runtime sources.

## Output

The build process generates a tarball (e.g., `desktop_integration_server-0.1.0.tar.gz`) inside the release directory (`_build/prod/rel/desktop_integration_server/releases/<version>/`). This tarball contains everything needed to run the application on a target machine with the same OS and architecture as the build machine. 