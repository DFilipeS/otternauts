defmodule Otturnaut.AppStateDefaultArgsTest do
  @moduledoc """
  Tests for default argument coverage of AppState functions.
  These tests use the globally named server and must run synchronously.
  """
  use ExUnit.Case, async: false

  alias Otturnaut.AppState
  alias Otturnaut.PortManager

  setup do
    # Ensure the default named server is running
    case Process.whereis(AppState) do
      nil ->
        case AppState.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      pid ->
        # Clear any existing state
        try do
          AppState.clear(pid)
        catch
          :exit, _ -> :ok
        end
    end

    on_exit(fn ->
      # Safely clear state if server still exists
      if pid = Process.whereis(AppState) do
        try do
          AppState.clear(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe "default argument coverage" do
    test "start_link without opts" do
      # Stop existing default server
      if pid = Process.whereis(AppState) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      # Start without opts - exercises the default argument path
      case AppState.start_link() do
        {:ok, pid} ->
          assert is_pid(pid)
          assert Process.whereis(AppState) == pid

        {:error, {:already_started, pid}} ->
          # Server was started by another concurrent process
          assert is_pid(pid)
      end
    end

    test "put/2 and get/1 with default server" do
      app = %{
        deployment_id: "default-test",
        container_name: "otturnaut-default-test",
        port: 10000,
        domains: [],
        status: :running
      }

      # Call without server argument to exercise default path
      assert :ok = AppState.put("default-app", app)
      assert {:ok, ^app} = AppState.get("default-app")
    end

    test "delete/1 with default server" do
      app = %{deployment_id: "d", container_name: "c", port: 1, domains: [], status: :running}
      AppState.put("del-app", app)
      assert :ok = AppState.delete("del-app")
      assert {:error, :not_found} = AppState.get("del-app")
    end

    test "list/0 with default server" do
      # list/0 exercises the default argument path
      assert is_list(AppState.list())
    end

    test "update/3 with default server" do
      app = %{deployment_id: "u", container_name: "c", port: 1, domains: [], status: :running}
      AppState.put("update-app", app)
      assert :ok = AppState.update("update-app", :status, :stopped)
    end

    test "update_status/2 with default server" do
      app = %{deployment_id: "s", container_name: "c", port: 1, domains: [], status: :running}
      AppState.put("status-app", app)
      assert :ok = AppState.update_status("status-app", :deploying)
    end

    test "clear/0 with default server" do
      app = %{deployment_id: "c", container_name: "c", port: 1, domains: [], status: :running}
      AppState.put("clear-app", app)
      assert :ok = AppState.clear()
      assert AppState.list() == []
    end

    test "recover_from_runtime/1 with default server" do
      # Ensure PortManager is running for recovery
      ensure_global_port_manager()

      assert :ok = AppState.recover_from_runtime(__MODULE__.DefaultRuntimeMock)
      assert {:ok, _} = AppState.get("recover-app")
    end
  end

  # Mock runtimes for testing - defined at module level to avoid redefinition warnings
  defmodule DefaultRuntimeMock do
    def list_apps do
      {:ok, [%{id: "recover-app", container_name: "otturnaut-recover-app-123", port: nil, status: :running}]}
    end
  end

  defmodule MockRuntime do
    def list_apps do
      {:ok,
       [
         %{
           id: "myapp",
           container_name: "otturnaut-myapp-abc123",
           port: 10042,
           status: :running
         },
         %{
           id: "otherapp",
           container_name: "otturnaut-otherapp-def456",
           port: 10043,
           status: :stopped
         }
       ]}
    end
  end

  defmodule MockRuntimeWeirdName do
    def list_apps do
      {:ok,
       [
         %{
           id: "weird",
           container_name: "some-other-format",
           port: 10044,
           status: :running
         }
       ]}
    end
  end

  describe "recover_from_runtime with ports (needs global PortManager)" do
    # These tests are here (sync) because they need the global PortManager

    setup do
      ensure_global_port_manager({10000, 11000})
      :ok
    end

    test "populates state from runtime" do
      # Ensure AppState is running
      case Process.whereis(AppState) do
        nil -> {:ok, _} = AppState.start_link()
        _ -> :ok
      end
      AppState.clear()

      assert :ok = AppState.recover_from_runtime(MockRuntime)

      # Only running apps are recovered
      {:ok, app} = AppState.get("myapp")
      assert app.deployment_id == "abc123"
      assert app.port == 10042
      assert app.status == :running

      # Stopped apps are not recovered
      assert {:error, :not_found} = AppState.get("otherapp")
    end

    test "handles apps with non-standard container names" do
      # Ensure AppState is running
      case Process.whereis(AppState) do
        nil -> {:ok, _} = AppState.start_link()
        _ -> :ok
      end
      AppState.clear()

      assert :ok = AppState.recover_from_runtime(MockRuntimeWeirdName)

      {:ok, app} = AppState.get("weird")
      assert app.deployment_id == "unknown"
      assert app.port == 10044
    end
  end

  # Helper to ensure the global PortManager is running
  defp ensure_global_port_manager(port_range \\ {10_000, 20_000}) do
    case Process.whereis(PortManager) do
      nil ->
        case PortManager.start_link(port_range: port_range) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      pid ->
        # Stop and restart with the required range
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

        case PortManager.start_link(port_range: port_range) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
    end
  end
end
