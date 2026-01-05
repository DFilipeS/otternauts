defmodule Otturnaut.Deployment.Strategy.BlueGreenTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Strategy.BlueGreen

  # Mock modules using process dictionary for state (async-safe)
  defmodule MockRuntime do
    def start(opts) do
      %{name: name} = opts
      container_id = "container-#{System.unique_integer([:positive])}"

      state = Process.get(:blue_green_test_state, %{})

      new_state =
        state
        |> put_in([:containers, name], container_id)
        |> put_in([:statuses, name], :running)

      Process.put(:blue_green_test_state, new_state)

      {:ok, container_id}
    end

    def stop(name, _opts \\ []) do
      state = Process.get(:blue_green_test_state, %{})
      new_state = put_in(state, [:statuses, name], :stopped)
      Process.put(:blue_green_test_state, new_state)
      :ok
    end

    def remove(name, _opts \\ []) do
      state = Process.get(:blue_green_test_state, %{})
      new_state = %{state | containers: Map.delete(state.containers || %{}, name)}
      Process.put(:blue_green_test_state, new_state)
      :ok
    end

    def status(name, _opts \\ []) do
      state = Process.get(:blue_green_test_state, %{})
      status = get_in(state, [:statuses, name]) || :not_found
      {:ok, status}
    end
  end

  defmodule MockPortManager do
    def allocate do
      state = Process.get(:blue_green_test_state, %{})
      next_port = Map.get(state, :next_port, 10000)
      allocated = Map.get(state, :allocated, [])

      new_state =
        state
        |> Map.put(:next_port, next_port + 1)
        |> Map.put(:allocated, [next_port | allocated])

      Process.put(:blue_green_test_state, new_state)

      {:ok, next_port}
    end

    def release(port) do
      state = Process.get(:blue_green_test_state, %{})
      allocated = Map.get(state, :allocated, [])
      new_state = Map.put(state, :allocated, List.delete(allocated, port))
      Process.put(:blue_green_test_state, new_state)
      :ok
    end

    def mark_in_use(port) do
      state = Process.get(:blue_green_test_state, %{})
      allocated = Map.get(state, :allocated, [])
      new_state = Map.put(state, :allocated, [port | allocated])
      Process.put(:blue_green_test_state, new_state)
      :ok
    end
  end

  defmodule MockAppState do
    def get(app_id) do
      state = Process.get(:blue_green_test_state, %{})
      apps = Map.get(state, :apps, %{})

      case Map.get(apps, app_id) do
        nil -> {:error, :not_found}
        app -> {:ok, app}
      end
    end

    def put(app_id, app) do
      state = Process.get(:blue_green_test_state, %{})
      apps = Map.get(state, :apps, %{})
      new_state = Map.put(state, :apps, Map.put(apps, app_id, app))
      Process.put(:blue_green_test_state, new_state)
      :ok
    end
  end

  defmodule MockCaddy do
    def add_route(route, _opts \\ []) do
      state = Process.get(:blue_green_test_state, %{})
      routes = Map.get(state, :routes, %{})
      new_state = Map.put(state, :routes, Map.put(routes, route.id, route))
      Process.put(:blue_green_test_state, new_state)
      :ok
    end

    def remove_route(route_id, _opts \\ []) do
      state = Process.get(:blue_green_test_state, %{})
      routes = Map.get(state, :routes, %{})
      new_state = Map.put(state, :routes, Map.delete(routes, route_id))
      Process.put(:blue_green_test_state, new_state)
      :ok
    end

    def get_routes do
      state = Process.get(:blue_green_test_state, %{})
      routes = Map.get(state, :routes, %{})
      Map.values(routes)
    end
  end

  # Failure scenario mocks
  defmodule FailingPortManager do
    def allocate, do: {:error, :exhausted}
  end

  defmodule FailingRuntime do
    def start(_opts), do: {:error, {:exit, 1}}
    def status(_name, _opts \\ []), do: {:ok, :not_found}
  end

  defmodule UnhealthyRuntime do
    def start(opts), do: {:ok, "container-#{opts.name}"}
    def status(_name, _opts \\ []), do: {:ok, :stopped}
    def stop(_name, _opts \\ []), do: :ok
    def remove(_name, _opts \\ []), do: :ok
  end

  defmodule FailingCaddy do
    def add_route(_route, _opts), do: {:error, :caddy_unavailable}
  end

  # Helper functions for tests
  defp set_container_status(name, status) do
    state = Process.get(:blue_green_test_state, %{})
    new_state = put_in(state, [:statuses, name], status)
    Process.put(:blue_green_test_state, new_state)
  end

  setup do
    # Initialize state in process dictionary
    Process.put(:blue_green_test_state, %{
      containers: %{},
      statuses: %{},
      next_port: 10000,
      allocated: [],
      apps: %{},
      routes: %{}
    })

    on_exit(fn ->
      for mock <- [MockRuntime, MockPortManager, MockAppState, MockCaddy] do
        if pid = Process.whereis(mock) do
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    context = %{
      port_manager: MockPortManager,
      app_state: MockAppState,
      caddy: MockCaddy
    }

    {:ok, context: context}
  end

  describe "name/0" do
    test "returns strategy name" do
      assert BlueGreen.name() == "Blue-Green"
    end
  end

  describe "execute/3" do
    test "deploys a new app successfully", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: ["myapp.com"],
          runtime: MockRuntime
        })

      assert {:ok, completed} = BlueGreen.execute(deployment, context, [])

      assert completed.status == :completed
      assert completed.port == 10000
      assert completed.container_name == "otturnaut-myapp-deploy-1"
      assert is_binary(completed.container_id)

      # Verify app state was updated
      {:ok, app} = MockAppState.get("myapp")
      assert app.port == 10000
      assert app.status == :running

      # Verify route was configured
      [route] = MockCaddy.get_routes()
      assert route.upstream_port == 10000
    end

    test "deploys without domains (no route switching)", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: MockRuntime
        })

      assert {:ok, completed} = BlueGreen.execute(deployment, context, [])

      assert completed.status == :completed

      # No routes should be configured
      assert MockCaddy.get_routes() == []
    end

    test "replaces existing deployment", %{context: context} do
      # Set up existing app state
      MockAppState.put("myapp", %{
        deployment_id: "old-deploy",
        container_name: "otturnaut-myapp-old-deploy",
        port: 9999,
        domains: ["myapp.com"],
        status: :running
      })

      # Mark old container as running
      set_container_status("otturnaut-myapp-old-deploy", :running)

      deployment =
        Deployment.new(%{
          id: "deploy-2",
          app_id: "myapp",
          image: "myapp:v2",
          container_port: 3000,
          domains: ["myapp.com"],
          runtime: MockRuntime
        })

      assert {:ok, completed} = BlueGreen.execute(deployment, context, [])

      assert completed.status == :completed
      assert completed.previous_container_name == "otturnaut-myapp-old-deploy"
      assert completed.previous_port == 9999

      # Old container should be stopped
      {:ok, old_status} = MockRuntime.status("otturnaut-myapp-old-deploy")
      assert old_status == :stopped
    end

    test "sends progress notifications", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: ["myapp.com"],
          runtime: MockRuntime
        })

      {:ok, _} = BlueGreen.execute(deployment, context, subscriber: self())

      assert_received {:deployment_progress, %{step: :allocate_port}}
      assert_received {:deployment_progress, %{step: :start_container}}
      assert_received {:deployment_progress, %{step: :health_check}}
      assert_received {:deployment_progress, %{step: :switch_route}}
    end

    test "fails when port allocation fails", %{context: context} do
      context = %{context | port_manager: FailingPortManager}

      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: MockRuntime
        })

      assert {:error, {:port_allocation_failed, :exhausted}, failed} =
               BlueGreen.execute(deployment, context, [])

      assert failed.status == :failed
    end

    test "fails when container start fails", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: FailingRuntime
        })

      assert {:error, {:container_start_failed, _}, failed} =
               BlueGreen.execute(deployment, context, [])

      assert failed.status == :failed
    end

    test "fails when health check fails", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: UnhealthyRuntime
        })

      # Use very short retry settings
      opts = [health_check: [max_attempts: 1, interval: 1]]

      assert {:error, :health_check_failed, failed} =
               BlueGreen.execute(deployment, context, opts)

      assert failed.status == :failed
    end

    test "fails when route switch fails", %{context: context} do
      context = %{context | caddy: FailingCaddy}

      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: ["myapp.com"],
          runtime: MockRuntime
        })

      assert {:error, {:route_switch_failed, :caddy_unavailable}, failed} =
               BlueGreen.execute(deployment, context, [])

      assert failed.status == :failed
    end
  end

  describe "rollback/3" do
    test "cleans up new container and port", %{context: context} do
      deployment = %Deployment{
        id: "deploy-1",
        app_id: "myapp",
        image: "myapp:latest",
        container_port: 3000,
        domains: ["myapp.com"],
        port: 10000,
        container_name: "otturnaut-myapp-deploy-1",
        container_id: "container-123",
        status: :failed,
        error: :health_check_failed,
        runtime: MockRuntime,
        runtime_opts: []
      }

      # Mark container as running
      set_container_status("otturnaut-myapp-deploy-1", :running)
      MockPortManager.mark_in_use(10000)

      assert :ok = BlueGreen.rollback(deployment, context, [])

      # Container should be stopped
      {:ok, status} = MockRuntime.status("otturnaut-myapp-deploy-1")
      assert status == :stopped
    end

    test "restores old route if deployment failed after route switch", %{context: context} do
      deployment = %Deployment{
        id: "deploy-1",
        app_id: "myapp",
        image: "myapp:latest",
        container_port: 3000,
        domains: ["myapp.com"],
        port: 10000,
        container_name: "otturnaut-myapp-deploy-1",
        container_id: "container-123",
        previous_container_name: "otturnaut-myapp-old",
        previous_port: 9999,
        status: :failed,
        error: :some_error,
        runtime: MockRuntime,
        runtime_opts: []
      }

      assert :ok = BlueGreen.rollback(deployment, context, [])

      # Old route should be restored
      [route] = MockCaddy.get_routes()
      assert route.upstream_port == 9999
    end

    test "handles rollback with nil container_name", %{context: context} do
      # This happens if deployment failed before container was started
      deployment = %Deployment{
        id: "deploy-1",
        app_id: "myapp",
        image: "myapp:latest",
        container_port: 3000,
        domains: [],
        port: 10000,
        container_name: nil,
        container_id: nil,
        status: :failed,
        error: :some_error,
        runtime: MockRuntime,
        runtime_opts: []
      }

      assert :ok = BlueGreen.rollback(deployment, context, [])
    end

    test "handles rollback with nil port", %{context: context} do
      # This happens if deployment failed before port was allocated
      deployment = %Deployment{
        id: "deploy-1",
        app_id: "myapp",
        image: "myapp:latest",
        container_port: 3000,
        domains: [],
        port: nil,
        container_name: nil,
        container_id: nil,
        status: :failed,
        error: :some_error,
        runtime: MockRuntime,
        runtime_opts: []
      }

      assert :ok = BlueGreen.rollback(deployment, context, [])
    end

    test "does not restore route if status is not failed", %{context: context} do
      deployment = %Deployment{
        id: "deploy-1",
        app_id: "myapp",
        image: "myapp:latest",
        container_port: 3000,
        domains: ["myapp.com"],
        port: 10000,
        container_name: "otturnaut-myapp-deploy-1",
        container_id: "container-123",
        previous_container_name: "otturnaut-myapp-old",
        previous_port: 9999,
        status: :in_progress,
        error: nil,
        runtime: MockRuntime,
        runtime_opts: []
      }

      set_container_status("otturnaut-myapp-deploy-1", :running)

      assert :ok = BlueGreen.rollback(deployment, context, [])

      # No route should be restored (status wasn't :failed)
      assert MockCaddy.get_routes() == []
    end
  end

  # Tests to cover default argument function arity variants
  describe "default argument coverage" do
    test "execute with only deployment and context", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-default",
          app_id: "defaultapp",
          image: "app:latest",
          container_port: 3000,
          domains: [],
          runtime: MockRuntime
        })

      # Call execute/2 without opts to exercise default argument path
      assert {:ok, completed} = BlueGreen.execute(deployment, context)
      assert completed.status == :completed
    end

    test "rollback with only deployment and context", %{context: context} do
      deployment = %Deployment{
        id: "deploy-1",
        app_id: "myapp",
        image: "myapp:latest",
        container_port: 3000,
        domains: [],
        port: nil,
        container_name: nil,
        container_id: nil,
        status: :failed,
        error: :some_error,
        runtime: MockRuntime,
        runtime_opts: []
      }

      # Call rollback/2 without opts to exercise default argument path
      assert :ok = BlueGreen.rollback(deployment, context)
    end
  end

  # Mock runtime that captures the opts passed to it
  defmodule OptsCapturingRuntime do
    def start(opts) do
      calls = Process.get(:opts_capture_calls, [])
      Process.put(:opts_capture_calls, [{:start, opts} | calls])
      {:ok, "container-123"}
    end

    def status(name, opts \\ []) do
      calls = Process.get(:opts_capture_calls, [])
      Process.put(:opts_capture_calls, [{:status, name, opts} | calls])
      {:ok, :running}
    end

    def stop(name, opts \\ []) do
      calls = Process.get(:opts_capture_calls, [])
      Process.put(:opts_capture_calls, [{:stop, name, opts} | calls])
      :ok
    end

    def remove(name, opts \\ []) do
      calls = Process.get(:opts_capture_calls, [])
      Process.put(:opts_capture_calls, [{:remove, name, opts} | calls])
      :ok
    end

    def get_calls do
      Process.get(:opts_capture_calls, [])
    end
  end

  describe "runtime_opts passthrough" do
    setup do
      # Initialize state in process dictionary
      Process.put(:blue_green_test_state, %{
        containers: %{},
        statuses: %{},
        next_port: 10000,
        allocated: [],
        apps: %{},
        routes: %{}
      })

      Process.put(:opts_capture_calls, [])

      :ok
    end

    test "passes runtime_opts to runtime.start" do
      context = %{
        port_manager: MockPortManager,
        app_state: MockAppState,
        caddy: MockCaddy
      }

      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: OptsCapturingRuntime,
          runtime_opts: [binary: "podman"]
        })

      {:ok, _completed} = BlueGreen.execute(deployment, context, [])

      calls = OptsCapturingRuntime.get_calls()

      # Find the start call and verify binary was passed
      start_call =
        Enum.find(calls, fn
          {:start, _} -> true
          _ -> false
        end)

      {:start, start_opts} = start_call
      assert start_opts[:binary] == "podman"
    end

    test "passes runtime_opts to health check (runtime.status)" do
      context = %{
        port_manager: MockPortManager,
        app_state: MockAppState,
        caddy: MockCaddy
      }

      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: OptsCapturingRuntime,
          runtime_opts: [binary: "podman"]
        })

      {:ok, _completed} = BlueGreen.execute(deployment, context, [])

      calls = OptsCapturingRuntime.get_calls()

      # Find a status call and verify runtime_opts were passed
      status_call =
        Enum.find(calls, fn
          {:status, _, _} -> true
          _ -> false
        end)

      {:status, _name, status_opts} = status_call
      assert status_opts[:binary] == "podman"
    end

    test "passes runtime_opts when stopping old container" do
      # Set up existing app state
      MockAppState.put("myapp", %{
        deployment_id: "old-deploy",
        container_name: "otturnaut-myapp-old-deploy",
        port: 9999,
        domains: [],
        status: :running
      })

      context = %{
        port_manager: MockPortManager,
        app_state: MockAppState,
        caddy: MockCaddy
      }

      deployment =
        Deployment.new(%{
          id: "deploy-2",
          app_id: "myapp",
          image: "myapp:v2",
          container_port: 3000,
          domains: [],
          runtime: OptsCapturingRuntime,
          runtime_opts: [binary: "podman"]
        })

      {:ok, _completed} = BlueGreen.execute(deployment, context, [])

      calls = OptsCapturingRuntime.get_calls()

      # Find the stop call for old container
      stop_call =
        Enum.find(calls, fn
          {:stop, name, _} -> name == "otturnaut-myapp-old-deploy"
          _ -> false
        end)

      {:stop, _, stop_opts} = stop_call
      assert stop_opts[:binary] == "podman"
    end
  end
end
