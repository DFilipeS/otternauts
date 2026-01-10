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

  require Logger

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Reactors.BlueGreen, as: BlueGreenReactor

  @impl true
  def name, do: "Blue-Green"

  @impl true
  def execute(deployment, context, opts \\ []) do
    log_deployment_start(deployment)

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
      {:ok, reactor_result} ->
        completed =
          deployment
          |> put_deployment_info(reactor_result)
          |> Deployment.mark_completed()

        log_deployment_success(completed)
        {:ok, completed}

      {:error, errors} ->
        reason = extract_error_reason(errors)
        log_deployment_failure(deployment, reason)
        {:error, reason, Deployment.mark_failed(deployment, reason)}
    end
  end

  defp log_deployment_start(deployment) do
    Logger.info(
      "Starting deployment app_id=#{deployment.app_id} deployment_id=#{deployment.id} image=#{deployment.image} strategy=blue-green"
    )
  end

  defp log_deployment_success(completed) do
    Logger.info(
      "Deployment completed app_id=#{completed.app_id} deployment_id=#{completed.id} port=#{completed.port} container=#{completed.container_name}"
    )
  end

  defp log_deployment_failure(deployment, reason) do
    Logger.error(
      "Deployment failed app_id=#{deployment.app_id} deployment_id=#{deployment.id} error=#{inspect(reason)}"
    )
  end

  defp put_deployment_info(deployment, reactor_result) do
    %{
      deployment
      | port: reactor_result.port,
        container_name: reactor_result.container_name,
        container_id: reactor_result.container_id,
        previous_container_name: reactor_result.previous_container_name,
        previous_port: reactor_result.previous_port
    }
  end

  defp extract_error_reason(%Reactor.Error.Invalid{errors: [first | _]}) do
    extract_error_reason(first)
  end

  defp extract_error_reason(%Reactor.Error.Invalid.RunStepError{error: reason}), do: reason
end
