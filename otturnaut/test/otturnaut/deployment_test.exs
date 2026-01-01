defmodule Otturnaut.DeploymentTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment

  # Strategy mocks for execute/rollback tests
  defmodule SuccessStrategy do
    def execute(deployment, _context, _opts) do
      {:ok, %{deployment | port: 10042, container_id: "abc123"}}
    end
  end

  defmodule FailureStrategy do
    def execute(deployment, _context, _opts) do
      {:error, :health_check_failed, deployment}
    end
  end

  defmodule OptsStrategy do
    def execute(_deployment, _context, opts) do
      send(self(), {:opts_received, opts})
      {:ok, %Otturnaut.Deployment{id: "x", app_id: "x", image: "x", container_port: 1}}
    end
  end

  defmodule RollbackStrategy do
    def rollback(deployment, context, opts) do
      send(self(), {:rollback_called, deployment, context, opts})
      :ok
    end
  end

  defmodule RollbackFailStrategy do
    def rollback(_deployment, _context, _opts) do
      {:error, :rollback_failed}
    end
  end

  describe "new/1" do
    test "creates a deployment with required fields" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      assert deployment.app_id == "myapp"
      assert deployment.image == "myapp:latest"
      assert deployment.container_port == 3000
      assert deployment.status == :pending
      assert deployment.env == %{}
      assert deployment.domains == []
      assert is_binary(deployment.id)
    end

    test "creates a deployment with optional fields" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          env: %{"DATABASE_URL" => "postgres://localhost/myapp"},
          domains: ["myapp.com", "www.myapp.com"]
        })

      assert deployment.env == %{"DATABASE_URL" => "postgres://localhost/myapp"}
      assert deployment.domains == ["myapp.com", "www.myapp.com"]
    end

    test "uses provided id if given" do
      deployment =
        Deployment.new(%{
          id: "custom-id",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      assert deployment.id == "custom-id"
    end

    test "generates unique ids" do
      deployment1 =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      deployment2 =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      assert deployment1.id != deployment2.id
    end
  end

  describe "container_name/1" do
    test "generates container name from app_id and deployment id" do
      deployment =
        Deployment.new(%{
          id: "abc123",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      assert Deployment.container_name(deployment) == "otturnaut-myapp-abc123"
    end
  end

  describe "mark_completed/1" do
    test "sets status to completed and timestamps" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      completed = Deployment.mark_completed(deployment)

      assert completed.status == :completed
      assert %DateTime{} = completed.completed_at
    end
  end

  describe "mark_failed/2" do
    test "sets status to failed with error" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      failed = Deployment.mark_failed(deployment, :health_check_failed)

      assert failed.status == :failed
      assert failed.error == :health_check_failed
      assert %DateTime{} = failed.completed_at
    end
  end

  describe "mark_rolled_back/1" do
    test "sets status to rolled_back" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      rolled_back = Deployment.mark_rolled_back(deployment)

      assert rolled_back.status == :rolled_back
      assert %DateTime{} = rolled_back.completed_at
    end
  end

  describe "execute/4" do
    test "calls strategy.execute with deployment and context" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      context = %{runtime: FakeRuntime}

      {:ok, result} = Deployment.execute(deployment, SuccessStrategy, context)

      assert result.port == 10042
      assert result.container_id == "abc123"
    end

    test "sets status to in_progress and started_at before calling strategy" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      {:ok, result} = Deployment.execute(deployment, SuccessStrategy, %{})

      # The strategy receives the updated deployment
      assert result.status == :in_progress
      assert %DateTime{} = result.started_at
    end

    test "returns error tuple from strategy" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      {:error, reason, result} = Deployment.execute(deployment, FailureStrategy, %{})

      assert reason == :health_check_failed
      assert result.status == :in_progress
    end

    test "passes opts to strategy" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      Deployment.execute(deployment, OptsStrategy, %{}, timeout: 5000)

      assert_receive {:opts_received, [timeout: 5000]}
    end
  end

  describe "rollback/4" do
    test "calls strategy.rollback" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      context = %{runtime: FakeRuntime}

      assert :ok = Deployment.rollback(deployment, RollbackStrategy, context)

      assert_receive {:rollback_called, ^deployment, ^context, []}
    end

    test "passes opts to strategy.rollback" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      Deployment.rollback(deployment, RollbackStrategy, %{}, force: true)

      assert_receive {:rollback_called, _, _, [force: true]}
    end

    test "returns error from strategy" do
      deployment =
        Deployment.new(%{
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000
        })

      assert {:error, :rollback_failed} =
               Deployment.rollback(deployment, RollbackFailStrategy, %{})
    end
  end
end
