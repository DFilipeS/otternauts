defmodule Otturnaut.Caddy.Route do
  @moduledoc """
  Represents a route configuration for Caddy.

  A route maps one or more domains to an upstream service running on localhost.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          domains: [String.t()],
          upstream_port: pos_integer()
        }

  @enforce_keys [:id, :domains, :upstream_port]
  defstruct [:id, :domains, :upstream_port]

  @doc """
  Creates a new route.

  ## Examples

      iex> Route.new("myapp", ["myapp.com", "www.myapp.com"], 3000)
      %Route{id: "myapp", domains: ["myapp.com", "www.myapp.com"], upstream_port: 3000}

  """
  @spec new(String.t(), String.t() | [String.t()], pos_integer()) :: t()
  def new(id, domains, upstream_port) when is_binary(domains) do
    new(id, [domains], upstream_port)
  end

  def new(id, domains, upstream_port) when is_list(domains) do
    %__MODULE__{
      id: id,
      domains: domains,
      upstream_port: upstream_port
    }
  end

  @doc """
  Converts the route to Caddy's JSON config format.

  Returns a map suitable for POSTing to Caddy's admin API.
  """
  @spec to_caddy_config(t()) :: map()
  def to_caddy_config(%__MODULE__{} = route) do
    %{
      "@id" => route.id,
      "match" => [
        %{"host" => route.domains}
      ],
      "handle" => [
        %{
          "handler" => "reverse_proxy",
          "upstreams" => [
            %{"dial" => "localhost:#{route.upstream_port}"}
          ]
        }
      ]
    }
  end

  @doc """
  Parses a route from Caddy's JSON config format.

  Returns `{:ok, route}` or `{:error, reason}`.
  """
  @spec from_caddy_config(map()) :: {:ok, t()} | {:error, String.t()}
  def from_caddy_config(config) do
    with {:ok, id} <- extract_id(config),
         {:ok, domains} <- extract_domains(config),
         {:ok, port} <- extract_upstream_port(config) do
      {:ok, new(id, domains, port)}
    end
  end

  defp extract_id(%{"@id" => id}) when is_binary(id), do: {:ok, id}
  defp extract_id(_), do: {:error, "missing or invalid @id"}

  defp extract_domains(%{"match" => [%{"host" => domains} | _]}) when is_list(domains) do
    {:ok, domains}
  end

  defp extract_domains(_), do: {:error, "missing or invalid match.host"}

  defp extract_upstream_port(%{"handle" => [%{"upstreams" => [%{"dial" => dial} | _]} | _]}) do
    case Regex.run(~r/:(\d+)$/, dial) do
      [_, port_str] -> {:ok, String.to_integer(port_str)}
      _ -> {:error, "could not parse port from dial: #{dial}"}
    end
  end

  defp extract_upstream_port(_), do: {:error, "missing or invalid handle.upstreams.dial"}
end
