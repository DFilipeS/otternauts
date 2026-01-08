defmodule Otturnaut.Deployment.Steps.SwitchRouteTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Steps.SwitchRoute

  defmodule MockCaddy do
    def add_route(route, _opts) do
      Process.put({:route, route.id}, route)
      :ok
    end

    def remove_route(route_id, _opts) do
      Process.delete({:route, route_id})
      :ok
    end
  end

  defmodule FailingCaddy do
    def add_route(_route, _opts), do: {:error, :caddy_unavailable}
  end

  describe "run/3" do
    test "adds route when domains are configured" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: ["myapp.com"]
        })

      previous_state = %{previous_container_name: nil, previous_port: nil}

      arguments = %{
        deployment: deployment,
        port: 10000,
        previous_state: previous_state,
        caddy: MockCaddy
      }

      assert {:ok, result} = SwitchRoute.run(arguments, %{}, [])

      assert result.route_id == "myapp-route"
      assert result.previous_port == nil

      route = Process.get({:route, "myapp-route"})
      assert route.upstream_port == 10000
    end

    test "skips route when no domains are configured" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: []
        })

      previous_state = %{previous_container_name: nil, previous_port: nil}

      arguments = %{
        deployment: deployment,
        port: 10000,
        previous_state: previous_state,
        caddy: MockCaddy
      }

      assert {:ok, :no_route_needed} = SwitchRoute.run(arguments, %{}, [])
    end

    test "returns error when caddy fails" do
      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: ["myapp.com"]
        })

      previous_state = %{previous_container_name: nil, previous_port: nil}

      arguments = %{
        deployment: deployment,
        port: 10000,
        previous_state: previous_state,
        caddy: FailingCaddy
      }

      assert {:error, {:route_switch_failed, :caddy_unavailable}} =
               SwitchRoute.run(arguments, %{}, [])
    end
  end

  describe "undo/4" do
    test "does nothing when no route was needed" do
      arguments = %{deployment: nil, caddy: MockCaddy}

      assert :ok = SwitchRoute.undo(:no_route_needed, arguments, %{}, [])
    end

    test "removes route when it was a fresh deployment" do
      Process.put({:route, "myapp-route"}, %{id: "myapp-route"})
      result = %{route_id: "myapp-route", previous_port: nil}

      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: ["myapp.com"]
        })

      arguments = %{deployment: deployment, caddy: MockCaddy}

      assert :ok = SwitchRoute.undo(result, arguments, %{}, [])

      refute Process.get({:route, "myapp-route"})
    end

    test "restores previous route when there was a previous port" do
      result = %{route_id: "myapp-route", previous_port: 9999}

      deployment =
        Deployment.new(%{
          id: "deploy-1",
          app_id: "myapp",
          image: "myapp:latest",
          container_port: 3000,
          domains: ["myapp.com"]
        })

      arguments = %{deployment: deployment, caddy: MockCaddy}

      assert :ok = SwitchRoute.undo(result, arguments, %{}, [])

      route = Process.get({:route, "myapp-route"})
      assert route.upstream_port == 9999
    end
  end
end
