defmodule Otturnaut.Deployment.Reactors.BlueGreen do
  @moduledoc """
  Blue-green deployment reactor.

  Orchestrates the deployment steps with automatic rollback on failure.
  Each step that modifies state has an `undo` callback that is automatically
  called in reverse order if a later step fails.

  ## Steps

  1. **load_previous_state** — Query AppState for current deployment
  2. **allocate_port** — Get available port from port manager
  3. **start_container** — Start new container on allocated port
  4. **health_check** — Verify new version is healthy
  5. **switch_route** — Update Caddy to point to new port
  6. **cleanup** — Stop old container, release old port
  7. **update_app_state** — Save new deployment state

  ## Inputs

  - `:deployment` — The `Otturnaut.Deployment` struct
  - `:context` — The `Otturnaut.Deployment.Context` with infrastructure modules
  - `:opts` — Strategy options (e.g., `:subscriber` for progress updates)

  ## Returns

  On success, returns a map with the completed deployment information.
  On failure, Reactor automatically calls undo on completed steps and
  returns the error.
  """

  use Reactor

  alias Otturnaut.Deployment.Steps

  input :deployment
  input :context
  input :opts

  step :load_previous_state, Steps.LoadPreviousState do
    argument :app_id, input(:deployment), transform: & &1.app_id
    argument :app_state, input(:context), transform: & &1.app_state
  end

  step :allocate_port, Steps.AllocatePort do
    argument :port_manager, input(:context), transform: & &1.port_manager
  end

  step :start_container, Steps.StartContainer do
    argument :deployment, input(:deployment)
    argument :port, result(:allocate_port)
  end

  step :health_check, Steps.HealthCheck do
    argument :deployment, input(:deployment)
    argument :container, result(:start_container)
    argument :opts, input(:opts)
  end

  step :switch_route, Steps.SwitchRoute do
    argument :deployment, input(:deployment)
    argument :port, result(:allocate_port)
    argument :previous_state, result(:load_previous_state)
    argument :caddy, input(:context), transform: & &1.caddy

    wait_for :health_check
  end

  step :cleanup, Steps.Cleanup do
    argument :deployment, input(:deployment)
    argument :previous_state, result(:load_previous_state)
    argument :port_manager, input(:context), transform: & &1.port_manager

    wait_for :switch_route
  end

  step :update_app_state, Steps.UpdateAppState do
    argument :deployment, input(:deployment)
    argument :port, result(:allocate_port)
    argument :container, result(:start_container)
    argument :previous_state, result(:load_previous_state)
    argument :app_state, input(:context), transform: & &1.app_state

    wait_for :cleanup
  end

  return :update_app_state
end
