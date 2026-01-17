defmodule Otturnaut.Runtime.DockerTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Runtime.Docker

  defmodule MockContainerAPI do
    def list_containers(_socket, _opts \\ []) do
      containers = [
        %{
          id: "container123abc",
          names: ["/otturnaut-myapp-abc123"],
          image: "myapp:latest",
          state: "running",
          status: "Up 2 hours",
          ports: [%{"PublicPort" => 10042, "PrivatePort" => 3000}]
        },
        %{
          id: "container456def",
          names: ["/otturnaut-otherapp-def456"],
          image: "otherapp:v2",
          state: "exited",
          status: "Exited (0) 1 hour ago",
          ports: []
        }
      ]

      {:ok, containers}
    end

    def create_container(_socket, %{name: name}) do
      {:ok, "sha256:#{name}-container-id"}
    end

    def start_container(_socket, _container_id) do
      :ok
    end

    def stop_container(_socket, _container_id, _opts \\ []) do
      :ok
    end

    def remove_container(_socket, _container_id, _opts \\ []) do
      :ok
    end

    def inspect_container(_socket, "running-container") do
      {:ok,
       %{
         "State" => %{"Status" => "running"},
         "NetworkSettings" => %{
           "Ports" => %{
             "3000/tcp" => [%{"HostIp" => "0.0.0.0", "HostPort" => "10042"}]
           }
         }
       }}
    end

    def inspect_container(_socket, "exited-container") do
      {:ok, %{"State" => %{"Status" => "exited"}, "NetworkSettings" => %{"Ports" => %{}}}}
    end

    def inspect_container(_socket, "created-container") do
      {:ok, %{"State" => %{"Status" => "created"}, "NetworkSettings" => %{"Ports" => %{}}}}
    end

    def inspect_container(_socket, "paused-container") do
      {:ok, %{"State" => %{"Status" => "paused"}, "NetworkSettings" => %{"Ports" => %{}}}}
    end

    def inspect_container(_socket, "weird-container") do
      {:ok, %{"State" => %{"Status" => "restarting"}, "NetworkSettings" => %{"Ports" => %{}}}}
    end

    def inspect_container(_socket, "not-found") do
      {:error, :not_found}
    end

    def inspect_container(_socket, "container-with-port") do
      {:ok,
       %{
         "State" => %{"Status" => "running"},
         "NetworkSettings" => %{
           "Ports" => %{
             "3000/tcp" => [%{"HostIp" => "0.0.0.0", "HostPort" => "10042"}]
           }
         }
       }}
    end

    def inspect_container(_socket, "container-no-port") do
      {:ok, %{"State" => %{"Status" => "running"}, "NetworkSettings" => %{"Ports" => %{}}}}
    end

    def load_image(_socket, "/path/to/image.tar") do
      {:ok, "myapp:latest"}
    end

    def load_image(_socket, "/path/to/weird.tar") do
      {:error, :could_not_parse_image}
    end
  end

  defmodule MockContainerAPIErrors do
    def list_containers(_socket, _opts \\ []) do
      {:error, :connection_refused}
    end

    def create_container(_socket, _opts) do
      {:error, {:http_error, 500, "Internal server error"}}
    end

    def stop_container(_socket, _container_id, _opts \\ []) do
      {:error, :not_found}
    end

    def remove_container(_socket, _container_id, _opts \\ []) do
      {:error, :not_found}
    end

    def inspect_container(_socket, _name) do
      {:error, :connection_refused}
    end

    def load_image(_socket, _path) do
      {:error, {:http_error, 500, "Load failed"}}
    end
  end

  defmodule MockEmptyList do
    def list_containers(_socket, _opts \\ []) do
      {:ok, []}
    end
  end

  defmodule MockNoPortMapping do
    def list_containers(_socket, _opts \\ []) do
      {:ok,
       [
         %{
           id: "container123",
           names: ["/otturnaut-myapp-abc123"],
           image: "image:latest",
           state: "running",
           status: "Up",
           ports: []
         }
       ]}
    end
  end

  defmodule MockNonOtturnautContainers do
    def list_containers(_socket, _opts \\ []) do
      {:ok,
       [
         %{
           id: "container123",
           names: ["/random-container"],
           image: "image:latest",
           state: "running",
           status: "Up",
           ports: []
         },
         %{
           id: "container456",
           names: ["/otturnaut-myapp-abc123"],
           image: "myapp:latest",
           state: "running",
           status: "Up",
           ports: []
         }
       ]}
    end
  end

  defmodule MockShortName do
    def list_containers(_socket, _opts \\ []) do
      {:ok,
       [
         %{
           id: "container123",
           names: ["/otturnaut-onlyappid"],
           image: "image:latest",
           state: "running",
           status: "Up",
           ports: [%{"PublicPort" => 10000}]
         }
       ]}
    end
  end

  defmodule MockUnknownState do
    def list_containers(_socket, _opts \\ []) do
      {:ok,
       [
         %{
           id: "container123",
           names: ["/otturnaut-myapp-abc123"],
           image: "image:latest",
           state: "creating",
           status: "Creating",
           ports: []
         }
       ]}
    end
  end

  describe "list_apps/1" do
    test "returns list of running containers" do
      {:ok, apps} = Docker.list_apps(api_module: MockContainerAPI)

      assert length(apps) == 2

      [app1, app2] = apps
      assert app1.id == "myapp"
      assert app1.container_id == "container123abc"
      assert app1.status == :running
      assert app1.port == 10042
      assert app1.image == "myapp:latest"

      assert app2.id == "otherapp"
      assert app2.status == :stopped
    end

    test "returns error on API failure" do
      {:error, reason} = Docker.list_apps(api_module: MockContainerAPIErrors)
      assert reason == :connection_refused
    end

    test "handles empty container list" do
      {:ok, apps} = Docker.list_apps(api_module: MockEmptyList)
      assert apps == []
    end

    test "filters out non-otturnaut containers" do
      {:ok, apps} = Docker.list_apps(api_module: MockNonOtturnautContainers)
      assert length(apps) == 1
      assert hd(apps).id == "myapp"
    end

    test "handles container name with only app_id (no deploy_id)" do
      {:ok, apps} = Docker.list_apps(api_module: MockShortName)
      assert length(apps) == 1
      assert hd(apps).id == "onlyappid"
    end

    test "handles unknown container state" do
      {:ok, apps} = Docker.list_apps(api_module: MockUnknownState)
      assert length(apps) == 1
      assert hd(apps).status == :unknown
    end

    test "handles container without port mapping" do
      {:ok, apps} = Docker.list_apps(api_module: MockNoPortMapping)
      assert length(apps) == 1
      assert hd(apps).port == nil
    end
  end

  describe "start/1" do
    test "creates and starts container" do
      opts = %{
        image: "myapp:latest",
        port: 10042,
        container_port: 3000,
        env: %{"PORT" => "3000"},
        name: "otturnaut-myapp-abc123",
        api_module: MockContainerAPI
      }

      {:ok, container_id} = Docker.start(opts)
      assert container_id =~ "otturnaut-myapp-abc123"
    end

    test "accepts opts as keyword list" do
      opts = [
        image: "myapp:latest",
        port: 10042,
        container_port: 3000,
        env: %{"PORT" => "3000"},
        name: "otturnaut-myapp-abc123",
        api_module: MockContainerAPI
      ]

      {:ok, container_id} = Docker.start(opts)
      assert container_id =~ "otturnaut-myapp-abc123"
    end

    test "returns error on API failure" do
      opts = %{
        image: "myapp:latest",
        port: 10042,
        container_port: 3000,
        env: %{},
        name: "otturnaut-myapp-abc123",
        api_module: MockContainerAPIErrors
      }

      {:error, reason} = Docker.start(opts)
      assert match?({:http_error, 500, _}, reason)
    end
  end

  describe "stop/2" do
    test "stops container" do
      assert :ok = Docker.stop("mycontainer", api_module: MockContainerAPI)
    end

    test "returns error when container not found" do
      {:error, :not_found} = Docker.stop("mycontainer", api_module: MockContainerAPIErrors)
    end
  end

  describe "remove/2" do
    test "removes container" do
      assert :ok = Docker.remove("mycontainer", api_module: MockContainerAPI)
    end

    test "returns error when container not found" do
      {:error, :not_found} = Docker.remove("mycontainer", api_module: MockContainerAPIErrors)
    end
  end

  describe "status/2" do
    test "returns :running for running container" do
      {:ok, status} = Docker.status("running-container", api_module: MockContainerAPI)
      assert status == :running
    end

    test "returns :stopped for exited container" do
      {:ok, status} = Docker.status("exited-container", api_module: MockContainerAPI)
      assert status == :stopped
    end

    test "returns :stopped for created container" do
      {:ok, status} = Docker.status("created-container", api_module: MockContainerAPI)
      assert status == :stopped
    end

    test "returns :stopped for paused container" do
      {:ok, status} = Docker.status("paused-container", api_module: MockContainerAPI)
      assert status == :stopped
    end

    test "returns :unknown for unexpected states" do
      {:ok, status} = Docker.status("weird-container", api_module: MockContainerAPI)
      assert status == :unknown
    end

    test "returns :not_found for non-existent container" do
      {:ok, status} = Docker.status("not-found", api_module: MockContainerAPI)
      assert status == :not_found
    end

    test "returns error on API failure" do
      {:error, reason} = Docker.status("any", api_module: MockContainerAPIErrors)
      assert reason == :connection_refused
    end
  end

  describe "get_port/2" do
    test "returns host port for container" do
      {:ok, port} = Docker.get_port("container-with-port", api_module: MockContainerAPI)
      assert port == 10042
    end

    test "returns error when no port mapping" do
      {:error, :no_port_mapping} = Docker.get_port("container-no-port", api_module: MockContainerAPI)
    end

    test "returns error on API failure" do
      {:error, reason} = Docker.get_port("any", api_module: MockContainerAPIErrors)
      assert reason == :connection_refused
    end
  end

  describe "load_image/2" do
    test "loads image from tarball" do
      {:ok, image} = Docker.load_image("/path/to/image.tar", api_module: MockContainerAPI)
      assert image == "myapp:latest"
    end

    test "returns error when image parsing fails" do
      {:error, :could_not_parse_image} =
        Docker.load_image("/path/to/weird.tar", api_module: MockContainerAPI)
    end

    test "returns error on API failure" do
      {:error, reason} =
        Docker.load_image("/path/to/image.tar", api_module: MockContainerAPIErrors)

      assert match?({:http_error, 500, _}, reason)
    end
  end

  describe "build_image/3" do
    test "delegates to ContainerAPI" do
      defmodule BuildMockAPI do
        def build_image(socket, context, tag, opts) do
          send(self(), {:build_image, socket, context, tag, opts})
          {:ok, tag}
        end
      end

      {:ok, tag} =
        Docker.build_image("/app", "myapp:latest",
          api_module: BuildMockAPI,
          socket: "/test.sock"
        )

      assert tag == "myapp:latest"
      assert_received {:build_image, "/test.sock", "/app", "myapp:latest", _opts}
    end

    test "passes options through" do
      defmodule BuildOptsAPI do
        def build_image(_socket, _context, tag, opts) do
          send(self(), {:opts, opts})
          {:ok, tag}
        end
      end

      Docker.build_image("/app", "myapp:latest",
        api_module: BuildOptsAPI,
        socket: "/test.sock",
        dockerfile: "/app/Custom.Dockerfile",
        build_args: %{"FOO" => "bar"}
      )

      assert_received {:opts, opts}
      assert opts[:dockerfile] == "/app/Custom.Dockerfile"
      assert opts[:build_args] == %{"FOO" => "bar"}
    end
  end

  describe "default socket path" do
    test "uses /var/run/docker.sock by default" do
      result = Docker.list_apps()
      assert match?({:error, _}, result)
    end
  end

  describe "edge cases" do
    defmodule MockStartFailsOnStart do
      def create_container(_socket, %{name: name}) do
        {:ok, "sha256:#{name}-container-id"}
      end

      def start_container(_socket, _container_id) do
        {:error, {:http_error, 500, "Container failed to start"}}
      end
    end

    defmodule MockExtractPortEdgeCases do
      def inspect_container(_socket, "no-network-settings") do
        {:ok, %{"State" => %{"Status" => "running"}}}
      end

      def inspect_container(_socket, "empty-port-bindings") do
        {:ok,
         %{
           "State" => %{"Status" => "running"},
           "NetworkSettings" => %{"Ports" => %{}}
         }}
      end

      def inspect_container(_socket, "null-port-binding") do
        {:ok,
         %{
           "State" => %{"Status" => "running"},
           "NetworkSettings" => %{
             "Ports" => %{
               "3000/tcp" => nil
             }
           }
         }}
      end

      def inspect_container(_socket, "empty-array-port-binding") do
        {:ok,
         %{
           "State" => %{"Status" => "running"},
           "NetworkSettings" => %{
             "Ports" => %{
               "3000/tcp" => []
             }
           }
         }}
      end
    end

    defmodule MockNonListPorts do
      def list_containers(_socket, _opts \\ []) do
        {:ok,
         [
           %{
             id: "container123",
             names: ["/otturnaut-myapp-abc123"],
             image: "image:latest",
             state: "running",
             status: "Up",
             ports: "not-a-list"
           }
         ]}
      end
    end

    test "start returns error when start_container fails" do
      opts = %{
        image: "myapp:latest",
        port: 10042,
        container_port: 3000,
        env: %{},
        name: "otturnaut-myapp-abc123",
        api_module: MockStartFailsOnStart
      }

      {:error, {:http_error, 500, _}} = Docker.start(opts)
    end

    test "get_port returns error when NetworkSettings is missing" do
      {:error, :no_port_mapping} =
        Docker.get_port("no-network-settings", api_module: MockExtractPortEdgeCases)
    end

    test "get_port returns error when Ports is empty map" do
      {:error, :no_port_mapping} =
        Docker.get_port("empty-port-bindings", api_module: MockExtractPortEdgeCases)
    end

    test "get_port returns error when port binding is nil" do
      {:error, :no_port_mapping} =
        Docker.get_port("null-port-binding", api_module: MockExtractPortEdgeCases)
    end

    test "get_port returns error when port binding is empty array" do
      {:error, :no_port_mapping} =
        Docker.get_port("empty-array-port-binding", api_module: MockExtractPortEdgeCases)
    end

    test "extract_port_from_ports handles non-list ports" do
      {:ok, apps} = Docker.list_apps(api_module: MockNonListPorts)
      assert length(apps) == 1
      assert hd(apps).port == nil
    end

    defmodule MockMultipleNamesFirstNonOtturnaut do
      def list_containers(_socket, _opts \\ []) do
        {:ok,
         [
           %{
             id: "container123",
             names: ["/random-alias", "/otturnaut-myapp-deploy1"],
             image: "image:latest",
             state: "running",
             status: "Up",
             ports: []
           }
         ]}
      end
    end

    test "extract_app_id uses full name when first name doesn't match otturnaut pattern" do
      {:ok, apps} = Docker.list_apps(api_module: MockMultipleNamesFirstNonOtturnaut)
      assert length(apps) == 1
      assert hd(apps).id == "random-alias"
    end
  end

  describe "1-arity function coverage" do
    test "stop/1 without opts (exercises default argument)" do
      result = Docker.stop("nonexistent-container-12345")
      assert match?({:error, _}, result)
    end

    test "remove/1 without opts (exercises default argument)" do
      result = Docker.remove("nonexistent-container-12345")
      assert match?({:error, _}, result)
    end

    test "status/1 without opts (exercises default argument)" do
      result = Docker.status("nonexistent-container-12345")
      assert match?({:error, _}, result) or match?({:ok, :not_found}, result)
    end

    test "get_port/1 without opts (exercises default argument)" do
      result = Docker.get_port("nonexistent-container-12345")
      assert match?({:error, _}, result)
    end

    test "load_image/1 without opts (exercises default argument)" do
      result = Docker.load_image("/nonexistent/path.tar")
      assert match?({:error, _}, result)
    end
  end
end
