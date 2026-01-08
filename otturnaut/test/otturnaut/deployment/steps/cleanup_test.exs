defmodule Otturnaut.Deployment.Steps.CleanupTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Steps.Cleanup

  defmodule MockRuntime do
    def stop(name, _opts) do
      Process.put({:stopped, name}, true)
      :ok
    end

    def remove(name, _opts) do
      Process.put({:removed, name}, true)
      :ok
    end
  end

  defmodule MockPortManager do
    def release(port) do
      Process.put({:released, port}, true)
      :ok
    end
  end

  describe "run/3" do
    test "cleans up old container and port" do
      deployment =
        Deployment.new(%{
          id: "deploy-2",
          app_id: "myapp",
          image: "myapp:v2",
          container_port: 3000,
          runtime: MockRuntime,
          runtime_opts: []
        })

      previous_state = %{
        previous_container_name: "otturnaut-myapp-old",
        previous_port: 9999
      }

      arguments = %{
        deployment: deployment,
        previous_state: previous_state,
        port_manager: MockPortManager
      }

      assert {:ok, :cleaned_up} = Cleanup.run(arguments, %{}, [])

      assert Process.get({:stopped, "otturnaut-myapp-old"})
      assert Process.get({:removed, "otturnaut-myapp-old"})
      assert Process.get({:released, 9999})
    end

    test "handles nil previous state gracefully" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          runtime: MockRuntime,
          runtime_opts: []
        })

      previous_state = %{
        previous_container_name: nil,
        previous_port: nil
      }

      arguments = %{
        deployment: deployment,
        previous_state: previous_state,
        port_manager: MockPortManager
      }

      assert {:ok, :cleaned_up} = Cleanup.run(arguments, %{}, [])
    end
  end
end
