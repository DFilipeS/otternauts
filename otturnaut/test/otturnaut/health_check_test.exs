defmodule Otturnaut.HealthCheckTest do
  use ExUnit.Case, async: true

  alias Otturnaut.HealthCheck

  # Mock runtime for testing :running check type
  defmodule MockRuntime do
    def status(name, _opts \\ [])
    def status("running-container", _opts), do: {:ok, :running}
    def status("stopped-container", _opts), do: {:ok, :stopped}
    def status("error-container", _opts), do: {:error, :not_found}
  end

  # Mock runtime for testing retry behavior - uses process dictionary for state
  defmodule RetryRuntime do
    def status(_name, _opts \\ []) do
      count = Agent.get_and_update(Process.get(:counter), &{&1 + 1, &1 + 1})

      if count >= 3 do
        {:ok, :running}
      else
        {:ok, :stopped}
      end
    end
  end

  describe "check/1 with :running type" do
    test "returns :healthy when container is running" do
      config = %{type: :running, runtime: MockRuntime, name: "running-container"}
      assert HealthCheck.check(config) == :healthy
    end

    test "returns :unhealthy when container is stopped" do
      config = %{type: :running, runtime: MockRuntime, name: "stopped-container"}
      assert HealthCheck.check(config) == :unhealthy
    end

    test "returns :unhealthy when status check errors" do
      config = %{type: :running, runtime: MockRuntime, name: "error-container"}
      assert HealthCheck.check(config) == :unhealthy
    end
  end

  describe "check/1 with :http type" do
    setup do
      # Start a simple HTTP server for testing
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(socket)

      # Spawn a process to handle connections
      pid =
        spawn_link(fn ->
          http_server_loop(socket)
        end)

      on_exit(fn ->
        Process.exit(pid, :kill)
        :gen_tcp.close(socket)
      end)

      {:ok, port: port}
    end

    test "returns :healthy when HTTP endpoint returns expected status", %{port: port} do
      config = %{
        type: :http,
        url: "http://localhost:#{port}/health",
        expected_status: 200,
        timeout: 1_000
      }

      assert HealthCheck.check(config) == :healthy
    end

    test "returns :unhealthy when HTTP endpoint returns unexpected status", %{port: port} do
      config = %{
        type: :http,
        url: "http://localhost:#{port}/error",
        expected_status: 200,
        timeout: 1_000
      }

      assert HealthCheck.check(config) == :unhealthy
    end

    test "returns :unhealthy when connection fails" do
      config = %{
        type: :http,
        url: "http://localhost:59999/health",
        expected_status: 200,
        timeout: 100
      }

      assert HealthCheck.check(config) == :unhealthy
    end

    test "uses default timeout when not specified", %{port: port} do
      config = %{
        type: :http,
        url: "http://localhost:#{port}/health",
        expected_status: 200
      }

      assert HealthCheck.check(config) == :healthy
    end

    defp http_server_loop(socket) do
      case :gen_tcp.accept(socket, 1000) do
        {:ok, client} ->
          # Read request
          {:ok, data} = :gen_tcp.recv(client, 0, 1000)

          # Determine response based on path
          response =
            if String.contains?(data, "GET /health") do
              "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
            else
              "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 5\r\n\r\nError"
            end

          :gen_tcp.send(client, response)
          :gen_tcp.close(client)
          http_server_loop(socket)

        {:error, :timeout} ->
          http_server_loop(socket)

        {:error, _} ->
          :ok
      end
    end
  end

  describe "check/1 with :tcp type" do
    setup do
      # Start a TCP server
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(socket)

      pid =
        spawn_link(fn ->
          tcp_server_loop(socket)
        end)

      on_exit(fn ->
        Process.exit(pid, :kill)
        :gen_tcp.close(socket)
      end)

      {:ok, port: port}
    end

    test "returns :healthy when TCP port accepts connections", %{port: port} do
      config = %{type: :tcp, host: "localhost", port: port, timeout: 1_000}
      assert HealthCheck.check(config) == :healthy
    end

    test "returns :unhealthy when TCP port refuses connections" do
      config = %{type: :tcp, host: "localhost", port: 59998, timeout: 100}
      assert HealthCheck.check(config) == :unhealthy
    end

    test "uses default timeout when not specified", %{port: port} do
      config = %{type: :tcp, host: "localhost", port: port}
      assert HealthCheck.check(config) == :healthy
    end

    defp tcp_server_loop(socket) do
      case :gen_tcp.accept(socket, 1000) do
        {:ok, client} ->
          :gen_tcp.close(client)
          tcp_server_loop(socket)

        {:error, :timeout} ->
          tcp_server_loop(socket)

        {:error, _} ->
          :ok
      end
    end
  end

  describe "check_with_retry/2" do
    test "returns :healthy on first success" do
      config = %{type: :running, runtime: MockRuntime, name: "running-container"}

      assert HealthCheck.check_with_retry(config, max_attempts: 3, interval: 10) == :healthy
    end

    test "returns :unhealthy after all attempts fail" do
      config = %{type: :running, runtime: MockRuntime, name: "stopped-container"}

      # Use small interval for faster test
      assert HealthCheck.check_with_retry(config, max_attempts: 2, interval: 10) == :unhealthy
    end

    test "uses default options" do
      config = %{type: :running, runtime: MockRuntime, name: "running-container"}
      assert HealthCheck.check_with_retry(config) == :healthy
    end

    test "retries until success" do
      # Use a counter to track attempts
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      Process.put(:counter, counter)
      config = %{type: :running, runtime: RetryRuntime, name: "test"}

      result = HealthCheck.check_with_retry(config, max_attempts: 5, interval: 10)
      assert result == :healthy

      final_count = Agent.get(counter, & &1)
      assert final_count == 3

      Agent.stop(counter)
    end
  end
end
