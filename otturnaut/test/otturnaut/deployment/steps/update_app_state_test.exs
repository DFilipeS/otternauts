defmodule Otturnaut.Deployment.Steps.UpdateAppStateTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Steps.UpdateAppState

  defmodule MockAppState do
    def put(app_id, app) do
      Process.put({:app, app_id}, app)
      :ok
    end

    def delete(app_id) do
      Process.delete({:app, app_id})
      :ok
    end
  end

  describe "run/3" do
    test "saves new app state" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: ["myapp.com"]
        })

      container = %{container_name: "otturnaut-myapp-deploy-1", container_id: "container-123"}
      previous_state = %{previous_container_name: nil, previous_port: nil}

      arguments = %{
        deployment: deployment,
        port: 10000,
        container: container,
        previous_state: previous_state,
        app_state: MockAppState
      }

      assert {:ok, result} = UpdateAppState.run(arguments, %{}, [])

      assert result.app_id == "myapp"
      assert result.port == 10000
      assert result.container_name == "otturnaut-myapp-deploy-1"
      assert result.container_id == "container-123"
      assert result.previous_container_name == nil
      assert result.previous_port == nil

      app = Process.get({:app, "myapp"})
      assert app.port == 10000
      assert app.container_name == "otturnaut-myapp-deploy-1"
      assert app.status == :running
    end
  end

  describe "undo/4" do
    test "deletes app state when it was a fresh deployment" do
      Process.put({:app, "myapp"}, %{status: :running})

      result = %{
        app_id: "myapp",
        port: 10000,
        container_name: "otturnaut-myapp-deploy-1",
        container_id: "container-123",
        previous_container_name: nil,
        previous_port: nil
      }

      arguments = %{app_state: MockAppState}

      assert :ok = UpdateAppState.undo(result, arguments, %{}, [])

      refute Process.get({:app, "myapp"})
    end

    test "restores previous state when there was a previous deployment" do
      result = %{
        app_id: "myapp",
        port: 10000,
        container_name: "otturnaut-myapp-deploy-1",
        container_id: "container-123",
        previous_container_name: "otturnaut-myapp-old",
        previous_port: 9999
      }

      arguments = %{app_state: MockAppState}

      assert :ok = UpdateAppState.undo(result, arguments, %{}, [])

      app = Process.get({:app, "myapp"})
      assert app.container_name == "otturnaut-myapp-old"
      assert app.port == 9999
    end

    test "handles non-standard container name format in undo" do
      result = %{
        app_id: "myapp",
        port: 10000,
        container_name: "otturnaut-myapp-deploy-1",
        container_id: "container-123",
        previous_container_name: "custom-container",
        previous_port: 9999
      }

      arguments = %{app_state: MockAppState}

      assert :ok = UpdateAppState.undo(result, arguments, %{}, [])

      app = Process.get({:app, "myapp"})
      assert app.deployment_id == "unknown"
    end
  end
end
