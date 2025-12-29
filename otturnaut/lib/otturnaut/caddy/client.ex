defmodule Otturnaut.Caddy.Client do
  @moduledoc """
  HTTP client for Caddy's admin API.

  This module handles the low-level HTTP communication with Caddy.
  It's typically not called directly — use `Otturnaut.Caddy` instead.
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

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :caddy_unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  @doc """
  Sets the config at the given path.

  Uses POST to set/replace the config at that path.
  """
  @spec set_config(String.t(), any(), keyword()) :: :ok | error()
  def set_config(path, config, opts \\ []) do
    url = build_url("/config#{path}", opts)

    case Req.post(url, json: config, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :caddy_unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  @doc """
  Appends an item to an array at the given config path.

  Uses POST with `...` suffix to append to an array.
  """
  @spec append_config(String.t(), any(), keyword()) :: :ok | error()
  def append_config(path, config, opts \\ []) do
    url = build_url("/config#{path}/...", opts)

    case Req.post(url, json: config, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :caddy_unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  @doc """
  Deletes the config at the given path.
  """
  @spec delete_config(String.t(), keyword()) :: :ok | error()
  def delete_config(path, opts \\ []) do
    url = build_url("/config#{path}", opts)

    case Req.delete(url, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :caddy_unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  @doc """
  Gets an object by its @id field.

  Uses the /id/ endpoint which is at the API root (not under /config/).
  """
  @spec get_by_id(String.t(), keyword()) :: {:ok, any()} | error()
  def get_by_id(id, opts \\ []) do
    url = build_id_url(id, opts)

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :caddy_unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  @doc """
  Deletes an object by its @id field.

  Uses the /id/ endpoint which is at the API root (not under /config/).
  """
  @spec delete_by_id(String.t(), keyword()) :: :ok | error()
  def delete_by_id(id, opts \\ []) do
    url = build_id_url(id, opts)

    case Req.delete(url, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :caddy_unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :request_failed}
    end
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
