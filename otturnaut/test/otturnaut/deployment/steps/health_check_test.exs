defmodule Otturnaut.Deployment.Steps.HealthCheckTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Steps.HealthCheck

  defmodule HealthyRuntime do
    def status(_name, _opts), do: {:ok, :running}
  end

  defmodule UnhealthyRuntime do
    def status(_name, _opts), do: {:ok, :stopped}
  end

  describe "run/3" do
    test "returns healthy when container is running" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          runtime: HealthyRuntime,
          runtime_opts: []
        })

      container = %{container_name: "otturnaut-myapp-deploy-1"}
      opts = [health_check: [max_attempts: 1, interval: 10]]
      arguments = %{deployment: deployment, container: container, opts: opts}

      assert {:ok, :healthy} = HealthCheck.run(arguments, %{}, [])
    end

    test "returns error when container is unhealthy" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          runtime: UnhealthyRuntime,
          runtime_opts: []
        })

      container = %{container_name: "otturnaut-myapp-deploy-1"}
      opts = [health_check: [max_attempts: 2, interval: 10]]
      arguments = %{deployment: deployment, container: container, opts: opts}

      assert {:error, :health_check_failed} = HealthCheck.run(arguments, %{}, [])
    end

    test "uses default health check options when not provided" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          runtime: HealthyRuntime,
          runtime_opts: []
        })

      container = %{container_name: "otturnaut-myapp-deploy-1"}
      arguments = %{deployment: deployment, container: container, opts: []}

      assert {:ok, :healthy} = HealthCheck.run(arguments, %{}, [])
    end
  end
end
