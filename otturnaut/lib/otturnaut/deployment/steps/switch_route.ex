defmodule Otturnaut.Deployment.Steps.SwitchRoute do
  @moduledoc """
  Switches the Caddy route to point to the new container.

  On failure of a later step, the `undo/4` callback restores the previous
  route configuration or removes the new route if this was a fresh deployment.
  """

  use Reactor.Step

  alias Otturnaut.Caddy.Route

  @impl true
  def run(arguments, _context, options) do
    %{
      deployment: deployment,
      port: port,
      previous_state: previous_state,
      caddy: caddy
    } = arguments

    if deployment.domains == [] do
      {:ok, :no_route_needed}
    else
      route = %Route{
        id: "#{deployment.app_id}-route",
        domains: deployment.domains,
        upstream_port: port
      }

      case caddy.add_route(route, options) do
        :ok ->
          {:ok, %{route_id: route.id, previous_port: previous_state.previous_port}}

        {:error, reason} ->
          {:error, {:route_switch_failed, reason}}
      end
    end
  end

  @impl true
  def undo(result, arguments, _context, options) do
    case result do
      :no_route_needed ->
        :ok

      %{route_id: route_id, previous_port: nil} ->
        %{caddy: caddy} = arguments
        _ = caddy.remove_route(route_id, options)
        :ok

      %{route_id: _route_id, previous_port: previous_port} ->
        %{deployment: deployment, caddy: caddy} = arguments

        route = %Route{
          id: "#{deployment.app_id}-route",
          domains: deployment.domains,
          upstream_port: previous_port
        }

        _ = caddy.add_route(route, options)
        :ok
    end
  end
end
