defmodule Otturnaut.AppStateDefaultArgsTest do
  @moduledoc """
  Tests for default argument coverage of AppState functions.
  These tests use the globally named server and must run synchronously.
  """
  use ExUnit.Case, async: false

  alias Otturnaut.AppState

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
  end
end
