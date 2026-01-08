defmodule Otturnaut.Deployment.Steps.StartContainerTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Steps.StartContainer

  defmodule MockRuntime do
    def start(opts) do
      container_id = "container-#{opts.name}"
      Process.put({:container, opts.name}, container_id)
      {:ok, container_id}
    end

    def stop(name, _opts) do
      Process.put({:stopped, name}, true)
      :ok
    end

    def remove(name, _opts) do
      Process.delete({:container, name})
      Process.put({:removed, name}, true)
      :ok
    end
  end

  defmodule FailingRuntime do
    def start(_opts), do: {:error, {:exit, 1}}
  end

  describe "run/3" do
    test "starts container successfully" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          runtime: MockRuntime,
          runtime_opts: []
        })

      arguments = %{deployment: deployment, port: 10000}

      assert {:ok, result} = StartContainer.run(arguments, %{}, [])

      assert result.container_name == "otturnaut-myapp-deploy-1"
      assert result.container_id == "container-otturnaut-myapp-deploy-1"
    end

    test "returns error when container start fails" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          runtime: FailingRuntime,
          runtime_opts: []
        })

      arguments = %{deployment: deployment, port: 10000}

      assert {:error, {:container_start_failed, {:exit, 1}}} =
               StartContainer.run(arguments, %{}, [])
    end
  end

  describe "undo/4" do
    test "stops and removes the container" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          runtime: MockRuntime,
          runtime_opts: []
        })

      result = %{container_name: "otturnaut-myapp-deploy-1", container_id: "container-123"}
      arguments = %{deployment: deployment}

      assert :ok = StartContainer.undo(result, arguments, %{}, [])

      assert Process.get({:stopped, "otturnaut-myapp-deploy-1"})
      assert Process.get({:removed, "otturnaut-myapp-deploy-1"})
    end
  end
end
