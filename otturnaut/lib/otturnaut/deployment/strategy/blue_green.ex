defmodule Otturnaut.Deployment.Strategy.BlueGreen do
  @moduledoc """
  Blue-green deployment strategy.

  Achieves zero-downtime by running two versions simultaneously and switching
  traffic instantly once the new version is verified healthy.

  ## Steps

  1. **Allocate port** — Get available port from port manager
  2. **Start new container** — Start new container on allocated port
  3. **Health check** — Verify new version is healthy
  4. **Switch route** — Update Caddy to point to new port (instant)
  5. **Stop old container** — Stop previous container
  6. **Release old port** — Return old port to pool

  ## Context

  The context struct (see `Otturnaut.Deployment.Context`) contains infrastructure
  modules that can be overridden for testing:

  - `:port_manager` — Module or server for port allocation
  - `:app_state` — Module or server for app state
  - `:caddy` — Module for Caddy route management

  Runtime configuration (`:runtime`, `:runtime_opts`) is on the deployment struct.

  ## Failure Handling

  If any step before "switch route" fails, the old version remains live.
  We stop the new container, release the allocated port, and report failure.
  Users experience no downtime.
  """

  @behaviour Otturnaut.Deployment.Strategy

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Strategy
  alias Otturnaut.Caddy.Route

  @impl true
  def name, do: "Blue-Green"

  @impl true
  def execute(deployment, context, opts \\ []) do
    %{port_manager: port_manager, app_state: app_state, caddy: caddy} = context
    %{runtime: runtime, runtime_opts: runtime_opts} = deployment

    # Get current state if app exists
    deployment = load_previous_state(deployment, app_state)

    with {:ok, deployment} <- allocate_port(deployment, port_manager, opts),
         {:ok, deployment} <- start_container(deployment, runtime, runtime_opts, opts),
         {:ok, deployment} <- health_check(deployment, runtime, runtime_opts, opts),
         {:ok, deployment} <- switch_route(deployment, caddy, opts),
         {:ok, deployment} <- stop_old_container(deployment, runtime, runtime_opts, opts),
         {:ok, deployment} <- release_old_port(deployment, port_manager, opts),
         {:ok, deployment} <- update_app_state(deployment, app_state, opts) do
      {:ok, Deployment.mark_completed(deployment)}
    else
      {:error, reason, deployment} ->
        {:error, reason, Deployment.mark_failed(deployment, reason)}
    end
  end

  @impl true
  def rollback(deployment, context, opts \\ []) do
    %{port_manager: port_manager, caddy: caddy} = context
    %{runtime: runtime, runtime_opts: runtime_opts} = deployment

    if deployment.container_name do
      runtime.stop(deployment.container_name, runtime_opts)
      runtime.remove(deployment.container_name, runtime_opts)
    end

    if deployment.port do
      port_manager.release(deployment.port)
    end

    if deployment.previous_port && deployment.status == :failed do
      route = %Route{
        id: "#{deployment.app_id}-route",
        domains: deployment.domains,
        upstream_port: deployment.previous_port
      }

      caddy.add_route(route, opts)
    end

    :ok
  end

  # Steps

  defp load_previous_state(deployment, app_state) do
    case app_state.get(deployment.app_id) do
      {:ok, app} ->
        %{
          deployment
          | previous_container_name: app.container_name,
            previous_port: app.port
        }

      {:error, :not_found} ->
        deployment
    end
  end

  defp allocate_port(deployment, port_manager, opts) do
    Strategy.notify_progress(opts, :allocate_port, "Allocating port")

    case port_manager.allocate() do
      {:ok, port} ->
        {:ok, %{deployment | port: port}}

      {:error, reason} ->
        {:error, {:port_allocation_failed, reason}, deployment}
    end
  end

  defp start_container(deployment, runtime, runtime_opts, opts) do
    Strategy.notify_progress(opts, :start_container, "Starting container")

    container_name = Deployment.container_name(deployment)

    start_opts =
      %{
        image: deployment.image,
        port: deployment.port,
        container_port: deployment.container_port,
        env: deployment.env,
        name: container_name
      }
      |> Map.merge(Map.new(runtime_opts))

    case runtime.start(start_opts) do
      {:ok, container_id} ->
        {:ok, %{deployment | container_name: container_name, container_id: container_id}}

      {:error, reason} ->
        {:error, {:container_start_failed, reason}, deployment}
    end
  end

  defp health_check(deployment, runtime, runtime_opts, opts) do
    Strategy.notify_progress(opts, :health_check, "Checking health")

    check_config = %{
      type: :running,
      runtime: runtime,
      runtime_opts: runtime_opts,
      name: deployment.container_name
    }

    health_opts = Keyword.get(opts, :health_check, [])
    max_attempts = Keyword.get(health_opts, :max_attempts, 10)
    interval = Keyword.get(health_opts, :interval, 1_000)

    case Otturnaut.HealthCheck.check_with_retry(check_config,
           max_attempts: max_attempts,
           interval: interval
         ) do
      :healthy ->
        {:ok, deployment}

      :unhealthy ->
        {:error, :health_check_failed, deployment}
    end
  end

  defp switch_route(deployment, caddy, opts) do
    # Only switch routes if we have domains configured
    if deployment.domains == [] do
      {:ok, deployment}
    else
      Strategy.notify_progress(opts, :switch_route, "Switching route to new container")

      route = %Route{
        id: "#{deployment.app_id}-route",
        domains: deployment.domains,
        upstream_port: deployment.port
      }

      case caddy.add_route(route, opts) do
        :ok ->
          {:ok, deployment}

        {:error, reason} ->
          {:error, {:route_switch_failed, reason}, deployment}
      end
    end
  end

  defp stop_old_container(deployment, runtime, runtime_opts, opts) do
    case deployment.previous_container_name do
      nil ->
        {:ok, deployment}

      container_name ->
        Strategy.notify_progress(opts, :stop_old, "Stopping old container")

        # Stop and remove - failures here are not critical
        _ = runtime.stop(container_name, runtime_opts)
        _ = runtime.remove(container_name, runtime_opts)

        {:ok, deployment}
    end
  end

  defp release_old_port(deployment, port_manager, opts) do
    case deployment.previous_port do
      nil ->
        {:ok, deployment}

      port ->
        Strategy.notify_progress(opts, :release_port, "Releasing old port")
        _ = port_manager.release(port)
        {:ok, deployment}
    end
  end

  defp update_app_state(deployment, app_state, _opts) do
    app = %{
      deployment_id: deployment.id,
      container_name: deployment.container_name,
      port: deployment.port,
      domains: deployment.domains,
      status: :running
    }

    :ok = app_state.put(deployment.app_id, app)
    {:ok, deployment}
  end
end
