defmodule Otturnaut.Deployment.Steps.UpdateAppState do
  @moduledoc """
  Updates the application state with the new deployment information.

  On failure of a later step, the `undo/4` callback restores the previous
  state or deletes the entry if this was a fresh deployment.
  """

  use Reactor.Step

  @impl true
  def run(arguments, _context, _options) do
    %{
      deployment: deployment,
      port: port,
      container: container,
      previous_state: previous_state,
      app_state: app_state
    } = arguments

    app = %{
      deployment_id: deployment.id,
      container_name: container.container_name,
      port: port,
      domains: deployment.domains,
      status: :running
    }

    :ok = app_state.put(deployment.app_id, app)

    {:ok, %{app_id: deployment.app_id, previous_state: previous_state}}
  end

  @impl true
  def undo(result, arguments, _context, _options) do
    %{app_id: app_id, previous_state: previous_state} = result
    %{app_state: app_state} = arguments

    case previous_state do
      %{previous_container_name: nil, previous_port: nil} ->
        _ = app_state.delete(app_id)
        :ok

      %{previous_container_name: container_name, previous_port: port} ->
        previous_app = %{
          deployment_id: extract_deploy_id(container_name),
          container_name: container_name,
          port: port,
          domains: [],
          status: :running
        }

        _ = app_state.put(app_id, previous_app)
        :ok
    end
  end

  defp extract_deploy_id(container_name) do
    case String.split(container_name, "-", parts: 3) do
      ["otturnaut", _app_id, deploy_id] -> deploy_id
      _ -> "unknown"
    end
  end
end
