defmodule Otturnaut.Deployment.Steps.LoadPreviousState do
  @moduledoc """
  Loads the previous deployment state for an application.

  This is a read-only step that queries AppState to get the current
  deployment information (container name, port) which is needed for
  rollback and cleanup operations.

  ## Returns

  A map with `:previous_container_name` and `:previous_port` keys,
  or an empty map if no previous deployment exists.
  """

  use Reactor.Step

  @impl true
  def run(arguments, _context, _options) do
    %{app_id: app_id, app_state: app_state} = arguments

    case app_state.get(app_id) do
      {:ok, app} ->
        {:ok,
         %{
           previous_container_name: app.container_name,
           previous_port: app.port
         }}

      {:error, :not_found} ->
        {:ok, %{previous_container_name: nil, previous_port: nil}}
    end
  end
end
