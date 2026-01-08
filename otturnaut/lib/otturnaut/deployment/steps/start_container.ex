defmodule Otturnaut.Deployment.Steps.StartContainer do
  @moduledoc """
  Starts a new container for the deployment.

  On failure of a later step, the `undo/4` callback stops and removes
  the container.
  """

  use Reactor.Step

  @impl true
  def run(arguments, _context, _options) do
    %{
      deployment: deployment,
      port: port
    } = arguments

    %{runtime: runtime, runtime_opts: runtime_opts} = deployment

    container_name = Otturnaut.Deployment.container_name(deployment)

    start_opts =
      %{
        image: deployment.image,
        port: port,
        container_port: deployment.container_port,
        env: deployment.env,
        name: container_name
      }
      |> Map.merge(Map.new(runtime_opts))

    case runtime.start(start_opts) do
      {:ok, container_id} ->
        {:ok, %{container_name: container_name, container_id: container_id}}

      {:error, reason} ->
        {:error, {:container_start_failed, reason}}
    end
  end

  @impl true
  def undo(result, arguments, _context, _options) do
    %{deployment: deployment} = arguments
    %{runtime: runtime, runtime_opts: runtime_opts} = deployment
    %{container_name: container_name} = result

    _ = runtime.stop(container_name, runtime_opts)
    _ = runtime.remove(container_name, runtime_opts)

    :ok
  end
end
