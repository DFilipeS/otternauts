defmodule Otturnaut.Runtime do
  @moduledoc """
  Behaviour for container/process runtimes.

  Otturnaut supports multiple runtimes (Docker, Podman, systemd) through
  this common interface. Each runtime implements discovery, lifecycle
  management, and port mapping queries.

  ## Implementations

  - `Otturnaut.Runtime.Docker` - Docker container runtime (Phase 1)
  - `Otturnaut.Runtime.Podman` - Podman container runtime (future)
  - `Otturnaut.Runtime.Systemd` - systemd service runtime (future)
  """

  @type app_id :: String.t()
  @type container_id :: String.t()

  @type app_info :: %{
          id: app_id(),
          container_id: container_id(),
          port: pos_integer() | nil,
          status: :running | :stopped | :unknown,
          image: String.t() | nil
        }

  @type start_opts :: %{
          image: String.t(),
          port: pos_integer(),
          container_port: pos_integer(),
          env: map(),
          name: String.t()
        }

  @doc """
  Lists all apps managed by Otturnaut on this runtime.

  Returns apps matching the `otturnaut-*` naming convention.
  """
  @callback list_apps() :: {:ok, [app_info()]} | {:error, term()}

  @doc """
  Starts a new container/service.
  """
  @callback start(start_opts()) :: {:ok, container_id()} | {:error, term()}

  @doc """
  Stops a running container/service by name.
  """
  @callback stop(String.t()) :: :ok | {:error, term()}

  @doc """
  Removes a stopped container/service.
  """
  @callback remove(String.t()) :: :ok | {:error, term()}

  @doc """
  Gets the status of a container/service.
  """
  @callback status(String.t()) :: {:ok, :running | :stopped | :not_found} | {:error, term()}

  @doc """
  Gets the host port mapping for a container/service.
  """
  @callback get_port(String.t()) :: {:ok, pos_integer()} | {:error, term()}

  @doc """
  Loads a Docker image from a tarball (for artifact-based deployments).
  """
  @callback load_image(String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Builds an image from a Dockerfile.
  """
  @callback build_image(String.t(), String.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
