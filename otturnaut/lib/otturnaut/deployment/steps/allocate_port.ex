defmodule Otturnaut.Deployment.Steps.AllocatePort do
  @moduledoc """
  Allocates a port for the new deployment.

  On failure of a later step, the `undo/4` callback releases the port
  back to the pool.
  """

  use Reactor.Step

  @impl true
  def run(arguments, _context, _options) do
    %{port_manager: port_manager} = arguments

    case port_manager.allocate() do
      {:ok, port} ->
        {:ok, port}

      {:error, reason} ->
        {:error, {:port_allocation_failed, reason}}
    end
  end

  @impl true
  def undo(port, arguments, _context, _options) do
    %{port_manager: port_manager} = arguments
    port_manager.release(port)
    :ok
  end
end
