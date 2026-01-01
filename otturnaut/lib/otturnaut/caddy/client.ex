defmodule Otturnaut.Caddy.Client do
  @moduledoc """
  HTTP client for Caddy's admin API.

  This module handles the low-level HTTP communication with Caddy.
  It's typically not called directly — use `Otturnaut.Caddy` instead.

  ## Testing

  Pass `plug: {Req.Test, stub_name}` in opts to use Req.Test stubs:

      Req.Test.stub(MyStub, fn conn ->
        Req.Test.json(conn, %{"apps" => %{}})
      end)

      Client.get_config("/apps", plug: {Req.Test, MyStub})
  """

  @default_base_url "http://localhost:2019"

  @type error ::
          {:error,
           :caddy_unavailable
           | :timeout
           | :request_failed
           | {:unexpected_status, integer(), any()}}

  @doc """
  Gets the current config at the given path.
  """
  @spec get_config(String.t(), keyword()) :: {:ok, any()} | error()
  def get_config(path, opts \\ []) do
    url = build_url("/config#{path}", opts)

    url
    |> Req.get(req_opts(opts))
    |> handle_response(:get)
  end

  @doc """
  Sets the config at the given path.

  Uses POST to set/replace the config at that path.
  """
  @spec set_config(String.t(), any(), keyword()) :: :ok | error()
  def set_config(path, config, opts \\ []) do
    url = build_url("/config#{path}", opts)

    url
    |> Req.post(Keyword.put(req_opts(opts), :json, config))
    |> handle_response(:post)
  end

  @doc """
  Appends an item to an array at the given config path.

  Uses POST with `...` suffix to append to an array.
  """
  @spec append_config(String.t(), any(), keyword()) :: :ok | error()
  def append_config(path, config, opts \\ []) do
    url = build_url("/config#{path}/...", opts)

    url
    |> Req.post(Keyword.put(req_opts(opts), :json, config))
    |> handle_response(:post)
  end

  @doc """
  Deletes the config at the given path.
  """
  @spec delete_config(String.t(), keyword()) :: :ok | error()
  def delete_config(path, opts \\ []) do
    url = build_url("/config#{path}", opts)

    url
    |> Req.delete(req_opts(opts))
    |> handle_response(:delete)
  end

  @doc """
  Gets an object by its @id field.

  Uses the /id/ endpoint which is at the API root (not under /config/).
  """
  @spec get_by_id(String.t(), keyword()) :: {:ok, any()} | error()
  def get_by_id(id, opts \\ []) do
    url = build_id_url(id, opts)

    url
    |> Req.get(req_opts(opts))
    |> handle_response(:get)
  end

  @doc """
  Deletes an object by its @id field.

  Uses the /id/ endpoint which is at the API root (not under /config/).
  """
  @spec delete_by_id(String.t(), keyword()) :: :ok | error()
  def delete_by_id(id, opts \\ []) do
    url = build_id_url(id, opts)

    url
    |> Req.delete(req_opts(opts))
    |> handle_response(:delete)
  end

  @doc """
  Checks if Caddy's admin API is reachable.
  """
  @spec health_check(keyword()) :: :ok | error()
  def health_check(opts \\ []) do
    case get_config("", opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Build common Req options, forwarding :plug if provided for testing
  defp req_opts(opts) do
    base = [receive_timeout: 5_000, retry: false]

    case Keyword.get(opts, :plug) do
      nil -> base
      plug -> Keyword.put(base, :plug, plug)
    end
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, :get) do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: 200}}, _method) do
    :ok
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _method) do
    {:error, {:unexpected_status, status, body}}
  end

  defp handle_response({:error, %Req.TransportError{reason: :econnrefused}}, _method) do
    {:error, :caddy_unavailable}
  end

  defp handle_response({:error, %Req.TransportError{reason: :timeout}}, _method) do
    {:error, :timeout}
  end

  defp handle_response({:error, _reason}, _method) do
    {:error, :request_failed}
  end

  defp build_url(path, opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    # Ensure trailing slash - Caddy redirects without it and POST body may be lost
    full_path = if String.ends_with?(path, "/"), do: path, else: path <> "/"
    base_url <> full_path
  end

  defp build_id_url(id, opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    "#{base_url}/id/#{id}"
  end
end
