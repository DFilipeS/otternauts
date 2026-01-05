defmodule Otturnaut.Runtime.Docker do
  @moduledoc """
  Docker runtime implementation.

  Manages Docker containers for deployed applications. Uses the `docker` CLI
  (or a compatible alternative like `podman`) via the `Otturnaut.Command` module.

  ## Options

  Most functions accept an `opts` keyword list or map with:

  - `:binary` - The container CLI binary to use. Defaults to `"docker"`.
    Set to `"podman"` for Podman compatibility.
  - `:command_module` - Module for executing commands. Defaults to `Otturnaut.Command`.
    Used for testing.

  ## Naming Convention

  Containers are named `otturnaut-{app_id}-{deploy_id}` to enable discovery
  after agent restart.

  ## Example

      # Using Podman instead of Docker
      Otturnaut.Runtime.Docker.list_apps(binary: "podman")

      # In deployment context
      context = %{
        runtime: Otturnaut.Runtime.Docker,
        runtime_opts: [binary: "podman"],
        ...
      }

  """

  @behaviour Otturnaut.Runtime

  alias Otturnaut.Command
  alias Otturnaut.Command.Result

  @otturnaut_prefix "otturnaut-"

  @default_binary "docker"

  # Allow injecting a different command module for testing
  defp command_module(opts) when is_list(opts), do: Keyword.get(opts, :command_module, Command)
  defp command_module(opts) when is_map(opts), do: Map.get(opts, :command_module, Command)

  # Allow configuring the binary (docker, podman, etc.)
  defp binary(opts) when is_list(opts), do: Keyword.get(opts, :binary, @default_binary)
  defp binary(opts) when is_map(opts), do: Map.get(opts, :binary, @default_binary)

  @impl true
  def list_apps(opts \\ []) do
    format = "{{.Names}}\t{{.ID}}\t{{.State}}\t{{.Image}}\t{{.Ports}}"
    cmd = command_module(opts)

    case cmd.run(binary(opts), [
           "ps",
           "-a",
           "--filter",
           "name=#{@otturnaut_prefix}",
           "--format",
           format
         ]) do
      %Result{status: :ok, output: output} ->
        apps = parse_container_list(output)
        {:ok, apps}

      %Result{status: :error, error: error} ->
        {:error, error}
    end
  end

  @impl true
  def start(opts) do
    %{
      image: image,
      port: host_port,
      container_port: container_port,
      env: env,
      name: name
    } = opts

    cmd = command_module(opts)

    args =
      ["run", "-d", "--name", name, "-p", "#{host_port}:#{container_port}"] ++
        build_env_args(env) ++
        [image]

    case cmd.run(binary(opts), args) do
      %Result{status: :ok, output: container_id} ->
        {:ok, String.trim(container_id)}

      %Result{status: :error, output: output, error: error} ->
        {:error, {error, output}}
    end
  end

  @impl true
  def stop(name, opts \\ []) do
    cmd = command_module(opts)

    case cmd.run(binary(opts), ["stop", name]) do
      %Result{status: :ok} -> :ok
      %Result{status: :error, error: error, output: output} -> {:error, {error, output}}
    end
  end

  @impl true
  def remove(name, opts \\ []) do
    cmd = command_module(opts)

    case cmd.run(binary(opts), ["rm", name]) do
      %Result{status: :ok} -> :ok
      %Result{status: :error, error: error, output: output} -> {:error, {error, output}}
    end
  end

  @impl true
  def status(name, opts \\ []) do
    cmd = command_module(opts)

    case cmd.run(binary(opts), ["inspect", "-f", "{{.State.Status}}", name]) do
      %Result{status: :ok, output: output} ->
        status =
          case String.trim(output) do
            "running" -> :running
            "exited" -> :stopped
            "created" -> :stopped
            "paused" -> :stopped
            _ -> :unknown
          end

        {:ok, status}

      %Result{status: :error, error: {:exit, 1}} ->
        # Docker returns exit code 1 for "no such container"
        {:ok, :not_found}

      %Result{status: :error, error: {:exit, 125}} ->
        # Podman returns exit code 125 for "no such object"
        {:ok, :not_found}

      %Result{status: :error, error: error} ->
        {:error, error}
    end
  end

  @impl true
  def get_port(name, opts \\ []) do
    cmd = command_module(opts)

    # Get the first host port mapping
    case cmd.run(binary(opts), ["port", name]) do
      %Result{status: :ok, output: output} ->
        case parse_port_output(output) do
          {:ok, port} -> {:ok, port}
          :error -> {:error, :no_port_mapping}
        end

      %Result{status: :error, error: error} ->
        {:error, error}
    end
  end

  @impl true
  def load_image(tarball_path, opts \\ []) do
    cmd = command_module(opts)

    case cmd.run(binary(opts), ["load", "-i", tarball_path]) do
      %Result{status: :ok, output: output} ->
        # Output is like "Loaded image: myapp:latest"
        case Regex.run(~r/Loaded image: (.+)/, output) do
          [_, image] -> {:ok, String.trim(image)}
          _ -> {:error, :could_not_parse_image}
        end

      %Result{status: :error, error: error, output: output} ->
        {:error, {error, output}}
    end
  end

  @impl true
  def build_image(context_path, tag, opts \\ []) do
    cmd = command_module(opts)
    dockerfile = Keyword.get(opts, :dockerfile, "Dockerfile")
    build_args = Keyword.get(opts, :build_args, %{})
    subscriber = Keyword.get(opts, :subscriber)
    timeout = Keyword.get(opts, :timeout, :timer.minutes(10))

    args =
      ["build", "-t", tag, "-f", dockerfile] ++
        build_build_args(build_args) ++
        [context_path]

    if subscriber do
      # Async build with streaming
      {:ok, pid} = cmd.run_async(binary(opts), args, subscriber: subscriber, timeout: timeout)
      {:ok, pid}
    else
      # Sync build
      case cmd.run(binary(opts), args, timeout: timeout) do
        %Result{status: :ok} -> {:ok, tag}
        %Result{status: :error, error: error, output: output} -> {:error, {error, output}}
      end
    end
  end

  # Helper functions

  defp build_env_args(env) when is_map(env) do
    Enum.flat_map(env, fn {key, value} ->
      ["-e", "#{key}=#{value}"]
    end)
  end

  defp build_build_args(build_args) when is_map(build_args) do
    Enum.flat_map(build_args, fn {key, value} ->
      ["--build-arg", "#{key}=#{value}"]
    end)
  end

  defp parse_container_list(output) do
    output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_container_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_container_line(line) do
    case String.split(line, "\t") do
      [name, container_id, state, image, ports] ->
        %{
          id: extract_app_id(name),
          container_id: container_id,
          container_name: name,
          status: parse_state(state),
          image: image,
          port: parse_host_port(ports)
        }

      _ ->
        nil
    end
  end

  defp extract_app_id(name) do
    # otturnaut-myapp-abc123 -> myapp
    case String.split(name, "-", parts: 3) do
      ["otturnaut", app_id, _deploy_id] -> app_id
      ["otturnaut", app_id] -> app_id
      _ -> name
    end
  end

  defp parse_state("running"), do: :running
  defp parse_state("exited"), do: :stopped
  defp parse_state(_), do: :unknown

  defp parse_host_port(ports_string) do
    # Format: "0.0.0.0:10042->3000/tcp" or multiple mappings
    case Regex.run(~r/0\.0\.0\.0:(\d+)->/, ports_string) do
      [_, port] -> String.to_integer(port)
      _ -> nil
    end
  end

  defp parse_port_output(output) do
    # Format: "3000/tcp -> 0.0.0.0:10042"
    case Regex.run(~r/-> 0\.0\.0\.0:(\d+)/, output) do
      [_, port] -> {:ok, String.to_integer(port)}
      _ -> :error
    end
  end
end
