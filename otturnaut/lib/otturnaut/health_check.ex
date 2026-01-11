defmodule Otturnaut.HealthCheck do
  @moduledoc """
  Health checking for deployed applications.

  Supports multiple check types, starting simple and extensible for future needs:

  - `:running` - Check if container/process is running (Phase 1)
  - `:http` - HTTP endpoint responds with expected status (future)
  - `:tcp` - TCP port accepts connections (future, for databases)

  ## Example

      # Check if container is running
      config = %{type: :running, runtime: Otturnaut.Runtime.Docker, name: "myapp-abc123"}
      case HealthCheck.check(config) do
        :healthy -> # proceed
        :unhealthy -> # handle failure
      end

      # With custom runtime options (e.g., Podman)
      config = %{
        type: :running,
        runtime: Otturnaut.Runtime.Docker,
        runtime_opts: [binary: "podman"],
        name: "myapp-abc123"
      }

      # Future: HTTP health check
      config = %{type: :http, url: "http://localhost:3000/health", expected_status: 200}
      HealthCheck.check(config)

  """

  @type check_config ::
          %{
            optional(:runtime_opts) => keyword(),
            type: :running,
            runtime: module(),
            name: String.t()
          }
          | %{
              type: :http,
              url: String.t(),
              expected_status: pos_integer(),
              timeout: pos_integer()
            }
          | %{type: :tcp, host: String.t(), port: pos_integer(), timeout: pos_integer()}

  @type result :: :healthy | :unhealthy

  @doc """
  Performs a health check based on the configuration.

  Returns `:healthy` or `:unhealthy`.
  """
  @spec check(check_config()) :: result()
  def check(%{type: :running, runtime: runtime, name: name} = config) do
    runtime_opts = Map.get(config, :runtime_opts, [])

    case runtime.status(name, runtime_opts) do
      {:ok, :running} -> :healthy
      _ -> :unhealthy
    end
  end

  def check(%{type: :http, url: url, expected_status: expected} = config) do
    timeout = Map.get(config, :timeout, 5_000)

    case http_get(url, timeout) do
      {:ok, ^expected} -> :healthy
      _ -> :unhealthy
    end
  end

  def check(%{type: :tcp, host: host, port: port} = config) do
    timeout = Map.get(config, :timeout, 5_000)

    case tcp_connect(host, port, timeout) do
      :ok -> :healthy
      _ -> :unhealthy
    end
  end

  @doc """
  Performs a health check with retries.

  Retries the check up to `max_attempts` times with `interval` milliseconds between attempts.
  Returns `:healthy` on first success or `:unhealthy` after all attempts fail.
  """
  @spec check_with_retry(check_config(), keyword()) :: result()
  def check_with_retry(config, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 5)
    interval = Keyword.get(opts, :interval, 1_000)

    do_check_with_retry(config, max_attempts, interval)
  end

  defp do_check_with_retry(_config, 0, _interval), do: :unhealthy

  defp do_check_with_retry(config, attempts_left, interval) do
    case check(config) do
      :healthy ->
        :healthy

      :unhealthy ->
        Process.sleep(interval)
        do_check_with_retry(config, attempts_left - 1, interval)
    end
  end

  # HTTP check implementation
  defp http_get(url, timeout) do
    # Use Req for HTTP requests
    case Req.get(url, receive_timeout: timeout, retry: false) do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, _} -> :error
    end
  end

  # TCP check implementation
  defp tcp_connect(host, port, timeout) do
    host_charlist = String.to_charlist(host)

    case :gen_tcp.connect(host_charlist, port, [], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        :error
    end
  end
end
