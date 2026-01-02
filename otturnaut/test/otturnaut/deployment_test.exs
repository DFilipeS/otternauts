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

  describe "undeploy/3" do
    # Mock modules that use process dictionary for state (async-safe)
    # Defined at describe level to avoid recompilation warnings
    defmodule TestMockRuntime do
      def status(name, _opts \\ []) do
        state = Process.get(:test_mock_state, %{})
        status = get_in(state, [:statuses, name]) || :not_found
        {:ok, status}
      end

      def stop(name, _opts \\ []) do
        state = Process.get(:test_mock_state, %{})
        new_state = put_in(state, [:statuses, name], :stopped)
        Process.put(:test_mock_state, new_state)
        :ok
      end

      def remove(name, _opts \\ []) do
        state = Process.get(:test_mock_state, %{})

        new_state =
          state
          |> Map.update(:containers, %{}, &Map.delete(&1, name))
          |> put_in([:statuses, name], :not_found)

        Process.put(:test_mock_state, new_state)
        :ok
      end
    end

    defmodule TestMockAppState do
      def get(app_id) do
        state = Process.get(:test_mock_state, %{})

        case get_in(state, [:apps, app_id]) do
          nil -> {:error, :not_found}
          app -> {:ok, app}
        end
      end

      def put(app_id, app) do
        state = Process.get(:test_mock_state, %{})
        new_state = put_in(state, [:apps, app_id], app)
        Process.put(:test_mock_state, new_state)
        :ok
      end

      def delete(app_id) do
        state = Process.get(:test_mock_state, %{})
        new_state = Map.update(state, :apps, %{}, &Map.delete(&1, app_id))
        Process.put(:test_mock_state, new_state)
        :ok
      end
    end

    defmodule TestMockPortManager do
      def release(port) do
        state = Process.get(:test_mock_state, %{})
        released = Map.get(state, :released_ports, [])
        new_state = Map.put(state, :released_ports, [port | released])
        Process.put(:test_mock_state, new_state)
        :ok
      end
    end

    defmodule TestMockCaddy do
      def remove_route(route_id, _opts \\ []) do
        state = Process.get(:test_mock_state, %{})
        removed = Map.get(state, :removed_routes, [])
        new_state = Map.put(state, :removed_routes, [route_id | removed])
        Process.put(:test_mock_state, new_state)
        :ok
      end
    end

    # Failure scenario mocks
    defmodule UndeployOptsTrackingCaddy do
      def remove_route(_route_id, opts) do
        Process.put(:tracked_opts, opts)
        # Also record the route removal
        state = Process.get(:test_mock_state, %{})
        removed = Map.get(state, :removed_routes, [])
        new_state = Map.put(state, :removed_routes, ["myapp-route" | removed])
        Process.put(:test_mock_state, new_state)
        :ok
      end
    end

    defmodule UndeployFailingStopRuntime do
      def status(_name, _opts \\ []), do: {:ok, :running}
      def stop(_name, _opts \\ []), do: {:error, :stop_failed}
      def remove(_name, _opts \\ []), do: :ok
    end

    defmodule UndeployFailingStatusRuntime do
      def status(_name, _opts \\ []), do: {:error, :status_check_failed}
      def stop(_name, _opts \\ []), do: :ok
      def remove(_name, _opts \\ []), do: :ok
    end

    defmodule UndeployFailingRemoveRuntime do
      def status(_name, _opts \\ []), do: {:ok, :running}
      def stop(_name, _opts \\ []), do: :ok
      def remove(_name, _opts \\ []), do: {:error, :remove_failed}
    end

    defmodule UndeployFailingCaddy do
      def remove_route(_route_id, _opts), do: {:error, :caddy_unavailable}
    end

    setup do
      # Initialize state in process dictionary
      Process.put(:test_mock_state, %{
        apps: %{},
        statuses: %{},
        containers: %{},
        released_ports: [],
        removed_routes: []
      })

      context = %{
        runtime: TestMockRuntime,
        app_state: TestMockAppState,
        port_manager: TestMockPortManager,
        caddy: TestMockCaddy
      }

      {:ok, context: context}
    end

    # Helper functions
    defp add_container(name) do
      state = Process.get(:test_mock_state, %{})

      new_state =
        state
        |> put_in([:containers, name], true)
        |> put_in([:statuses, name], :running)

      Process.put(:test_mock_state, new_state)
    end

    defp set_container_status(name, status) do
      state = Process.get(:test_mock_state, %{})
      new_state = put_in(state, [:statuses, name], status)
      Process.put(:test_mock_state, new_state)
    end

    defp get_released_ports do
      state = Process.get(:test_mock_state, %{})
      Map.get(state, :released_ports, [])
    end

    defp get_removed_routes do
      state = Process.get(:test_mock_state, %{})
      Map.get(state, :removed_routes, [])
    end

    test "successfully undeploys app with all resources present", %{context: context} do
      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: ["myapp.com"],
        status: :running
      }

      TestMockAppState.put("myapp", app)
      add_container("otturnaut-myapp-deploy123")

      assert :ok = Deployment.undeploy("myapp", context)

      assert {:error, :not_found} = TestMockAppState.get("myapp")
      assert {:ok, :not_found} = TestMockRuntime.status("otturnaut-myapp-deploy123")
      assert [10042] = get_released_ports()
      assert ["myapp-route"] = get_removed_routes()
    end

    test "idempotent - returns ok when app not found", %{context: context} do
      assert {:error, :not_found} = TestMockAppState.get("myapp")
      assert :ok = Deployment.undeploy("myapp", context)
      assert [] = get_released_ports()
      assert [] = get_removed_routes()
    end

    test "handles partial cleanup when container already removed", %{context: context} do
      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: ["myapp.com"],
        status: :running
      }

      TestMockAppState.put("myapp", app)

      assert :ok = Deployment.undeploy("myapp", context)
      assert {:error, :not_found} = TestMockAppState.get("myapp")
      assert [10042] = get_released_ports()
      assert ["myapp-route"] = get_removed_routes()
    end

    test "skips stop when container already stopped", %{context: context} do
      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: ["myapp.com"],
        status: :running
      }

      TestMockAppState.put("myapp", app)
      add_container("otturnaut-myapp-deploy123")
      set_container_status("otturnaut-myapp-deploy123", :stopped)

      assert :ok = Deployment.undeploy("myapp", context)
      assert {:error, :not_found} = TestMockAppState.get("myapp")
      assert [10042] = get_released_ports()
      assert ["myapp-route"] = get_removed_routes()
    end

    test "skips Caddy route removal when no domains configured", %{context: context} do
      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: [],
        status: :running
      }

      TestMockAppState.put("myapp", app)
      add_container("otturnaut-myapp-deploy123")

      assert :ok = Deployment.undeploy("myapp", context)
      assert {:error, :not_found} = TestMockAppState.get("myapp")
      assert [10042] = get_released_ports()
      assert [] = get_removed_routes()
    end

    test "sends progress notifications when subscriber provided", %{context: context} do
      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: ["myapp.com"],
        status: :running
      }

      TestMockAppState.put("myapp", app)
      add_container("otturnaut-myapp-deploy123")

      assert :ok = Deployment.undeploy("myapp", context, subscriber: self())

      assert_receive {:undeploy_progress, %{step: :retrieve_state, message: _}}
      assert_receive {:undeploy_progress, %{step: :stop_container, message: _}}
      assert_receive {:undeploy_progress, %{step: :remove_container, message: _}}
      assert_receive {:undeploy_progress, %{step: :remove_routes, message: _}}
      assert_receive {:undeploy_progress, %{step: :release_port, message: "Releasing port 10042"}}
      assert_receive {:undeploy_progress, %{step: :clear_state, message: _}}
    end

    test "passes opts correctly to Caddy", %{context: context} do
      custom_context = %{context | caddy: UndeployOptsTrackingCaddy}

      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: ["myapp.com"],
        status: :running
      }

      TestMockAppState.put("myapp", app)
      add_container("otturnaut-myapp-deploy123")

      custom_opts = [subscriber: self(), custom: :value]
      assert :ok = Deployment.undeploy("myapp", custom_context, custom_opts)
      assert Process.get(:tracked_opts) == custom_opts
    end

    test "continues cleanup when stop fails", %{context: context} do
      custom_context = %{context | runtime: UndeployFailingStopRuntime}

      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: [],
        status: :running
      }

      TestMockAppState.put("myapp", app)

      assert :ok = Deployment.undeploy("myapp", custom_context)
      assert {:error, :not_found} = TestMockAppState.get("myapp")
      assert [10042] = get_released_ports()
    end

    test "continues cleanup when status check fails", %{context: context} do
      custom_context = %{context | runtime: UndeployFailingStatusRuntime}

      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: [],
        status: :running
      }

      TestMockAppState.put("myapp", app)

      assert :ok = Deployment.undeploy("myapp", custom_context)
      assert {:error, :not_found} = TestMockAppState.get("myapp")
      assert [10042] = get_released_ports()
    end

    test "continues cleanup when remove fails", %{context: context} do
      custom_context = %{context | runtime: UndeployFailingRemoveRuntime}

      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: [],
        status: :running
      }

      TestMockAppState.put("myapp", app)

      assert :ok = Deployment.undeploy("myapp", custom_context)
      assert {:error, :not_found} = TestMockAppState.get("myapp")
      assert [10042] = get_released_ports()
    end

    test "continues cleanup when Caddy route removal fails", %{context: context} do
      custom_context = %{context | caddy: UndeployFailingCaddy}

      app = %{
        deployment_id: "deploy123",
        container_name: "otturnaut-myapp-deploy123",
        port: 10042,
        domains: ["myapp.com"],
        status: :running
      }

      TestMockAppState.put("myapp", app)
      add_container("otturnaut-myapp-deploy123")

      assert :ok = Deployment.undeploy("myapp", custom_context)
      assert {:error, :not_found} = TestMockAppState.get("myapp")
      assert [10042] = get_released_ports()
    end
  end
end
