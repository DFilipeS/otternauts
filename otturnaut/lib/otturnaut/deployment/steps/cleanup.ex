defmodule Otturnaut.Deployment.Steps.Cleanup do
  @moduledoc """
  Cleans up the old deployment resources.

  This step stops and removes the old container and releases its port.
  It is best-effort and does not have an undo callback - if cleanup
  fails, we don't want to undo the successful new deployment.
  """

  use Reactor.Step

  @impl true
  def run(arguments, _context, _options) do
    %{
      deployment: deployment,
      previous_state: previous_state,
      port_manager: port_manager
    } = arguments

    %{runtime: runtime, runtime_opts: runtime_opts} = deployment

    if previous_state.previous_container_name do
      _ = runtime.stop(previous_state.previous_container_name, runtime_opts)
      _ = runtime.remove(previous_state.previous_container_name, runtime_opts)
    end

    if previous_state.previous_port do
      _ = port_manager.release(previous_state.previous_port)
    end

    {:ok, :cleaned_up}
  end
end
