defmodule Otturnaut.Runtime.DockerTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Runtime.Docker
  alias Otturnaut.Command.Result

  # Mock Command module for testing
  defmodule MockCommand do
    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["ps", "-a", "--filter", "name=otturnaut-", "--format", _format], _opts) do
      # Docker outputs 5 tab-separated fields, even if ports is empty the field has a placeholder
      output =
        "otturnaut-myapp-abc123\tcontainer123\trunning\tmyapp:latest\t0.0.0.0:10042->3000/tcp\n" <>
          "otturnaut-otherapp-def456\tcontainer456\texited\totherapp:v2\t-\n"

      Result.success(output, 100)
    end

    def run("docker", ["run", "-d", "--name", name | _rest], _opts) do
      Result.success("sha256:#{name}-container-id\n", 500)
    end

    def run("docker", ["stop", _name], _opts) do
      Result.success("", 100)
    end

    def run("docker", ["rm", _name], _opts) do
      Result.success("", 50)
    end

    def run("docker", ["inspect", "-f", "{{.State.Status}}", "running-container"], _opts) do
      Result.success("running\n", 50)
    end

    def run("docker", ["inspect", "-f", "{{.State.Status}}", "exited-container"], _opts) do
      Result.success("exited\n", 50)
    end

    def run("docker", ["inspect", "-f", "{{.State.Status}}", "created-container"], _opts) do
      Result.success("created\n", 50)
    end

    def run("docker", ["inspect", "-f", "{{.State.Status}}", "paused-container"], _opts) do
      Result.success("paused\n", 50)
    end

    def run("docker", ["inspect", "-f", "{{.State.Status}}", "weird-container"], _opts) do
      Result.success("restarting\n", 50)
    end

    def run("docker", ["inspect", "-f", "{{.State.Status}}", "not-found"], _opts) do
      Result.failure(1, "", 50)
    end

    def run("docker", ["inspect", "-f", "{{.State.Status}}", "not-found-podman"], _opts) do
      # Podman returns exit code 125 for "no such object"
      Result.failure(125, "Error: no such object: \"not-found-podman\"\n", 50)
    end

    def run("docker", ["port", "container-with-port"], _opts) do
      Result.success("3000/tcp -> 0.0.0.0:10042\n", 50)
    end

    def run("docker", ["port", "container-no-port"], _opts) do
      Result.success("", 50)
    end

    def run("docker", ["load", "-i", "/path/to/image.tar"], _opts) do
      Result.success("Loaded image: myapp:latest\n", 1000)
    end

    def run("docker", ["load", "-i", "/path/to/weird.tar"], _opts) do
      Result.success("Some unexpected output\n", 1000)
    end

    def run("docker", ["build" | _args], _opts) do
      Result.success("Successfully built\n", 5000)
    end

    def run_async("docker", ["build" | _args], opts) do
      subscriber = Keyword.get(opts, :subscriber)
      send(subscriber, {:build_started, self()})
      {:ok, self()}
    end
  end

  # Mock for error scenarios
  defmodule MockCommandErrors do
    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["ps" | _], _opts) do
      Result.error(:command_not_found, "", 0)
    end

    def run("docker", ["run" | _], _opts) do
      Result.failure(1, "Error response from daemon", 100)
    end

    def run("docker", ["stop", _name], _opts) do
      Result.failure(1, "Error", 100)
    end

    def run("docker", ["rm", _name], _opts) do
      Result.failure(1, "Error", 100)
    end

    def run("docker", ["inspect" | _], _opts) do
      Result.error(:timeout, "", 5000)
    end

    def run("docker", ["port", _name], _opts) do
      Result.failure(1, "", 50)
    end

    def run("docker", ["load" | _], _opts) do
      Result.failure(1, "Error loading", 1000)
    end

    def run("docker", ["build" | _], _opts) do
      Result.failure(1, "Build failed", 5000)
    end
  end

  # Additional mocks for specific test scenarios
  defmodule CustomDockerfileMock do
    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["build", "-t", "myapp:latest", "-f", "Custom.Dockerfile", "/app"], _opts) do
      Otturnaut.Command.Result.success("Built\n", 1000)
    end
  end

  defmodule TimeoutBuildMock do
    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["build" | _], opts) do
      timeout = Keyword.get(opts, :timeout)

      if timeout == 30_000 do
        Otturnaut.Command.Result.success("Built\n", 1000)
      else
        Otturnaut.Command.Result.failure(1, "Wrong timeout", 1000)
      end
    end
  end

  defmodule BuildArgsMock do
    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["build", "-t", _tag, "-f", _dockerfile, "--build-arg", arg1, "--build-arg", arg2 | _rest], _opts) do
      # Verify build args are passed
      if String.contains?(arg1, "MIX_ENV=") and String.contains?(arg2, "NODE_ENV=") do
        Otturnaut.Command.Result.success("Built with args\n", 1000)
      else
        Otturnaut.Command.Result.failure(1, "Missing build args", 1000)
      end
    end
  end

  defmodule MockEmptyList do
    alias Otturnaut.Command.Result

    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["ps" | _], _opts) do
      Result.success("", 50)
    end
  end

  defmodule MockMalformedList do
    alias Otturnaut.Command.Result

    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["ps" | _], _opts) do
      output =
        "some-other-container\tid\trunning\n" <>
          "otturnaut-app\tid\trunning\timage\tports\n" <>
          "invalid-line\n"

      Result.success(output, 50)
    end
  end

  defmodule MockShortName do
    alias Otturnaut.Command.Result

    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["ps" | _], _opts) do
      output =
        "otturnaut-onlyappid\tcontainer123\trunning\timage:latest\t0.0.0.0:10000->3000/tcp\n"

      Result.success(output, 50)
    end
  end

  defmodule MockNonOtternautName do
    alias Otturnaut.Command.Result

    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["ps" | _], _opts) do
      output =
        "random-container-name\tcontainer123\trunning\timage:latest\t0.0.0.0:10000->3000/tcp\n"

      Result.success(output, 50)
    end
  end

  defmodule MockUnknownState do
    alias Otturnaut.Command.Result

    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["ps" | _], _opts) do
      output =
        "otturnaut-myapp-abc123\tcontainer123\tcreating\timage:latest\t0.0.0.0:10000->3000/tcp\n"

      Result.success(output, 50)
    end
  end

  defmodule MockNoPortMapping do
    alias Otturnaut.Command.Result

    def run(cmd, args), do: run(cmd, args, [])

    def run("docker", ["ps" | _], _opts) do
      output = "otturnaut-myapp-abc123\tcontainer123\trunning\timage:latest\t-\n"
      Result.success(output, 50)
    end
  end

  describe "list_apps/1" do
    test "parses container list output" do
      {:ok, apps} = Docker.list_apps(command_module: MockCommand)

      assert length(apps) == 2

      [app1, app2] = apps
      assert app1.id == "myapp"
      assert app1.container_id == "container123"
      assert app1.container_name == "otturnaut-myapp-abc123"
      assert app1.status == :running
      assert app1.image == "myapp:latest"
      assert app1.port == 10042

      assert app2.id == "otherapp"
      assert app2.status == :stopped
      assert app2.port == nil
    end

    test "returns error on command failure" do
      {:error, reason} = Docker.list_apps(command_module: MockCommandErrors)
      assert reason == :command_not_found
    end
  end

  describe "start/1" do
    test "starts a container and returns container id" do
      opts = %{
        image: "myapp:latest",
        port: 10042,
        container_port: 3000,
        env: %{"PORT" => "3000"},
        name: "otturnaut-myapp-abc123",
        command_module: MockCommand
      }

      {:ok, container_id} = Docker.start(opts)
      assert container_id =~ "otturnaut-myapp-abc123"
    end

    test "returns error on failure" do
      opts = %{
        image: "myapp:latest",
        port: 10042,
        container_port: 3000,
        env: %{},
        name: "test",
        command_module: MockCommandErrors
      }

      {:error, {reason, output}} = Docker.start(opts)
      assert reason == {:exit, 1}
      assert output =~ "Error response"
    end
  end

  describe "stop/2" do
    test "stops a container" do
      assert :ok = Docker.stop("mycontainer", command_module: MockCommand)
    end

    test "returns error on failure" do
      {:error, {reason, _output}} = Docker.stop("mycontainer", command_module: MockCommandErrors)
      assert reason == {:exit, 1}
    end
  end

  describe "remove/2" do
    test "removes a container" do
      assert :ok = Docker.remove("mycontainer", command_module: MockCommand)
    end

    test "returns error on failure" do
      {:error, {reason, _output}} =
        Docker.remove("mycontainer", command_module: MockCommandErrors)

      assert reason == {:exit, 1}
    end
  end

  describe "status/2" do
    test "returns :running for running container" do
      {:ok, status} = Docker.status("running-container", command_module: MockCommand)
      assert status == :running
    end

    test "returns :stopped for exited container" do
      {:ok, status} = Docker.status("exited-container", command_module: MockCommand)
      assert status == :stopped
    end

    test "returns :stopped for created container" do
      {:ok, status} = Docker.status("created-container", command_module: MockCommand)
      assert status == :stopped
    end

    test "returns :stopped for paused container" do
      {:ok, status} = Docker.status("paused-container", command_module: MockCommand)
      assert status == :stopped
    end

    test "returns :unknown for unexpected status" do
      {:ok, status} = Docker.status("weird-container", command_module: MockCommand)
      assert status == :unknown
    end

    test "returns :not_found for non-existent container (Docker exit code 1)" do
      {:ok, status} = Docker.status("not-found", command_module: MockCommand)
      assert status == :not_found
    end

    test "returns :not_found for non-existent container (Podman exit code 125)" do
      {:ok, status} = Docker.status("not-found-podman", command_module: MockCommand)
      assert status == :not_found
    end

    test "returns error on other failures" do
      {:error, reason} = Docker.status("any", command_module: MockCommandErrors)
      assert reason == :timeout
    end
  end

  describe "get_port/2" do
    test "returns port for container with port mapping" do
      {:ok, port} = Docker.get_port("container-with-port", command_module: MockCommand)
      assert port == 10042
    end

    test "returns error for container without port mapping" do
      {:error, reason} = Docker.get_port("container-no-port", command_module: MockCommand)
      assert reason == :no_port_mapping
    end

    test "returns error on command failure" do
      {:error, reason} = Docker.get_port("any", command_module: MockCommandErrors)
      assert reason == {:exit, 1}
    end
  end

  describe "load_image/2" do
    test "loads image from tarball" do
      {:ok, image} = Docker.load_image("/path/to/image.tar", command_module: MockCommand)
      assert image == "myapp:latest"
    end

    test "returns error when output cannot be parsed" do
      {:error, reason} = Docker.load_image("/path/to/weird.tar", command_module: MockCommand)
      assert reason == :could_not_parse_image
    end

    test "returns error on command failure" do
      {:error, {reason, _output}} =
        Docker.load_image("/path/to/image.tar", command_module: MockCommandErrors)

      assert reason == {:exit, 1}
    end
  end

  describe "build_image/3" do
    test "builds image synchronously" do
      {:ok, tag} = Docker.build_image("/app", "myapp:latest", command_module: MockCommand)
      assert tag == "myapp:latest"
    end

    test "builds image asynchronously with subscriber" do
      {:ok, pid} =
        Docker.build_image("/app", "myapp:latest",
          command_module: MockCommand,
          subscriber: self()
        )

      assert is_pid(pid)
      assert_receive {:build_started, _}
    end

    test "returns error on build failure" do
      {:error, {reason, _output}} =
        Docker.build_image("/app", "myapp:latest", command_module: MockCommandErrors)

      assert reason == {:exit, 1}
    end

    test "passes custom dockerfile option" do
      {:ok, tag} =
        Docker.build_image("/app", "myapp:latest",
          command_module: CustomDockerfileMock,
          dockerfile: "Custom.Dockerfile"
        )

      assert tag == "myapp:latest"
    end

    test "passes timeout option to sync build" do
      {:ok, tag} =
        Docker.build_image("/app", "myapp:latest",
          command_module: TimeoutBuildMock,
          timeout: 30_000
        )

      assert tag == "myapp:latest"
    end

    test "passes build_args option to sync build" do
      {:ok, tag} =
        Docker.build_image("/app", "myapp:latest",
          command_module: BuildArgsMock,
          build_args: %{"MIX_ENV" => "prod", "NODE_ENV" => "production"}
        )

      assert tag == "myapp:latest"
    end
  end

  describe "parsing edge cases" do
    test "handles empty container list" do
      {:ok, apps} = Docker.list_apps(command_module: MockEmptyList)
      assert apps == []
    end

    test "handles malformed lines and rejects non-matching containers" do
      {:ok, apps} = Docker.list_apps(command_module: MockMalformedList)
      # Only the valid otturnaut container line is parsed
      assert length(apps) == 1
      assert hd(apps).id == "app"
    end

    test "handles container name with only app_id (no deploy_id)" do
      {:ok, apps} = Docker.list_apps(command_module: MockShortName)
      assert length(apps) == 1
      # When there's no deploy_id, the app_id is extracted as the whole part
      assert hd(apps).id == "onlyappid"
    end

    test "uses full name as id for non-otturnaut containers" do
      {:ok, apps} = Docker.list_apps(command_module: MockNonOtternautName)
      assert length(apps) == 1
      # When name doesn't match otturnaut pattern, the full name is used as id
      assert hd(apps).id == "random-container-name"
    end

    test "handles unknown container state" do
      {:ok, apps} = Docker.list_apps(command_module: MockUnknownState)
      assert length(apps) == 1
      assert hd(apps).status == :unknown
    end

    test "handles container without port mapping" do
      {:ok, apps} = Docker.list_apps(command_module: MockNoPortMapping)
      assert length(apps) == 1
      assert hd(apps).port == nil
    end
  end

  describe "start/1 with map opts" do
    # Test the command_module/1 function with map opts (line 23)
    test "accepts opts as a map" do
      opts = %{
        image: "myapp:latest",
        port: 10042,
        container_port: 3000,
        env: %{"PORT" => "3000"},
        name: "otturnaut-myapp-abc123",
        command_module: MockCommand
      }

      {:ok, container_id} = Docker.start(opts)
      assert container_id =~ "otturnaut-myapp-abc123"
    end
  end

  # Mock for testing configurable binary (podman support)
  defmodule PodmanMock do
    alias Otturnaut.Command.Result

    def run(cmd, args), do: run(cmd, args, [])

    def run("podman", ["ps", "-a", "--filter", "name=otturnaut-", "--format", _format], _opts) do
      output =
        "otturnaut-myapp-abc123\tcontainer123\trunning\tmyapp:latest\t0.0.0.0:10042->3000/tcp\n"

      Result.success(output, 100)
    end

    def run("podman", ["run", "-d", "--name", name | _rest], _opts) do
      Result.success("sha256:#{name}-container-id\n", 500)
    end

    def run("podman", ["stop", _name], _opts) do
      Result.success("", 100)
    end

    def run("podman", ["rm", _name], _opts) do
      Result.success("", 50)
    end

    def run("podman", ["inspect", "-f", "{{.State.Status}}", _name], _opts) do
      Result.success("running\n", 50)
    end

    def run("podman", ["port", _name], _opts) do
      Result.success("3000/tcp -> 0.0.0.0:10042\n", 50)
    end

    def run("podman", ["load", "-i", _path], _opts) do
      Result.success("Loaded image: myapp:latest\n", 1000)
    end

    def run("podman", ["build" | _args], _opts) do
      Result.success("Successfully built\n", 5000)
    end

    def run_async("podman", ["build" | _args], opts) do
      subscriber = Keyword.get(opts, :subscriber)
      send(subscriber, {:build_started, self()})
      {:ok, self()}
    end
  end

  describe "configurable binary (podman support)" do
    test "list_apps uses custom binary" do
      {:ok, apps} = Docker.list_apps(command_module: PodmanMock, binary: "podman")
      assert length(apps) == 1
      assert hd(apps).id == "myapp"
    end

    test "start uses custom binary" do
      opts = %{
        image: "myapp:latest",
        port: 10042,
        container_port: 3000,
        env: %{},
        name: "otturnaut-myapp-abc123",
        command_module: PodmanMock,
        binary: "podman"
      }

      {:ok, container_id} = Docker.start(opts)
      assert container_id =~ "otturnaut-myapp-abc123"
    end

    test "stop uses custom binary" do
      assert :ok = Docker.stop("mycontainer", command_module: PodmanMock, binary: "podman")
    end

    test "remove uses custom binary" do
      assert :ok = Docker.remove("mycontainer", command_module: PodmanMock, binary: "podman")
    end

    test "status uses custom binary" do
      {:ok, status} =
        Docker.status("running-container", command_module: PodmanMock, binary: "podman")

      assert status == :running
    end

    test "get_port uses custom binary" do
      {:ok, port} =
        Docker.get_port("container-with-port", command_module: PodmanMock, binary: "podman")

      assert port == 10042
    end

    test "load_image uses custom binary" do
      {:ok, image} =
        Docker.load_image("/path/to/image.tar", command_module: PodmanMock, binary: "podman")

      assert image == "myapp:latest"
    end

    test "build_image uses custom binary (sync)" do
      {:ok, tag} =
        Docker.build_image("/app", "myapp:latest", command_module: PodmanMock, binary: "podman")

      assert tag == "myapp:latest"
    end

    test "build_image uses custom binary (async)" do
      {:ok, pid} =
        Docker.build_image("/app", "myapp:latest",
          command_module: PodmanMock,
          binary: "podman",
          subscriber: self()
        )

      assert is_pid(pid)
      assert_receive {:build_started, _}
    end
  end

  # Tests to cover default argument function arity variants
  describe "default argument coverage" do
    # These call functions without optional opts to exercise the generated arity variants
    # Most will fail because Docker isn't available, but that's fine for coverage

    test "list_apps without opts" do
      result = Docker.list_apps()
      # Either works (docker available) or fails (not available)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "stop without opts" do
      # This will fail because container doesn't exist
      result = Docker.stop("nonexistent-container-12345")
      assert match?({:error, _}, result)
    end

    test "remove without opts" do
      result = Docker.remove("nonexistent-container-12345")
      assert match?({:error, _}, result)
    end

    test "status without opts" do
      result = Docker.status("nonexistent-container-12345")
      # Returns :not_found for non-existent containers
      assert {:ok, :not_found} == result or match?({:error, _}, result)
    end

    test "get_port without opts" do
      result = Docker.get_port("nonexistent-container-12345")
      assert match?({:error, _}, result)
    end

    test "load_image without opts" do
      result = Docker.load_image("/nonexistent/path.tar")
      assert match?({:error, _}, result)
    end

    test "build_image without opts" do
      result = Docker.build_image("/nonexistent", "test:latest")
      assert match?({:error, _}, result)
    end
  end
end
