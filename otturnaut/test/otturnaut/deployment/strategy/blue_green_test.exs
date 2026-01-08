defmodule Otturnaut.Deployment.Strategy.BlueGreenTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Strategy.BlueGreen

  defmodule MockRuntime do
    def start(opts) do
      %{name: name} = opts
      container_id = "container-#{System.unique_integer([:positive])}"

      :ets.insert(:blue_green_test_state, {{:containers, name}, container_id})
      :ets.insert(:blue_green_test_state, {{:statuses, name}, :running})

      {:ok, container_id}
    end

    def stop(name, _opts \\ []) do
      :ets.insert(:blue_green_test_state, {{:statuses, name}, :stopped})
      :ok
    end

    def remove(name, _opts \\ []) do
      :ets.delete(:blue_green_test_state, {:containers, name})
      :ok
    end

    def status(name, _opts \\ []) do
      case :ets.lookup(:blue_green_test_state, {:statuses, name}) do
        [{{:statuses, ^name}, status}] -> {:ok, status}
        [] -> {:ok, :not_found}
      end
    end
  end

  defmodule MockPortManager do
    def allocate do
      case :ets.lookup(:blue_green_test_state, :next_port) do
        [{:next_port, port}] ->
          :ets.insert(:blue_green_test_state, {:next_port, port + 1})
          :ets.insert(:blue_green_test_state, {{:allocated, port}, true})
          {:ok, port}

        [] ->
          :ets.insert(:blue_green_test_state, {:next_port, 10001})
          :ets.insert(:blue_green_test_state, {{:allocated, 10000}, true})
          {:ok, 10000}
      end
    end

    def release(port) do
      :ets.delete(:blue_green_test_state, {:allocated, port})
      :ok
    end

    def mark_in_use(port) do
      :ets.insert(:blue_green_test_state, {{:allocated, port}, true})
      :ok
    end

    def allocated_ports do
      :ets.match(:blue_green_test_state, {{:allocated, :"$1"}, true})
      |> List.flatten()
    end
  end

  defmodule MockAppState do
    def get(app_id) do
      case :ets.lookup(:blue_green_test_state, {:apps, app_id}) do
        [{{:apps, ^app_id}, app}] -> {:ok, app}
        [] -> {:error, :not_found}
      end
    end

    def put(app_id, app) do
      :ets.insert(:blue_green_test_state, {{:apps, app_id}, app})
      :ok
    end

    def delete(app_id) do
      :ets.delete(:blue_green_test_state, {:apps, app_id})
      :ok
    end
  end

  defmodule MockCaddy do
    def add_route(route, _opts \\ []) do
      :ets.insert(:blue_green_test_state, {{:routes, route.id}, route})
      :ok
    end

    def remove_route(route_id, _opts \\ []) do
      :ets.delete(:blue_green_test_state, {:routes, route_id})
      :ok
    end

    def get_routes do
      :ets.match(:blue_green_test_state, {{:routes, :_}, :"$1"})
      |> List.flatten()
    end
  end

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

  defmodule GenericErrorRuntime do
    def start(_opts), do: {:error, %{message: "generic error"}}
  end

  defmodule SimpleErrorRuntime do
    def start(_opts), do: {:error, :simple_error}
  end

  defp set_container_status(name, status) do
    :ets.insert(:blue_green_test_state, {{:statuses, name}, status})
  end

  setup do
    if :ets.whereis(:blue_green_test_state) != :undefined do
      :ets.delete(:blue_green_test_state)
    end

    :ets.new(:blue_green_test_state, [:named_table, :public, :set])
    :ets.insert(:blue_green_test_state, {:next_port, 10000})

    on_exit(fn ->
      if :ets.whereis(:blue_green_test_state) != :undefined do
        :ets.delete(:blue_green_test_state)
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
      assert completed.container_name == "otturnaut-myapp-deploy-1"

      {:ok, app} = MockAppState.get("myapp")
      assert app.port == 10000
      assert app.status == :running

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
      assert MockCaddy.get_routes() == []
    end

    test "replaces existing deployment", %{context: context} do
      MockAppState.put("myapp", %{
        deployment_id: "old-deploy",
        container_name: "otturnaut-myapp-old-deploy",
        port: 9999,
        domains: ["myapp.com"],
        status: :running
      })

      set_container_status("otturnaut-myapp-old-deploy", :running)
      MockPortManager.mark_in_use(9999)

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
      assert completed.container_name == "otturnaut-myapp-deploy-2"

      {:ok, app} = MockAppState.get("myapp")
      assert app.port == 10000
      assert app.container_name == "otturnaut-myapp-deploy-2"

      case :ets.lookup(:blue_green_test_state, {:statuses, "otturnaut-myapp-old-deploy"}) do
        [{{:statuses, _}, status}] -> assert status == :stopped
        [] -> :ok
      end

      allocated = MockPortManager.allocated_ports()
      refute 9999 in allocated
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

    test "fails when container start fails and releases port", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: FailingRuntime
        })

      assert {:error, {:container_start_failed, {:exit, 1}}, failed} =
               BlueGreen.execute(deployment, context, [])

      assert failed.status == :failed

      allocated = MockPortManager.allocated_ports()
      assert allocated == []
    end

    test "fails when health check fails and cleans up", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: UnhealthyRuntime
        })

      opts = [health_check: [max_attempts: 2, interval: 10]]

      assert {:error, :health_check_failed, failed} =
               BlueGreen.execute(deployment, context, opts)

      assert failed.status == :failed

      allocated = MockPortManager.allocated_ports()
      assert allocated == []
    end

    test "fails when route switch fails and cleans up", %{context: context} do
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

      allocated = MockPortManager.allocated_ports()
      assert allocated == []
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

      assert {:ok, _completed} = BlueGreen.execute(deployment, context, subscriber: self())
    end
  end

  describe "rollback/3" do
    test "cleans up container and port on failed deployment", %{context: context} do
      MockRuntime.start(%{name: "otturnaut-myapp-deploy-1"})
      MockPortManager.mark_in_use(10000)

      deployment = %Deployment{
        id: "deploy-1",
        app_id: "myapp",
        image: "myapp:latest",
        container_port: 3000,
        domains: [],
        port: 10000,
        container_name: "otturnaut-myapp-deploy-1",
        container_id: "container-123",
        status: :failed,
        error: :some_error,
        runtime: MockRuntime,
        runtime_opts: []
      }

      assert :ok = BlueGreen.rollback(deployment, context, [])

      allocated = MockPortManager.allocated_ports()
      refute 10000 in allocated
    end

    test "restores previous route on failed deployment with previous port", %{context: context} do
      MockRuntime.start(%{name: "otturnaut-myapp-deploy-1"})
      MockPortManager.mark_in_use(10000)
      MockPortManager.mark_in_use(9999)

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

      [route] = MockCaddy.get_routes()
      assert route.upstream_port == 9999
    end

    test "handles rollback with nil container_name", %{context: context} do
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

    test "handles rollback with nil port", %{context: context} do
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
      assert MockCaddy.get_routes() == []
    end
  end

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

      assert :ok = BlueGreen.rollback(deployment, context)
    end
  end

  defmodule OptsCapturingRuntime do
    def start(opts) do
      :ets.insert(:blue_green_test_state, {{:calls, :start}, opts})
      {:ok, "container-123"}
    end

    def status(name, opts \\ []) do
      calls = get_calls(:status)
      :ets.insert(:blue_green_test_state, {{:calls, :status}, [{name, opts} | calls]})
      {:ok, :running}
    end

    def stop(name, opts \\ []) do
      calls = get_calls(:stop)
      :ets.insert(:blue_green_test_state, {{:calls, :stop}, [{name, opts} | calls]})
      :ok
    end

    def remove(name, opts \\ []) do
      calls = get_calls(:remove)
      :ets.insert(:blue_green_test_state, {{:calls, :remove}, [{name, opts} | calls]})
      :ok
    end

    defp get_calls(type) do
      case :ets.lookup(:blue_green_test_state, {:calls, type}) do
        [{{:calls, ^type}, calls}] -> calls
        [] -> []
      end
    end

    def get_start_opts do
      case :ets.lookup(:blue_green_test_state, {:calls, :start}) do
        [{{:calls, :start}, opts}] -> opts
        [] -> nil
      end
    end

    def get_status_calls do
      case :ets.lookup(:blue_green_test_state, {:calls, :status}) do
        [{{:calls, :status}, calls}] -> calls
        [] -> []
      end
    end

    def get_stop_calls do
      case :ets.lookup(:blue_green_test_state, {:calls, :stop}) do
        [{{:calls, :stop}, calls}] -> calls
        [] -> []
      end
    end
  end

  describe "error extraction edge cases" do
    test "handles error with generic error map", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: GenericErrorRuntime
        })

      assert {:error, {:container_start_failed, %{message: "generic error"}}, _failed} =
               BlueGreen.execute(deployment, context, [])
    end

    test "handles simple atom error", %{context: context} do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: [],
          runtime: SimpleErrorRuntime
        })

      assert {:error, {:container_start_failed, :simple_error}, _failed} =
               BlueGreen.execute(deployment, context, [])
    end
  end

  describe "runtime_opts passthrough" do
    test "passes runtime_opts to runtime.start", %{context: context} do
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

      start_opts = OptsCapturingRuntime.get_start_opts()
      assert start_opts[:binary] == "podman"
    end

    test "passes runtime_opts to health check (runtime.status)", %{context: context} do
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

      status_calls = OptsCapturingRuntime.get_status_calls()
      assert length(status_calls) > 0
      {_name, status_opts} = hd(status_calls)
      assert status_opts[:binary] == "podman"
    end

    test "passes runtime_opts when stopping old container", %{context: context} do
      MockAppState.put("myapp", %{
        deployment_id: "old-deploy",
        container_name: "otturnaut-myapp-old-deploy",
        port: 9999,
        domains: [],
        status: :running
      })

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

      stop_calls = OptsCapturingRuntime.get_stop_calls()

      old_container_stop =
        Enum.find(stop_calls, fn {name, _opts} -> name == "otturnaut-myapp-old-deploy" end)

      assert old_container_stop != nil
      {_, stop_opts} = old_container_stop
      assert stop_opts[:binary] == "podman"
    end
  end
end
