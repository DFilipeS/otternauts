defmodule Otturnaut.AppStateTest do
  @moduledoc """
  Tests for Otturnaut.AppState using isolated, uniquely-named server instances.

  These tests run async (concurrently) because each test starts its own server
  with a unique name, avoiding shared state conflicts.

  Default argument coverage tests (e.g., `AppState.get/1` without the server param)
  are in `app_state_default_args_test.exs` - those must run synchronously because
  they use the global `Otturnaut.AppState` server to exercise the default arg paths.
  """
  use ExUnit.Case, async: true

  alias Otturnaut.AppState

  # Mock runtimes for recovery tests
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

  defmodule MockRuntimeNoPort do
    def list_apps do
      {:ok,
       [
         %{
           id: "noport",
           container_name: "otturnaut-noport-xyz789",
           port: nil,
           status: :running
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

  defmodule FailingRuntime do
    def list_apps do
      {:error, :docker_unavailable}
    end
  end

  setup do
    # Start a uniquely named instance for this test
    server_name = :"app_state_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = AppState.start_link(name: server_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, server: server_name}
  end

  describe "put/2 and get/1" do
    test "stores and retrieves app state", %{server: server} do
      app = %{
        deployment_id: "abc123",
        container_name: "otturnaut-myapp-abc123",
        port: 10042,
        domains: ["myapp.com"],
        status: :running
      }

      assert :ok = AppState.put("myapp", app, server)
      assert {:ok, ^app} = AppState.get("myapp", server)
    end

    test "returns error for non-existent app", %{server: server} do
      assert {:error, :not_found} = AppState.get("nonexistent", server)
    end

    test "overwrites existing app state", %{server: server} do
      app1 = %{
        deployment_id: "abc123",
        container_name: "otturnaut-myapp-abc123",
        port: 10042,
        domains: [],
        status: :running
      }

      app2 = %{
        deployment_id: "def456",
        container_name: "otturnaut-myapp-def456",
        port: 10043,
        domains: ["myapp.com"],
        status: :deploying
      }

      AppState.put("myapp", app1, server)
      AppState.put("myapp", app2, server)

      assert {:ok, ^app2} = AppState.get("myapp", server)
    end
  end

  describe "delete/1" do
    test "removes app state", %{server: server} do
      app = %{
        deployment_id: "abc123",
        container_name: "otturnaut-myapp-abc123",
        port: 10042,
        domains: [],
        status: :running
      }

      AppState.put("myapp", app, server)
      assert :ok = AppState.delete("myapp", server)
      assert {:error, :not_found} = AppState.get("myapp", server)
    end

    test "succeeds even if app doesn't exist", %{server: server} do
      assert :ok = AppState.delete("nonexistent", server)
    end
  end

  describe "list/0" do
    test "returns empty list when no apps", %{server: server} do
      assert AppState.list(server) == []
    end

    test "returns all apps", %{server: server} do
      app1 = %{
        deployment_id: "abc",
        container_name: "otturnaut-app1-abc",
        port: 10042,
        domains: [],
        status: :running
      }

      app2 = %{
        deployment_id: "def",
        container_name: "otturnaut-app2-def",
        port: 10043,
        domains: [],
        status: :running
      }

      AppState.put("app1", app1, server)
      AppState.put("app2", app2, server)

      apps = AppState.list(server)
      assert length(apps) == 2
      assert {"app1", app1} in apps
      assert {"app2", app2} in apps
    end
  end

  describe "update/3" do
    test "updates a specific field", %{server: server} do
      app = %{
        deployment_id: "abc123",
        container_name: "otturnaut-myapp-abc123",
        port: 10042,
        domains: [],
        status: :running
      }

      AppState.put("myapp", app, server)
      assert :ok = AppState.update("myapp", :status, :stopped, server)

      {:ok, updated} = AppState.get("myapp", server)
      assert updated.status == :stopped
      assert updated.port == 10042
    end

    test "returns error for non-existent app", %{server: server} do
      assert {:error, :not_found} = AppState.update("nonexistent", :status, :stopped, server)
    end
  end

  describe "update_status/2" do
    test "updates app status", %{server: server} do
      app = %{
        deployment_id: "abc123",
        container_name: "otturnaut-myapp-abc123",
        port: 10042,
        domains: [],
        status: :deploying
      }

      AppState.put("myapp", app, server)
      assert :ok = AppState.update_status("myapp", :running, server)

      {:ok, updated} = AppState.get("myapp", server)
      assert updated.status == :running
    end
  end

  describe "clear/0" do
    test "removes all apps", %{server: server} do
      app1 = %{
        deployment_id: "abc",
        container_name: "otturnaut-app1-abc",
        port: 10042,
        domains: [],
        status: :running
      }

      app2 = %{
        deployment_id: "def",
        container_name: "otturnaut-app2-def",
        port: 10043,
        domains: [],
        status: :running
      }

      AppState.put("app1", app1, server)
      AppState.put("app2", app2, server)

      assert :ok = AppState.clear(server)
      assert AppState.list(server) == []
    end
  end

  # Note: recover_from_runtime tests that need the global PortManager are in
  # app_state_default_args_test.exs (sync file) to avoid race conditions

  describe "recover_from_runtime/1 (no port)" do
    test "returns error when runtime fails", %{server: server} do
      assert {:error, :docker_unavailable} = AppState.recover_from_runtime(FailingRuntime, server)
    end

    test "handles apps without port mapping", %{server: server} do
      assert :ok = AppState.recover_from_runtime(MockRuntimeNoPort, server)

      {:ok, app} = AppState.get("noport", server)
      assert app.port == nil
      assert app.deployment_id == "xyz789"
    end
  end
end
