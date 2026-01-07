defmodule Otturnaut.Caddy.ClientTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Otturnaut.Caddy.Client

  # Helper to create a plug option for this test
  defp plug(test_name) do
    [plug: {Req.Test, test_name}]
  end

  describe "get_config/2" do
    test "returns config on success" do
      Req.Test.stub(__MODULE__.GetConfigSuccess, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/config/test/"

        Req.Test.json(conn, %{"key" => "value"})
      end)

      result = Client.get_config("/test", plug(__MODULE__.GetConfigSuccess))
      assert {:ok, %{"key" => "value"}} = result
    end

    test "returns error on unexpected status" do
      Req.Test.stub(__MODULE__.GetConfigNotFound, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not found"}))
      end)

      result = Client.get_config("/missing", plug(__MODULE__.GetConfigNotFound))
      assert {:error, {:unexpected_status, 404, _body}} = result
    end

    test "returns :caddy_unavailable when connection refused" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      result = Client.get_config("/test")
      assert {:error, :caddy_unavailable} = result
    end

    test "returns :timeout on timeout error" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      result = Client.get_config("/test")
      assert {:error, :timeout} = result
    end

    test "returns :request_failed on other errors" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :nxdomain}}
      end)

      result = Client.get_config("/test")
      assert {:error, :request_failed} = result
    end
  end

  describe "set_config/3" do
    test "returns :ok on success" do
      Req.Test.stub(__MODULE__.SetConfigSuccess, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/config/test/"

        Req.Test.json(conn, %{})
      end)

      result = Client.set_config("/test", %{"key" => "value"}, plug(__MODULE__.SetConfigSuccess))
      assert :ok = result
    end

    test "returns error on unexpected status" do
      Req.Test.stub(__MODULE__.SetConfigError, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "bad request"}))
      end)

      result = Client.set_config("/fail", %{}, plug(__MODULE__.SetConfigError))
      assert {:error, {:unexpected_status, 400, _body}} = result
    end

    test "returns :caddy_unavailable when connection refused" do
      stub(Req, :post, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      result = Client.set_config("/test", %{})
      assert {:error, :caddy_unavailable} = result
    end

    test "returns :timeout on timeout error" do
      stub(Req, :post, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      result = Client.set_config("/test", %{})
      assert {:error, :timeout} = result
    end

    test "returns :request_failed on other errors" do
      stub(Req, :post, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :nxdomain}}
      end)

      result = Client.set_config("/test", %{})
      assert {:error, :request_failed} = result
    end
  end

  describe "append_config/3" do
    test "returns :ok on success" do
      Req.Test.stub(__MODULE__.AppendConfigSuccess, fn conn ->
        assert conn.method == "POST"
        # Path ends with /.../ because we add trailing slash, then append_config adds /...
        assert conn.request_path == "/config/routes/.../"

        Req.Test.json(conn, %{})
      end)

      result = Client.append_config("/routes", %{}, plug(__MODULE__.AppendConfigSuccess))
      assert :ok = result
    end

    test "returns error on unexpected status" do
      Req.Test.stub(__MODULE__.AppendConfigError, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "server error"}))
      end)

      result = Client.append_config("/routes/fail", %{}, plug(__MODULE__.AppendConfigError))
      assert {:error, {:unexpected_status, 500, _body}} = result
    end

    test "returns :caddy_unavailable when connection refused" do
      stub(Req, :post, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      result = Client.append_config("/routes", %{})
      assert {:error, :caddy_unavailable} = result
    end

    test "returns :timeout on timeout error" do
      stub(Req, :post, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      result = Client.append_config("/test", %{})
      assert {:error, :timeout} = result
    end

    test "returns :request_failed on other errors" do
      stub(Req, :post, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :nxdomain}}
      end)

      result = Client.append_config("/test", %{})
      assert {:error, :request_failed} = result
    end
  end

  describe "patch_config/3" do
    test "returns :ok on success" do
      Req.Test.stub(__MODULE__.PatchConfigSuccess, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/config/routes/"

        Req.Test.json(conn, %{})
      end)

      result = Client.patch_config("/routes", [%{"@id" => "test"}], plug(__MODULE__.PatchConfigSuccess))
      assert :ok = result
    end

    test "returns error on unexpected status" do
      Req.Test.stub(__MODULE__.PatchConfigError, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "server error"}))
      end)

      result = Client.patch_config("/routes/fail", %{}, plug(__MODULE__.PatchConfigError))
      assert {:error, {:unexpected_status, 500, _body}} = result
    end

    test "returns :caddy_unavailable when connection refused" do
      stub(Req, :patch, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      result = Client.patch_config("/routes", %{})
      assert {:error, :caddy_unavailable} = result
    end

    test "returns :timeout on timeout error" do
      stub(Req, :patch, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      result = Client.patch_config("/test", %{})
      assert {:error, :timeout} = result
    end

    test "returns :request_failed on other errors" do
      stub(Req, :patch, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :nxdomain}}
      end)

      result = Client.patch_config("/test", %{})
      assert {:error, :request_failed} = result
    end
  end

  describe "delete_config/2" do
    test "returns :ok on success" do
      Req.Test.stub(__MODULE__.DeleteConfigSuccess, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/config/test/"

        Req.Test.json(conn, %{})
      end)

      result = Client.delete_config("/test", plug(__MODULE__.DeleteConfigSuccess))
      assert :ok = result
    end

    test "returns error on unexpected status" do
      Req.Test.stub(__MODULE__.DeleteConfigError, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not found"}))
      end)

      result = Client.delete_config("/missing", plug(__MODULE__.DeleteConfigError))
      assert {:error, {:unexpected_status, 404, _body}} = result
    end

    test "returns :caddy_unavailable when connection refused" do
      stub(Req, :delete, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      result = Client.delete_config("/test")
      assert {:error, :caddy_unavailable} = result
    end

    test "returns :timeout on timeout error" do
      stub(Req, :delete, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      result = Client.delete_config("/test")
      assert {:error, :timeout} = result
    end

    test "returns :request_failed on other errors" do
      stub(Req, :delete, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :nxdomain}}
      end)

      result = Client.delete_config("/test")
      assert {:error, :request_failed} = result
    end
  end

  describe "get_by_id/2" do
    test "returns object on success" do
      Req.Test.stub(__MODULE__.GetByIdSuccess, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/id/myroute"

        Req.Test.json(conn, %{"@id" => "myroute", "match" => []})
      end)

      result = Client.get_by_id("myroute", plug(__MODULE__.GetByIdSuccess))
      assert {:ok, %{"@id" => "myroute"}} = result
    end

    test "returns error on unexpected status" do
      Req.Test.stub(__MODULE__.GetByIdError, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not found"}))
      end)

      result = Client.get_by_id("missing", plug(__MODULE__.GetByIdError))
      assert {:error, {:unexpected_status, 404, _body}} = result
    end

    test "returns :caddy_unavailable when connection refused" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      result = Client.get_by_id("test")
      assert {:error, :caddy_unavailable} = result
    end

    test "returns :timeout on timeout error" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      result = Client.get_by_id("test")
      assert {:error, :timeout} = result
    end

    test "returns :request_failed on other errors" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :nxdomain}}
      end)

      result = Client.get_by_id("test")
      assert {:error, :request_failed} = result
    end
  end

  describe "put_by_id/3" do
    test "returns :ok on success" do
      Req.Test.stub(__MODULE__.PutByIdSuccess, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/id/myroute"

        Req.Test.json(conn, %{})
      end)

      result = Client.put_by_id("myroute", %{"key" => "value"}, plug(__MODULE__.PutByIdSuccess))
      assert :ok = result
    end

    test "returns error on unexpected status" do
      Req.Test.stub(__MODULE__.PutByIdError, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "bad request"}))
      end)

      result = Client.put_by_id("fail", %{}, plug(__MODULE__.PutByIdError))
      assert {:error, {:unexpected_status, 400, _body}} = result
    end

    test "returns :caddy_unavailable when connection refused" do
      stub(Req, :patch, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      result = Client.put_by_id("test", %{})
      assert {:error, :caddy_unavailable} = result
    end

    test "returns :timeout on timeout error" do
      stub(Req, :patch, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      result = Client.put_by_id("test", %{})
      assert {:error, :timeout} = result
    end

    test "returns :request_failed on other errors" do
      stub(Req, :patch, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :nxdomain}}
      end)

      result = Client.put_by_id("test", %{})
      assert {:error, :request_failed} = result
    end
  end

  describe "delete_by_id/2" do
    test "returns :ok on success" do
      Req.Test.stub(__MODULE__.DeleteByIdSuccess, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/id/myroute"

        Req.Test.json(conn, %{})
      end)

      result = Client.delete_by_id("myroute", plug(__MODULE__.DeleteByIdSuccess))
      assert :ok = result
    end

    test "returns error on unexpected status" do
      Req.Test.stub(__MODULE__.DeleteByIdError, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not found"}))
      end)

      result = Client.delete_by_id("missing", plug(__MODULE__.DeleteByIdError))
      assert {:error, {:unexpected_status, 404, _body}} = result
    end

    test "returns :caddy_unavailable when connection refused" do
      stub(Req, :delete, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      result = Client.delete_by_id("test")
      assert {:error, :caddy_unavailable} = result
    end

    test "returns :timeout on timeout error" do
      stub(Req, :delete, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      result = Client.delete_by_id("test")
      assert {:error, :timeout} = result
    end

    test "returns :request_failed on other errors" do
      stub(Req, :delete, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :nxdomain}}
      end)

      result = Client.delete_by_id("test")
      assert {:error, :request_failed} = result
    end
  end

  describe "health_check/1" do
    test "returns :ok when Caddy is reachable" do
      Req.Test.stub(__MODULE__.HealthCheckSuccess, fn conn ->
        Req.Test.json(conn, %{"apps" => %{}})
      end)

      result = Client.health_check(plug(__MODULE__.HealthCheckSuccess))
      assert :ok = result
    end

    test "returns error when Caddy is unreachable" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      result = Client.health_check()
      assert {:error, :caddy_unavailable} = result
    end

    test "returns :timeout on timeout error" do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      result = Client.health_check()
      assert {:error, :timeout} = result
    end
  end
end
