defmodule Otturnaut.Runtime.PodmanTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Runtime.Podman

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

    def inspect_container(_socket, "not-found") do
      {:error, :not_found}
    end

    def load_image(_socket, _path) do
      {:ok, "myapp:latest"}
    end
  end

  describe "list_apps/1" do
    test "returns list of running containers" do
      {:ok, apps} = Podman.list_apps(api_module: MockContainerAPI)

      assert length(apps) == 1
      [app] = apps
      assert app.id == "myapp"
      assert app.status == :running
      assert app.port == 10042
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

      {:ok, container_id} = Podman.start(opts)
      assert container_id =~ "otturnaut-myapp-abc123"
    end
  end

  describe "stop/2" do
    test "stops container" do
      assert :ok = Podman.stop("mycontainer", api_module: MockContainerAPI)
    end
  end

  describe "remove/2" do
    test "removes container" do
      assert :ok = Podman.remove("mycontainer", api_module: MockContainerAPI)
    end
  end

  describe "status/2" do
    test "returns :running for running container" do
      {:ok, status} = Podman.status("running-container", api_module: MockContainerAPI)
      assert status == :running
    end

    test "returns :not_found for non-existent container" do
      {:ok, status} = Podman.status("not-found", api_module: MockContainerAPI)
      assert status == :not_found
    end
  end

  describe "get_port/2" do
    test "returns host port for container" do
      {:ok, port} = Podman.get_port("running-container", api_module: MockContainerAPI)
      assert port == 10042
    end
  end

  describe "load_image/2" do
    test "loads image from tarball" do
      {:ok, image} = Podman.load_image("/path/to/image.tar", api_module: MockContainerAPI)
      assert image == "myapp:latest"
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
        Podman.build_image("/app", "myapp:latest",
          api_module: BuildMockAPI,
          socket: "/test.sock"
        )

      assert tag == "myapp:latest"
      assert_received {:build_image, "/test.sock", "/app", "myapp:latest", _opts}
    end

    test "passes options through" do
      defmodule BuildOptsAPIForPodman do
        def build_image(_socket, _context, tag, opts) do
          send(self(), {:opts, opts})
          {:ok, tag}
        end
      end

      Podman.build_image("/app", "myapp:latest",
        api_module: BuildOptsAPIForPodman,
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
    test "uses /run/podman/podman.sock by default" do
      result = Podman.list_apps()
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

    defmodule MockAPIErrors do
      def list_containers(_socket, _opts \\ []) do
        {:error, :connection_refused}
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

    defmodule MockStatusVariants do
      def list_containers(_socket, _opts \\ []) do
        {:ok,
         [
           %{
             id: "container1",
             names: ["/otturnaut-app1-deploy1"],
             image: "image:latest",
             state: "exited",
             status: "Exited",
             ports: []
           },
           %{
             id: "container2",
             names: ["/otturnaut-app2-deploy2"],
             image: "image:latest",
             state: "created",
             status: "Created",
             ports: []
           },
           %{
             id: "container3",
             names: ["/otturnaut-app3-deploy3"],
             image: "image:latest",
             state: "paused",
             status: "Paused",
             ports: []
           },
           %{
             id: "container4",
             names: ["/otturnaut-app4-deploy4"],
             image: "image:latest",
             state: "restarting",
             status: "Restarting",
             ports: []
           }
         ]}
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

      def inspect_container(_socket, "unknown-container") do
        {:ok, %{"State" => %{"Status" => "restarting"}, "NetworkSettings" => %{"Ports" => %{}}}}
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

      {:error, {:http_error, 500, _}} = Podman.start(opts)
    end

    test "get_port returns error when NetworkSettings is missing" do
      {:error, :no_port_mapping} =
        Podman.get_port("no-network-settings", api_module: MockExtractPortEdgeCases)
    end

    test "get_port returns error when Ports is empty map" do
      {:error, :no_port_mapping} =
        Podman.get_port("empty-port-bindings", api_module: MockExtractPortEdgeCases)
    end

    test "get_port returns error when port binding is nil" do
      {:error, :no_port_mapping} =
        Podman.get_port("null-port-binding", api_module: MockExtractPortEdgeCases)
    end

    test "get_port returns error when port binding is empty array" do
      {:error, :no_port_mapping} =
        Podman.get_port("empty-array-port-binding", api_module: MockExtractPortEdgeCases)
    end

    test "extract_port_from_ports handles non-list ports" do
      {:ok, apps} = Podman.list_apps(api_module: MockNonListPorts)
      assert length(apps) == 1
      assert hd(apps).port == nil
    end

    test "list_apps returns error on API failure" do
      {:error, :connection_refused} = Podman.list_apps(api_module: MockAPIErrors)
    end

    test "stop returns error when container not found" do
      {:error, :not_found} = Podman.stop("mycontainer", api_module: MockAPIErrors)
    end

    test "remove returns error when container not found" do
      {:error, :not_found} = Podman.remove("mycontainer", api_module: MockAPIErrors)
    end

    test "status returns error on API failure" do
      {:error, :connection_refused} = Podman.status("any", api_module: MockAPIErrors)
    end

    test "get_port returns error on API failure" do
      {:error, :connection_refused} = Podman.get_port("any", api_module: MockAPIErrors)
    end

    test "load_image returns error on API failure" do
      {:error, {:http_error, 500, _}} =
        Podman.load_image("/path/to/image.tar", api_module: MockAPIErrors)
    end

    test "handles container name with only app_id (no deploy_id)" do
      {:ok, apps} = Podman.list_apps(api_module: MockShortName)
      assert length(apps) == 1
      assert hd(apps).id == "onlyappid"
    end

    test "filters out non-otturnaut containers" do
      {:ok, apps} = Podman.list_apps(api_module: MockNonOtturnautContainers)
      assert length(apps) == 1
      assert hd(apps).id == "myapp"
    end

    test "handles various container states in list_apps" do
      {:ok, apps} = Podman.list_apps(api_module: MockStatusVariants)
      assert length(apps) == 4
      statuses = Enum.map(apps, & &1.status)
      assert :stopped in statuses
      assert :unknown in statuses
    end

    test "status returns :stopped for exited container" do
      {:ok, status} = Podman.status("exited-container", api_module: MockStatusVariants)
      assert status == :stopped
    end

    test "status returns :stopped for created container" do
      {:ok, status} = Podman.status("created-container", api_module: MockStatusVariants)
      assert status == :stopped
    end

    test "status returns :stopped for paused container" do
      {:ok, status} = Podman.status("paused-container", api_module: MockStatusVariants)
      assert status == :stopped
    end

    test "status returns :unknown for unexpected states" do
      {:ok, status} = Podman.status("unknown-container", api_module: MockStatusVariants)
      assert status == :unknown
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
      {:ok, apps} = Podman.list_apps(api_module: MockMultipleNamesFirstNonOtturnaut)
      assert length(apps) == 1
      assert hd(apps).id == "random-alias"
    end
  end

  describe "1-arity function coverage" do
    test "stop/1 without opts (exercises default argument)" do
      result = Podman.stop("nonexistent-container-12345")
      assert match?({:error, _}, result)
    end

    test "remove/1 without opts (exercises default argument)" do
      result = Podman.remove("nonexistent-container-12345")
      assert match?({:error, _}, result)
    end

    test "status/1 without opts (exercises default argument)" do
      result = Podman.status("nonexistent-container-12345")
      assert match?({:error, _}, result) or match?({:ok, :not_found}, result)
    end

    test "get_port/1 without opts (exercises default argument)" do
      result = Podman.get_port("nonexistent-container-12345")
      assert match?({:error, _}, result)
    end

    test "load_image/1 without opts (exercises default argument)" do
      result = Podman.load_image("/nonexistent/path.tar")
      assert match?({:error, _}, result)
    end
  end
end
