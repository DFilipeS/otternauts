defmodule Otturnaut.Caddy do
  @moduledoc """
  Manage Caddy reverse proxy routes.

  This module provides functions to add, remove, and list routes in Caddy's
  configuration. Routes map domains to upstream services running on localhost.

  ## Examples

      # Add a route
      route = Caddy.Route.new("myapp", "myapp.com", 3000)
      :ok = Caddy.add_route(route)

      # List all routes
      {:ok, routes} = Caddy.list_routes()

      # Remove a route
      :ok = Caddy.remove_route("myapp")

      # Check if Caddy is running
      :ok = Caddy.health_check()

  ## Configuration

  Routes are stored under a dedicated HTTP server in Caddy's config at:

      apps.http.servers.otturnaut.routes

  This keeps Otturnaut-managed routes separate from any manual Caddy configuration.
  """

  alias Otturnaut.Caddy.{Client, Route}

  @server_path "/apps/http/servers/otturnaut"
  @routes_path "#{@server_path}/routes"

  # Default ports - can be overridden via opts
  @default_http_port 80
  @default_https_port 443

  @type error ::
          {:error,
           :caddy_unavailable | :not_found | :request_failed | {:unexpected_status, integer()}}

  @doc """
  Checks if Caddy's admin API is reachable.

  Returns `:ok` if Caddy is running and responsive, or an error tuple.

  ## Examples

      iex> Caddy.health_check()
      :ok

      iex> Caddy.health_check()
      {:error, :caddy_unavailable}

  """
  @spec health_check(keyword()) :: :ok | error()
  def health_check(opts \\ []) do
    Client.health_check(opts)
  end

  @doc """
  Adds a route to Caddy's configuration.

  If this is the first route, it will also create the Otturnaut HTTP server
  configuration.

  ## Examples

      route = Route.new("myapp", "myapp.com", 3000)
      :ok = Caddy.add_route(route)

  """
  @spec add_route(Route.t(), keyword()) :: :ok | error()
  def add_route(%Route{} = route, opts \\ []) do
    with :ok <- ensure_server_exists(opts) do
      config = Route.to_caddy_config(route)
      # POST to routes path appends a single item to the array
      Client.set_config(@routes_path, config, opts)
    end
  end

  @doc """
  Removes a route from Caddy's configuration by its ID.

  ## Examples

      :ok = Caddy.remove_route("myapp")

  """
  @spec remove_route(String.t(), keyword()) :: :ok | error()
  def remove_route(route_id, opts \\ []) do
    Client.delete_by_id(route_id, opts)
  end

  @doc """
  Lists all routes currently managed by Otturnaut.

  Returns `{:ok, routes}` where routes is a list of `Route` structs,
  or `{:ok, []}` if no routes are configured.

  ## Examples

      {:ok, routes} = Caddy.list_routes()
      Enum.each(routes, fn route ->
        IO.puts("\#{route.id}: \#{inspect(route.domains)} -> :\#{route.upstream_port}")
      end)

  """
  @spec list_routes(keyword()) :: {:ok, [Route.t()]} | error()
  def list_routes(opts \\ []) do
    case Client.get_config(@routes_path, opts) do
      {:ok, routes} when is_list(routes) ->
        parsed_routes =
          routes
          |> Enum.map(&Route.from_caddy_config/1)
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, route} -> route end)

        {:ok, parsed_routes}

      {:ok, nil} ->
        {:ok, []}

      {:error, {:unexpected_status, 404, _body}} ->
        {:ok, []}

      {:error, {:unexpected_status, 400, _body}} ->
        # Server doesn't exist yet
        {:ok, []}

      error ->
        error
    end
  end

  @doc """
  Gets a specific route by its ID.

  ## Examples

      {:ok, route} = Caddy.get_route("myapp")

  """
  @spec get_route(String.t(), keyword()) :: {:ok, Route.t()} | error()
  def get_route(route_id, opts \\ []) do
    case Client.get_by_id(route_id, opts) do
      {:ok, config} when is_map(config) ->
        Route.from_caddy_config(config)

      {:error, {:unexpected_status, 404, _body}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  # Ensures the Otturnaut HTTP server exists in Caddy's config.
  # Creates it if it doesn't exist.
  defp ensure_server_exists(opts) do
    case Client.get_config(@server_path, opts) do
      {:ok, config} when is_map(config) ->
        :ok

      {:ok, nil} ->
        create_server(opts)

      {:error, {:unexpected_status, 404, _body}} ->
        create_server(opts)

      {:error, {:unexpected_status, 400, _body}} ->
        # Parent path doesn't exist, need to create the full structure
        create_server(opts)

      error ->
        error
    end
  end

  # Creates the Otturnaut HTTP server configuration.
  # This server listens on configurable ports and handles routes added by Otturnaut.
  # We handle different states of the config: empty, partially initialized, etc.
  defp create_server(opts) do
    listen_addresses = build_listen_addresses(opts)
    disable_auto_https = Keyword.get(opts, :disable_auto_https, false)

    server_config =
      %{
        "listen" => listen_addresses,
        "routes" => []
      }
      |> maybe_disable_auto_https(disable_auto_https)

    # Check the current state of the config
    case Client.get_config("", opts) do
      {:ok, nil} ->
        # Config is completely empty, create the full structure at root
        full_config = %{
          "apps" => %{
            "http" => %{
              "servers" => %{
                "otturnaut" => server_config
              }
            }
          }
        }

        Client.set_config("", full_config, opts)

      {:ok, %{"apps" => %{"http" => %{"servers" => _}}}} ->
        # HTTP servers exist, just add our server
        Client.set_config(@server_path, server_config, opts)

      {:ok, %{"apps" => %{"http" => _}}} ->
        # HTTP app exists but no servers, create servers
        servers_config = %{
          "otturnaut" => server_config
        }

        Client.set_config("/apps/http/servers", servers_config, opts)

      {:ok, %{"apps" => _}} ->
        # Apps exists but no HTTP app
        http_config = %{
          "servers" => %{
            "otturnaut" => server_config
          }
        }

        Client.set_config("/apps/http", http_config, opts)

      {:ok, %{}} ->
        # Config exists but is empty object, create apps
        apps_config = %{
          "http" => %{
            "servers" => %{
              "otturnaut" => server_config
            }
          }
        }

        Client.set_config("/apps", apps_config, opts)

      error ->
        error
    end
  end

  defp build_listen_addresses(opts) do
    http_port = Keyword.get(opts, :http_port, @default_http_port)
    https_port = Keyword.get(opts, :https_port, @default_https_port)
    [":#{http_port}", ":#{https_port}"]
  end

  defp maybe_disable_auto_https(config, true) do
    Map.put(config, "automatic_https", %{"disable" => true})
  end

  defp maybe_disable_auto_https(config, false), do: config
end
