defmodule Otturnaut.Caddy.RouteTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Caddy.Route

  describe "new/3" do
    test "creates route with single domain" do
      route = Route.new("myapp", "myapp.com", 3000)

      assert route.id == "myapp"
      assert route.domains == ["myapp.com"]
      assert route.upstream_port == 3000
    end

    test "creates route with multiple domains" do
      route = Route.new("myapp", ["myapp.com", "www.myapp.com"], 3000)

      assert route.id == "myapp"
      assert route.domains == ["myapp.com", "www.myapp.com"]
      assert route.upstream_port == 3000
    end
  end

  describe "to_caddy_config/1" do
    test "converts route to Caddy JSON format" do
      route = Route.new("myapp", ["myapp.com"], 3000)
      config = Route.to_caddy_config(route)

      assert config["@id"] == "myapp"
      assert config["match"] == [%{"host" => ["myapp.com"]}]
      assert config["handle"] == [
        %{
          "handler" => "reverse_proxy",
          "upstreams" => [%{"dial" => "127.0.0.1:3000"}]
        }
      ]
    end
  end

  describe "from_caddy_config/1" do
    test "parses route from Caddy JSON format" do
      config = %{
        "@id" => "myapp",
        "match" => [%{"host" => ["myapp.com", "www.myapp.com"]}],
        "handle" => [
          %{
            "handler" => "reverse_proxy",
            "upstreams" => [%{"dial" => "127.0.0.1:4000"}]
          }
        ]
      }

      assert {:ok, route} = Route.from_caddy_config(config)
      assert route.id == "myapp"
      assert route.domains == ["myapp.com", "www.myapp.com"]
      assert route.upstream_port == 4000
    end

    test "returns error for missing @id" do
      config = %{
        "match" => [%{"host" => ["myapp.com"]}],
        "handle" => [%{"upstreams" => [%{"dial" => "127.0.0.1:3000"}]}]
      }

      assert {:error, "missing or invalid @id"} = Route.from_caddy_config(config)
    end

    test "returns error for missing host" do
      config = %{
        "@id" => "myapp",
        "handle" => [%{"upstreams" => [%{"dial" => "127.0.0.1:3000"}]}]
      }

      assert {:error, "missing or invalid match.host"} = Route.from_caddy_config(config)
    end

    test "returns error for missing upstream" do
      config = %{
        "@id" => "myapp",
        "match" => [%{"host" => ["myapp.com"]}]
      }

      assert {:error, _} = Route.from_caddy_config(config)
    end

    test "returns error for invalid dial format" do
      config = %{
        "@id" => "myapp",
        "match" => [%{"host" => ["myapp.com"]}],
        "handle" => [
          %{
            "handler" => "reverse_proxy",
            "upstreams" => [%{"dial" => "invalid-dial-format"}]
          }
        ]
      }

      assert {:error, "could not parse port from dial: invalid-dial-format"} =
               Route.from_caddy_config(config)
    end
  end

  describe "roundtrip" do
    test "route survives conversion to and from Caddy config" do
      original = Route.new("test", ["a.com", "b.com"], 8080)
      config = Route.to_caddy_config(original)
      {:ok, parsed} = Route.from_caddy_config(config)

      assert parsed.id == original.id
      assert parsed.domains == original.domains
      assert parsed.upstream_port == original.upstream_port
    end
  end
end
