defmodule Otturnaut.Deployment.Strategy.BlueGreen do
  @moduledoc """
  Blue-green deployment strategy.

  Achieves zero-downtime by running two versions simultaneously and switching
  traffic instantly once the new version is verified healthy.

  ## Implementation

  This strategy delegates to `Otturnaut.Deployment.Reactors.BlueGreen` which
  implements the saga pattern. Each step has a corresponding `undo` callback
  that is automatically called in reverse order if a later step fails.

  ## Steps

  1. **Load previous state** — Query AppState for current deployment
  2. **Allocate port** — Get available port from port manager
  3. **Start new container** — Start new container on allocated port
  4. **Health check** — Verify new version is healthy
  5. **Switch route** — Update Caddy to point to new port (instant)
  6. **Cleanup** — Stop old container, release old port
  7. **Update app state** — Save new deployment state

  ## Failure Handling

  If any step fails, Reactor automatically calls `undo` on all completed steps
  in reverse order. This ensures no orphaned resources:

  - Allocated ports are released
  - Started containers are stopped and removed
  - Routes are restored to their previous configuration
  - App state is reverted

  ## Context

  The context struct (see `Otturnaut.Deployment.Context`) contains infrastructure
  modules that can be overridden for testing:

  - `:port_manager` — Module or server for port allocation
  - `:app_state` — Module or server for app state
  - `:caddy` — Module for Caddy route management

  Runtime configuration (`:runtime`, `:runtime_opts`) is on the deployment struct.
  """

  @behaviour Otturnaut.Deployment.Strategy

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Reactors.BlueGreen, as: BlueGreenReactor
  alias Otturnaut.Caddy.Route

  @impl true
  def name, do: "Blue-Green"

  @impl true
  def execute(deployment, context, opts \\ []) do
    result =
      Reactor.run(
        BlueGreenReactor,
        %{
          deployment: deployment,
          context: context,
          opts: opts
        }
      )

    case result do
      {:ok, %{app_id: _app_id}} ->
        completed =
          deployment
          |> Deployment.mark_completed()
          |> put_container_info_from_reactor()

        {:ok, completed}

      {:error, errors} ->
        reason = extract_error_reason(errors)
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

  defp put_container_info_from_reactor(deployment) do
    container_name = Deployment.container_name(deployment)
    %{deployment | container_name: container_name}
  end

  defp extract_error_reason(%Reactor.Error.Invalid{errors: [first | _]}) do
    extract_error_reason(first)
  end

  defp extract_error_reason(%Reactor.Error.Invalid.RunStepError{error: reason}), do: reason
end
