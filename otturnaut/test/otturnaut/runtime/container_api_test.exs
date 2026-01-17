defmodule Otturnaut.Runtime.ContainerAPITest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Otturnaut.Runtime.ContainerAPI

  setup do
    Req.Test.set_req_test_to_private()
    :ok
  end

  describe "list_containers/2" do
    test "returns normalized containers" do
      Req.Test.stub(:container_api, fn conn ->
        containers = [
          %{
            "Id" => "abc123def",
            "Names" => ["/otturnaut-myapp-deploy1"],
            "Image" => "myapp:latest",
            "State" => "running",
            "Status" => "Up 2 hours",
            "Ports" => [%{"PublicPort" => 10042, "PrivatePort" => 3000}]
          }
        ]

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(containers))
      end)

      {:ok, containers} = ContainerAPI.list_containers({Req.Test, :container_api})

      assert length(containers) == 1
      [container] = containers
      assert container.id == "abc123def"
      assert container.names == ["/otturnaut-myapp-deploy1"]
      assert container.image == "myapp:latest"
      assert container.state == "running"
    end

    test "handles empty list" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, "[]")
      end)

      {:ok, containers} = ContainerAPI.list_containers({Req.Test, :container_api})
      assert containers == []
    end

    test "handles API error" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{"message" => "Internal error"}))
      end)

      {:error, {:http_error, 500, _}} = ContainerAPI.list_containers({Req.Test, :container_api})
    end

    test "handles missing optional fields" do
      Req.Test.stub(:container_api, fn conn ->
        containers = [
          %{
            "Id" => "abc123",
            "Image" => "myapp:latest",
            "State" => "running",
            "Status" => "Up"
          }
        ]

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(containers))
      end)

      {:ok, [container]} = ContainerAPI.list_containers({Req.Test, :container_api})
      assert container.names == []
      assert container.ports == []
    end
  end

  describe "create_container/2" do
    test "creates container and returns id" do
      Req.Test.stub(:container_api, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/containers/create"
        assert conn.query_params["name"] == "otturnaut-test-123"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, Jason.encode!(%{"Id" => "new-container-id", "Warnings" => []}))
      end)

      opts = %{
        image: "myapp:latest",
        name: "otturnaut-test-123",
        env: %{"PORT" => "3000"},
        port_bindings: %{"3000/tcp" => 10042}
      }

      {:ok, container_id} = ContainerAPI.create_container({Req.Test, :container_api}, opts)
      assert container_id == "new-container-id"
    end

    test "handles creation error" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(409, Jason.encode!(%{"message" => "Conflict: name already in use"}))
      end)

      opts = %{
        image: "myapp:latest",
        name: "existing-container",
        env: %{},
        port_bindings: %{}
      }

      {:error, {:http_error, 409, _}} =
        ContainerAPI.create_container({Req.Test, :container_api}, opts)
    end
  end

  describe "start_container/2" do
    test "starts container successfully" do
      Req.Test.stub(:container_api, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/containers/abc123/start"
        send_resp(conn, 204, "")
      end)

      assert :ok = ContainerAPI.start_container({Req.Test, :container_api}, "abc123")
    end

    test "handles already started (304)" do
      Req.Test.stub(:container_api, fn conn ->
        send_resp(conn, 304, "")
      end)

      assert :ok = ContainerAPI.start_container({Req.Test, :container_api}, "abc123")
    end

    test "handles start error" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{"message" => "Container failed to start"}))
      end)

      {:error, {:http_error, 500, _}} =
        ContainerAPI.start_container({Req.Test, :container_api}, "abc123")
    end
  end

  describe "stop_container/3" do
    test "stops container successfully" do
      Req.Test.stub(:container_api, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/containers/abc123/stop"
        send_resp(conn, 204, "")
      end)

      assert :ok = ContainerAPI.stop_container({Req.Test, :container_api}, "abc123")
    end

    test "handles already stopped (304)" do
      Req.Test.stub(:container_api, fn conn ->
        send_resp(conn, 304, "")
      end)

      assert :ok = ContainerAPI.stop_container({Req.Test, :container_api}, "abc123")
    end

    test "handles not found (404)" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"message" => "No such container"}))
      end)

      {:error, :not_found} = ContainerAPI.stop_container({Req.Test, :container_api}, "missing")
    end

    test "passes timeout parameter" do
      Req.Test.stub(:container_api, fn conn ->
        assert conn.query_params["t"] == "30"
        send_resp(conn, 204, "")
      end)

      assert :ok =
               ContainerAPI.stop_container({Req.Test, :container_api}, "abc123", timeout: 30)
    end
  end

  describe "remove_container/3" do
    test "removes container successfully" do
      Req.Test.stub(:container_api, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/containers/abc123"
        send_resp(conn, 204, "")
      end)

      assert :ok = ContainerAPI.remove_container({Req.Test, :container_api}, "abc123")
    end

    test "handles not found (404)" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"message" => "No such container"}))
      end)

      {:error, :not_found} = ContainerAPI.remove_container({Req.Test, :container_api}, "missing")
    end

    test "passes force parameter" do
      Req.Test.stub(:container_api, fn conn ->
        assert conn.query_params["force"] == "true"
        send_resp(conn, 204, "")
      end)

      assert :ok =
               ContainerAPI.remove_container({Req.Test, :container_api}, "abc123", force: true)
    end

    test "handles other errors" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{"message" => "Internal error"}))
      end)

      {:error, {:http_error, 500, _}} =
        ContainerAPI.remove_container({Req.Test, :container_api}, "abc123")
    end
  end

  describe "inspect_container/2" do
    test "returns container info" do
      Req.Test.stub(:container_api, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/containers/abc123/json"

        info = %{
          "Id" => "abc123",
          "State" => %{"Status" => "running"},
          "NetworkSettings" => %{
            "Ports" => %{
              "3000/tcp" => [%{"HostIp" => "0.0.0.0", "HostPort" => "10042"}]
            }
          }
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(info))
      end)

      {:ok, info} = ContainerAPI.inspect_container({Req.Test, :container_api}, "abc123")
      assert info["State"]["Status"] == "running"
      assert info["NetworkSettings"]["Ports"]["3000/tcp"] != nil
    end

    test "handles not found (404)" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"message" => "No such container"}))
      end)

      {:error, :not_found} = ContainerAPI.inspect_container({Req.Test, :container_api}, "missing")
    end

    test "handles other errors" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{"message" => "Internal error"}))
      end)

      {:error, {:http_error, 500, _}} =
        ContainerAPI.inspect_container({Req.Test, :container_api}, "abc123")
    end
  end

  describe "pull_image/2" do
    test "pulls image successfully" do
      Req.Test.stub(:container_api, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/images/create"
        assert conn.query_params["fromImage"] == "myapp:latest"
        send_resp(conn, 200, "")
      end)

      assert :ok = ContainerAPI.pull_image({Req.Test, :container_api}, "myapp:latest")
    end

    test "handles pull error" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"message" => "Image not found"}))
      end)

      {:error, {:http_error, 404, _}} =
        ContainerAPI.pull_image({Req.Test, :container_api}, "nonexistent:latest")
    end
  end

  describe "load_image/2" do
    @tag :tmp_dir
    test "loads image from tarball", %{tmp_dir: tmp_dir} do
      tarball = Path.join(tmp_dir, "image.tar")
      File.write!(tarball, "fake tar data")

      Req.Test.stub(:container_api, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/images/load"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"stream" => "Loaded image: myapp:latest\n"}))
      end)

      {:ok, image} = ContainerAPI.load_image({Req.Test, :container_api}, tarball)
      assert image == "myapp:latest"
    end

    @tag :tmp_dir
    test "parses string response format", %{tmp_dir: tmp_dir} do
      tarball = Path.join(tmp_dir, "image.tar")
      File.write!(tarball, "fake tar data")

      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "Loaded image: other:v2\n")
      end)

      {:ok, image} = ContainerAPI.load_image({Req.Test, :container_api}, tarball)
      assert image == "other:v2"
    end

    test "returns error for non-existent file" do
      {:error, {:file_read_error, :enoent}} =
        ContainerAPI.load_image({Req.Test, :container_api}, "/nonexistent.tar")
    end

    @tag :tmp_dir
    test "handles unparseable response", %{tmp_dir: tmp_dir} do
      tarball = Path.join(tmp_dir, "image.tar")
      File.write!(tarball, "fake tar data")

      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"unexpected" => "format"}))
      end)

      {:error, :could_not_parse_image} =
        ContainerAPI.load_image({Req.Test, :container_api}, tarball)
    end

    @tag :tmp_dir
    test "handles load error", %{tmp_dir: tmp_dir} do
      tarball = Path.join(tmp_dir, "image.tar")
      File.write!(tarball, "fake tar data")

      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{"message" => "Load failed"}))
      end)

      {:error, {:http_error, 500, _}} =
        ContainerAPI.load_image({Req.Test, :container_api}, tarball)
    end
  end

  describe "socket detection" do
    test "uses unix_socket for string socket path" do
      result = ContainerAPI.list_containers("/nonexistent/socket.sock")
      assert {:error, %Req.TransportError{reason: :enoent}} = result
    end
  end

  describe "network error handling" do
    test "create_container handles transport errors" do
      Req.Test.stub(:container_api, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      opts = %{image: "img", name: "name", env: %{}, port_bindings: %{}}
      {:error, %Req.TransportError{}} = ContainerAPI.create_container({Req.Test, :container_api}, opts)
    end

    test "start_container handles transport errors" do
      Req.Test.stub(:container_api, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      {:error, %Req.TransportError{}} =
        ContainerAPI.start_container({Req.Test, :container_api}, "abc123")
    end

    test "stop_container handles unexpected status codes" do
      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(409, Jason.encode!(%{"message" => "Conflict"}))
      end)

      {:error, {:http_error, 409, _}} =
        ContainerAPI.stop_container({Req.Test, :container_api}, "abc123")
    end

    test "pull_image handles transport errors" do
      Req.Test.stub(:container_api, fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      {:error, %Req.TransportError{}} =
        ContainerAPI.pull_image({Req.Test, :container_api}, "myapp:latest")
    end

    @tag :tmp_dir
    test "load_image handles transport errors", %{tmp_dir: tmp_dir} do
      tarball = Path.join(tmp_dir, "image.tar")
      File.write!(tarball, "fake tar data")

      Req.Test.stub(:container_api, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      {:error, %Req.TransportError{}} =
        ContainerAPI.load_image({Req.Test, :container_api}, tarball)
    end
  end

  describe "parse_loaded_image edge cases" do
    @tag :tmp_dir
    test "handles string response that doesn't match pattern", %{tmp_dir: tmp_dir} do
      tarball = Path.join(tmp_dir, "image.tar")
      File.write!(tarball, "fake tar data")

      Req.Test.stub(:container_api, fn conn ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "Some random output without image info")
      end)

      {:error, :could_not_parse_image} =
        ContainerAPI.load_image({Req.Test, :container_api}, tarball)
    end
  end
end
