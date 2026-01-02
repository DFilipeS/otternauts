defmodule Otturnaut.Deployment do
  @moduledoc """
  Deployment struct and orchestration.

  A deployment represents a request to deploy an application. It contains
  all the configuration needed for the strategy to execute the deployment.

  ## Lifecycle

  1. Create deployment with `new/1`
  2. Execute with a strategy via `execute/3`
  3. On success, deployment contains new container info
  4. On failure, rollback cleans up partial state
  5. To remove a deployed app, use `undeploy/3`

  ## Example

      deployment = Deployment.new(%{
        app_id: "myapp",
        image: "myapp:latest",
        container_port: 3000,
        env: %{"DATABASE_URL" => "postgres://..."},
        domains: ["myapp.com"]
      })

      context = %{
        runtime: Otturnaut.Runtime.Docker,
        port_manager: Otturnaut.PortManager,
        app_state: Otturnaut.AppState,
        caddy: Otturnaut.Caddy
      }

      case Deployment.execute(deployment, Strategy.BlueGreen, context) do
        {:ok, completed} ->
          IO.puts("Deployed to port \#{completed.port}")

        {:error, reason, partial} ->
          IO.puts("Failed: \#{inspect(reason)}")
          Deployment.rollback(partial, Strategy.BlueGreen, context)
      end

      # Later, to remove the application
      Deployment.undeploy("myapp", context)

  """
  require Logger

  @type status :: :pending | :in_progress | :completed | :failed | :rolled_back

  @type t :: %__MODULE__{
          id: String.t(),
          app_id: String.t(),
          image: String.t(),
          container_port: pos_integer(),
          env: map(),
          domains: [String.t()],
          # Populated during execution
          port: pos_integer() | nil,
          container_name: String.t() | nil,
          container_id: String.t() | nil,
          # Previous deployment info for rollback
          previous_container_name: String.t() | nil,
          previous_port: pos_integer() | nil,
          # Status tracking
          status: status(),
          error: term() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :app_id, :image, :container_port]
  defstruct [
    :id,
    :app_id,
    :image,
    :container_port,
    :port,
    :container_name,
    :container_id,
    :previous_container_name,
    :previous_port,
    :error,
    :started_at,
    :completed_at,
    env: %{},
    domains: [],
    status: :pending
  ]

  @doc """
  Creates a new deployment struct.

  Required fields:
  - `:app_id` - Application identifier
  - `:image` - Docker image to deploy
  - `:container_port` - Port the application listens on inside the container

  Optional fields:
  - `:env` - Environment variables (default: `%{}`)
  - `:domains` - Domains to route to this app (default: `[]`)
  - `:id` - Deployment ID (auto-generated if not provided)
  """
  @spec new(map()) :: t()
  def new(attrs) do
    id = Map.get_lazy(attrs, :id, &generate_id/0)

    struct!(
      __MODULE__,
      attrs
      |> Map.put(:id, id)
      |> Map.put(:status, :pending)
    )
  end

  @doc """
  Executes a deployment using the given strategy.

  Returns `{:ok, deployment}` on success or `{:error, reason, deployment}` on failure.
  The returned deployment contains the updated state regardless of outcome.
  """
  @spec execute(t(), module(), map(), keyword()) ::
          {:ok, t()} | {:error, term(), t()}
  def execute(deployment, strategy, context, opts \\ []) do
    deployment = %{deployment | status: :in_progress, started_at: DateTime.utc_now()}
    strategy.execute(deployment, context, opts)
  end

  @doc """
  Rolls back a deployment using the given strategy.

  Cleans up any resources created during a failed deployment.
  """
  @spec rollback(t(), module(), map(), keyword()) :: :ok | {:error, term()}
  def rollback(deployment, strategy, context, opts \\ []) do
    strategy.rollback(deployment, context, opts)
  end

  @doc """
  Undeploys an application by removing all its resources.

  This operation is idempotent - running it multiple times has the same effect
  as running it once. Missing resources are treated as successful cleanup.

  ## Undeploy Flow

  1. Retrieve app state (return :ok if not found)
  2. Stop container (if running)
  3. Remove container
  4. Remove Caddy routes (if domains configured)
  5. Release allocated port
  6. Clear application state

  ## Options

  - `:subscriber` - PID to receive progress updates

  ## Examples

      context = %{
        runtime: Otturnaut.Runtime.Docker,
        app_state: Otturnaut.AppState,
        port_manager: Otturnaut.PortManager,
        caddy: Otturnaut.Caddy
      }

      # Basic undeploy
      :ok = Deployment.undeploy("myapp", context)

      # With progress notifications
      :ok = Deployment.undeploy("myapp", context, subscriber: self())

      # Idempotent - safe to run again
      :ok = Deployment.undeploy("myapp", context)

  """
  @spec undeploy(String.t(), map(), keyword()) :: :ok
  def undeploy(app_id, context, opts \\ []) do
    %{
      runtime: runtime,
      app_state: app_state,
      port_manager: port_manager,
      caddy: caddy
    } = context

    runtime_opts = Map.get(context, :runtime_opts, [])

    # Step 1: Retrieve app state
    notify_undeploy_progress(opts, :retrieve_state, "Retrieving application state")

    case app_state.get(app_id) do
      {:error, :not_found} ->
        # Idempotent: nothing to clean up
        :ok

      {:ok, app} ->
        # Step 2: Stop container if running
        stop_container_if_running(app.container_name, runtime, runtime_opts, opts)

        # Step 3: Remove container
        remove_container(app.container_name, runtime, runtime_opts, opts)

        # Step 4: Remove Caddy routes (if domains configured)
        remove_routes_if_configured(app_id, app.domains, caddy, opts)

        # Step 5: Release port
        release_port(app.port, port_manager, opts)

        # Step 6: Clear app state
        clear_app_state(app_id, app_state, opts)

        :ok
    end
  end

  @doc """
  Generates a container name for the deployment.

  Format: `otturnaut-{app_id}-{deploy_id}`
  """
  @spec container_name(t()) :: String.t()
  def container_name(%__MODULE__{app_id: app_id, id: id}) do
    "otturnaut-#{app_id}-#{id}"
  end

  @doc """
  Marks the deployment as completed successfully.
  """
  @spec mark_completed(t()) :: t()
  def mark_completed(deployment) do
    %{deployment | status: :completed, completed_at: DateTime.utc_now()}
  end

  @doc """
  Marks the deployment as failed with an error.
  """
  @spec mark_failed(t(), term()) :: t()
  def mark_failed(deployment, error) do
    %{deployment | status: :failed, error: error, completed_at: DateTime.utc_now()}
  end

  @doc """
  Marks the deployment as rolled back.
  """
  @spec mark_rolled_back(t()) :: t()
  def mark_rolled_back(deployment) do
    %{deployment | status: :rolled_back, completed_at: DateTime.utc_now()}
  end

  # Helpers

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end

  # Undeploy helpers

  defp stop_container_if_running(container_name, runtime, runtime_opts, opts) do
    notify_undeploy_progress(opts, :stop_container, "Stopping container")

    case runtime.status(container_name, runtime_opts) do
      {:ok, :running} ->
        case runtime.stop(container_name, runtime_opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to stop container #{container_name}: #{inspect(reason)}")
            :ok
        end

      {:ok, _other_status} ->
        # Container is stopped or not found, skip stop
        :ok

      {:error, reason} ->
        Logger.warning("Failed to check container status #{container_name}: #{inspect(reason)}")
        :ok
    end
  end

  defp remove_container(container_name, runtime, runtime_opts, opts) do
    notify_undeploy_progress(opts, :remove_container, "Removing container")

    case runtime.remove(container_name, runtime_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to remove container #{container_name}: #{inspect(reason)}")
        :ok
    end
  end

  defp remove_routes_if_configured(app_id, domains, caddy, opts) do
    if domains == [] do
      :ok
    else
      notify_undeploy_progress(opts, :remove_routes, "Removing Caddy routes")
      route_id = "#{app_id}-route"

      case caddy.remove_route(route_id, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to remove Caddy route #{route_id}: #{inspect(reason)}")
          :ok
      end
    end
  end

  defp release_port(port, port_manager, opts) do
    notify_undeploy_progress(opts, :release_port, "Releasing port #{port}")
    port_manager.release(port)
    :ok
  end

  defp clear_app_state(app_id, app_state, opts) do
    notify_undeploy_progress(opts, :clear_state, "Clearing application state")
    app_state.delete(app_id)
    :ok
  end

  defp notify_undeploy_progress(opts, step, message) do
    case Keyword.get(opts, :subscriber) do
      nil -> :ok
      pid -> send(pid, {:undeploy_progress, %{step: step, message: message}})
    end

    :ok
  end
end
