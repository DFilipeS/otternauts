defmodule Otturnaut.CaddyUnitTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Otturnaut.Caddy
  alias Otturnaut.Caddy.Route

  # Mock client for unit testing
  defmodule MockClient do
    # Store state in the process dictionary for flexibility
    def health_check(opts) do
      case get_mock_response(:health_check, opts) do
        nil -> :ok
        response -> response
      end
    end

    def get_config(path, opts) do
      case get_mock_response({:get_config, path}, opts) do
        nil -> {:ok, %{}}
        response -> response
      end
    end

    def set_config(path, _config, opts) do
      case get_mock_response({:set_config, path}, opts) do
        nil -> :ok
        response -> response
      end
    end

    def get_by_id(id, opts) do
      case get_mock_response({:get_by_id, id}, opts) do
        nil -> {:ok, %{"@id" => id}}
        response -> response
      end
    end

    def delete_by_id(id, opts) do
      case get_mock_response({:delete_by_id, id}, opts) do
        nil -> :ok
        response -> response
      end
    end

    defp get_mock_response(key, opts) do
      responses = Keyword.get(opts, :mock_responses, %{})
      Map.get(responses, key)
    end
  end

  describe "health_check/1" do
    test "returns :ok when client reports healthy" do
      assert :ok = Caddy.health_check(client: MockClient)
    end

    test "returns error when client returns error" do
      opts = [
        client: MockClient,
        mock_responses: %{health_check: {:error, :caddy_unavailable}}
      ]

      assert {:error, :caddy_unavailable} = Caddy.health_check(opts)
    end
  end

  describe "add_route/2" do
    test "adds a route when server exists" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, %{"routes" => []}}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "creates server and adds route when server doesn't exist (nil)" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, nil}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "creates server when 404 error" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} =>
            {:error, {:unexpected_status, 404, "not found"}},
          {:get_config, ""} => {:ok, nil}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "creates server when 400 error (parent path missing)" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} =>
            {:error, {:unexpected_status, 400, "bad request"}},
          {:get_config, ""} => {:ok, nil}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "propagates error from ensure_server_exists" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:error, :caddy_unavailable}
        }
      ]

      assert {:error, :caddy_unavailable} = Caddy.add_route(route, opts)
    end
  end

  describe "remove_route/2" do
    test "removes route by id" do
      opts = [client: MockClient]
      assert :ok = Caddy.remove_route("myapp", opts)
    end

    test "returns error on failure" do
      opts = [
        client: MockClient,
        mock_responses: %{
          {:delete_by_id, "missing"} => {:error, {:unexpected_status, 404, "not found"}}
        }
      ]

      assert {:error, {:unexpected_status, 404, "not found"}} = Caddy.remove_route("missing", opts)
    end
  end

  describe "list_routes/1" do
    test "returns parsed routes when routes exist" do
      route_config = %{
        "@id" => "myapp",
        "match" => [%{"host" => ["myapp.com"]}],
        "handle" => [
          %{
            "handler" => "reverse_proxy",
            "upstreams" => [%{"dial" => "localhost:3000"}]
          }
        ]
      }

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut/routes"} => {:ok, [route_config]}
        }
      ]

      assert {:ok, [route]} = Caddy.list_routes(opts)
      assert route.id == "myapp"
      assert route.domains == ["myapp.com"]
      assert route.upstream_port == 3000
    end

    test "returns empty list when routes is nil" do
      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut/routes"} => {:ok, nil}
        }
      ]

      assert {:ok, []} = Caddy.list_routes(opts)
    end

    test "returns empty list on 404" do
      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut/routes"} =>
            {:error, {:unexpected_status, 404, "not found"}}
        }
      ]

      assert {:ok, []} = Caddy.list_routes(opts)
    end

    test "returns empty list on 400 (server doesn't exist)" do
      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut/routes"} =>
            {:error, {:unexpected_status, 400, "bad request"}}
        }
      ]

      assert {:ok, []} = Caddy.list_routes(opts)
    end

    test "filters out invalid route configs" do
      valid_route = %{
        "@id" => "valid",
        "match" => [%{"host" => ["valid.com"]}],
        "handle" => [
          %{
            "handler" => "reverse_proxy",
            "upstreams" => [%{"dial" => "localhost:3000"}]
          }
        ]
      }

      # Invalid route (missing required fields)
      invalid_route = %{"@id" => "invalid"}

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut/routes"} =>
            {:ok, [valid_route, invalid_route]}
        }
      ]

      assert {:ok, [route]} = Caddy.list_routes(opts)
      assert route.id == "valid"
    end

    test "propagates other errors" do
      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut/routes"} => {:error, :caddy_unavailable}
        }
      ]

      assert {:error, :caddy_unavailable} = Caddy.list_routes(opts)
    end
  end

  describe "get_route/2" do
    test "returns route when found" do
      route_config = %{
        "@id" => "myapp",
        "match" => [%{"host" => ["myapp.com"]}],
        "handle" => [
          %{
            "handler" => "reverse_proxy",
            "upstreams" => [%{"dial" => "localhost:3000"}]
          }
        ]
      }

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_by_id, "myapp"} => {:ok, route_config}
        }
      ]

      assert {:ok, route} = Caddy.get_route("myapp", opts)
      assert route.id == "myapp"
    end

    test "returns not_found on 404" do
      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_by_id, "missing"} => {:error, {:unexpected_status, 404, "not found"}}
        }
      ]

      assert {:error, :not_found} = Caddy.get_route("missing", opts)
    end

    test "propagates other errors" do
      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_by_id, "myapp"} => {:error, :caddy_unavailable}
        }
      ]

      assert {:error, :caddy_unavailable} = Caddy.get_route("myapp", opts)
    end
  end

  describe "create_server/1 (via add_route)" do
    # Test the different config states that create_server handles

    test "creates full config when config is completely empty" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, nil}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "creates server when http.servers exists" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, %{"apps" => %{"http" => %{"servers" => %{}}}}}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "creates servers when http exists but no servers" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, %{"apps" => %{"http" => %{}}}}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "creates http when apps exists but no http" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, %{"apps" => %{}}}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "creates apps when config is empty object" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, %{}}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "propagates error from get_config" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:error, :caddy_unavailable}
        }
      ]

      assert {:error, :caddy_unavailable} = Caddy.add_route(route, opts)
    end
  end

  describe "port configuration" do
    test "uses custom http and https ports" do
      # This test verifies the code path for custom ports
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        http_port: 8080,
        https_port: 8443,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, %{"routes" => []}}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "disables auto https when requested" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        disable_auto_https: true,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, nil}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end

    test "uses default auto https (enabled) when not specified" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        # disable_auto_https is false by default
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, nil}
        }
      ]

      assert :ok = Caddy.add_route(route, opts)
    end
  end

  describe "set_config path handling" do
    test "handles set_config error during server creation" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, nil},
          {:set_config, ""} => {:error, :request_failed}
        }
      ]

      assert {:error, :request_failed} = Caddy.add_route(route, opts)
    end

    test "handles set_config error when server path fails" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, %{"apps" => %{"http" => %{"servers" => %{}}}}},
          {:set_config, "/apps/http/servers/otturnaut"} => {:error, :request_failed}
        }
      ]

      assert {:error, :request_failed} = Caddy.add_route(route, opts)
    end

    test "handles set_config error when http servers path fails" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, %{"apps" => %{"http" => %{}}}},
          {:set_config, "/apps/http/servers"} => {:error, :request_failed}
        }
      ]

      assert {:error, :request_failed} = Caddy.add_route(route, opts)
    end

    test "handles set_config error when apps http path fails" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, %{"apps" => %{}}},
          {:set_config, "/apps/http"} => {:error, :request_failed}
        }
      ]

      assert {:error, :request_failed} = Caddy.add_route(route, opts)
    end

    test "handles set_config error when apps path fails" do
      route = Route.new("myapp", "myapp.com", 3000)

      opts = [
        client: MockClient,
        mock_responses: %{
          {:get_config, "/apps/http/servers/otturnaut"} => {:ok, nil},
          {:get_config, ""} => {:ok, %{}},
          {:set_config, "/apps"} => {:error, :request_failed}
        }
      ]

      assert {:error, :request_failed} = Caddy.add_route(route, opts)
    end
  end

  # Tests to cover default argument function arity variants
  # These use mimic to stub Req so they don't need a real Caddy server
  describe "default argument coverage" do
    test "health_check without opts" do
      stub(Req, :get, fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{}}}
      end)

      assert :ok = Caddy.health_check()
    end

    test "add_route without opts" do
      stub(Req, :get, fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"routes" => []}}}
      end)

      stub(Req, :post, fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{}}}
      end)

      route = Route.new("coverage-test-app", "coverage-test.localhost", 3000)
      assert :ok = Caddy.add_route(route)
    end

    test "remove_route without opts" do
      stub(Req, :delete, fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{}}}
      end)

      assert :ok = Caddy.remove_route("nonexistent-coverage-test")
    end

    test "list_routes without opts" do
      stub(Req, :get, fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: []}}
      end)

      assert {:ok, []} = Caddy.list_routes()
    end

    test "get_route without opts" do
      route_config = %{
        "@id" => "test",
        "match" => [%{"host" => ["test.com"]}],
        "handle" => [
          %{
            "handler" => "reverse_proxy",
            "upstreams" => [%{"dial" => "localhost:3000"}]
          }
        ]
      }

      stub(Req, :get, fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: route_config}}
      end)

      assert {:ok, route} = Caddy.get_route("test")
      assert route.id == "test"
    end
  end
end
