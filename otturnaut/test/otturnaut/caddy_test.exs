defmodule Otturnaut.CaddyTest do
  # Not async - tests share Caddy state
  use ExUnit.Case, async: false

  alias Otturnaut.Caddy
  alias Otturnaut.Caddy.Route

  # These tests require Caddy to be running.
  # Run with: mix test --include integration
  # Skip with: mix test --exclude integration
  @moduletag :integration

  # Use unprivileged ports and disable auto HTTPS for testing
  @test_opts [http_port: 8080, https_port: 8443, disable_auto_https: true]

  setup do
    # Clear any existing config before each test by deleting it
    # Use curl-style DELETE to ensure clean slate
    Req.delete("http://localhost:2019/config/")
    :ok
  end

  describe "health_check/1" do
    test "returns :ok when Caddy is running" do
      assert :ok = Caddy.health_check(@test_opts)
    end
  end

  describe "add_route/2" do
    test "adds a route and creates server if needed" do
      route = Route.new("test-app", "test.localhost", 9000)

      assert :ok = Caddy.add_route(route, @test_opts)
      assert {:ok, [^route]} = Caddy.list_routes(@test_opts)
    end

    test "adds multiple routes" do
      route1 = Route.new("app1", "app1.localhost", 3000)
      route2 = Route.new("app2", "app2.localhost", 4000)

      assert :ok = Caddy.add_route(route1, @test_opts)
      assert :ok = Caddy.add_route(route2, @test_opts)

      {:ok, routes} = Caddy.list_routes(@test_opts)
      assert length(routes) == 2
      assert Enum.any?(routes, &(&1.id == "app1"))
      assert Enum.any?(routes, &(&1.id == "app2"))
    end

    test "adds route with multiple domains" do
      route = Route.new("multi", ["a.localhost", "b.localhost"], 5000)

      assert :ok = Caddy.add_route(route, @test_opts)

      {:ok, routes} = Caddy.list_routes(@test_opts)
      retrieved = Enum.find(routes, &(&1.id == "multi"))
      assert retrieved.domains == ["a.localhost", "b.localhost"]
    end
  end

  describe "get_route/2" do
    test "retrieves a route by ID" do
      route = Route.new("findme", "find.localhost", 6000)
      :ok = Caddy.add_route(route, @test_opts)

      assert {:ok, found} = Caddy.get_route("findme", @test_opts)
      assert found.id == "findme"
      assert found.domains == ["find.localhost"]
      assert found.upstream_port == 6000
    end

    test "returns not_found for non-existent route" do
      # Ensure server exists first
      route = Route.new("exists", "exists.localhost", 7000)
      :ok = Caddy.add_route(route, @test_opts)

      assert {:error, :not_found} = Caddy.get_route("nonexistent", @test_opts)
    end
  end

  describe "remove_route/2" do
    test "removes a route by ID" do
      route = Route.new("removeme", "remove.localhost", 8000)
      :ok = Caddy.add_route(route, @test_opts)

      assert :ok = Caddy.remove_route("removeme", @test_opts)
      assert {:error, :not_found} = Caddy.get_route("removeme", @test_opts)
    end

    test "removing one route doesn't affect others" do
      route1 = Route.new("keep", "keep.localhost", 3001)
      route2 = Route.new("remove", "remove.localhost", 3002)

      :ok = Caddy.add_route(route1, @test_opts)
      :ok = Caddy.add_route(route2, @test_opts)
      :ok = Caddy.remove_route("remove", @test_opts)

      {:ok, routes} = Caddy.list_routes(@test_opts)
      assert length(routes) == 1
      assert hd(routes).id == "keep"
    end
  end

  describe "list_routes/1" do
    test "returns empty list when no routes exist" do
      # Create server without routes
      route = Route.new("temp", "temp.localhost", 9999)
      :ok = Caddy.add_route(route, @test_opts)
      :ok = Caddy.remove_route("temp", @test_opts)

      assert {:ok, []} = Caddy.list_routes(@test_opts)
    end

    test "returns empty list when server doesn't exist" do
      assert {:ok, []} = Caddy.list_routes(@test_opts)
    end
  end
end
