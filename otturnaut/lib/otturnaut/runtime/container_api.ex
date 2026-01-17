defmodule Otturnaut.Runtime.ContainerAPI do
  @moduledoc """
  HTTP client for Docker/Podman REST API over Unix socket.

  This module handles HTTP I/O over Unix sockets and is tested via integration
  with actual Docker/Podman daemons. Unit tests mock this module at the
  consumer level (Docker/Podman runtime modules).

  Both Docker and Podman expose a compatible REST API over Unix sockets.
  This module provides low-level HTTP operations that runtime modules
  (`Otturnaut.Runtime.Docker`, `Otturnaut.Runtime.Podman`) delegate to.

  ## Socket Paths

  - Docker: `/var/run/docker.sock`
  - Podman: `/run/podman/podman.sock`

  ## API Reference

  - Docker Engine API: https://docs.docker.com/engine/api/
  - Podman API: https://docs.podman.io/en/latest/_static/api.html
  """

  @type socket_path :: String.t()
  @type container_id :: String.t()

  @type container_info :: %{
          id: String.t(),
          names: [String.t()],
          image: String.t(),
          state: String.t(),
          status: String.t(),
          ports: [map()]
        }

  @type create_opts :: %{
          image: String.t(),
          name: String.t(),
          env: map(),
          port_bindings: %{String.t() => pos_integer()}
        }

  @doc """
  Lists all containers, optionally filtered by name prefix.
  """
  @spec list_containers(socket_path(), keyword()) ::
          {:ok, [container_info()]} | {:error, term()}
  def list_containers(socket, opts \\ []) do
    filters = Keyword.get(opts, :filters, %{})
    query = if map_size(filters) > 0, do: [filters: Jason.encode!(filters)], else: []

    case get(socket, "/containers/json", query: [all: true] ++ query) do
      {:ok, %{status: 200, body: containers}} ->
        {:ok, Enum.map(containers, &normalize_container/1)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a new container without starting it.
  """
  @spec create_container(socket_path(), create_opts()) ::
          {:ok, container_id()} | {:error, term()}
  def create_container(socket, opts) do
    %{image: image, name: name, env: env, port_bindings: port_bindings} = opts

    env_list = Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)

    exposed_ports =
      port_bindings
      |> Map.keys()
      |> Map.new(fn port -> {port, %{}} end)

    host_config_bindings =
      Map.new(port_bindings, fn {container_port, host_port} ->
        {container_port, [%{"HostIp" => "0.0.0.0", "HostPort" => to_string(host_port)}]}
      end)

    body = %{
      "Image" => image,
      "Env" => env_list,
      "ExposedPorts" => exposed_ports,
      "HostConfig" => %{
        "PortBindings" => host_config_bindings
      }
    }

    case post(socket, "/containers/create", query: [name: name], json: body) do
      {:ok, %{status: 201, body: %{"Id" => id}}} ->
        {:ok, id}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts a stopped container.
  """
  @spec start_container(socket_path(), container_id()) :: :ok | {:error, term()}
  def start_container(socket, container_id) do
    case post(socket, "/containers/#{container_id}/start") do
      {:ok, %{status: status}} when status in [204, 304] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops a running container.
  """
  @spec stop_container(socket_path(), container_id(), keyword()) :: :ok | {:error, term()}
  def stop_container(socket, container_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10)

    case post(socket, "/containers/#{container_id}/stop", query: [t: timeout]) do
      {:ok, %{status: status}} when status in [204, 304] ->
        :ok

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes a container.
  """
  @spec remove_container(socket_path(), container_id(), keyword()) :: :ok | {:error, term()}
  def remove_container(socket, container_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    query = if force, do: [force: true], else: []

    case delete(socket, "/containers/#{container_id}", query: query) do
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Inspects a container to get detailed information.
  """
  @spec inspect_container(socket_path(), container_id()) ::
          {:ok, map()} | {:error, term()}
  def inspect_container(socket, container_id) do
    case get(socket, "/containers/#{container_id}/json") do
      {:ok, %{status: 200, body: info}} ->
        {:ok, info}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Pulls an image from a registry.
  """
  @spec pull_image(socket_path(), String.t()) :: :ok | {:error, term()}
  def pull_image(socket, image) do
    case post(socket, "/images/create", query: [fromImage: image]) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds an image from a build context directory.

  ## Options

  - `:dockerfile` - Path to Dockerfile (default: "Dockerfile" in context)
  - `:build_args` - Map of build arguments
  - `:timeout` - Build timeout in milliseconds (default: 10 minutes)
  """
  @spec build_image(socket_path(), Path.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def build_image(socket, context_path, tag, opts \\ []) do
    dockerfile = Keyword.get(opts, :dockerfile)
    build_args = Keyword.get(opts, :build_args, %{})
    timeout = Keyword.get(opts, :timeout, :timer.minutes(10))

    dockerfile_param =
      if dockerfile do
        Path.relative_to(dockerfile, context_path)
      else
        "Dockerfile"
      end

    with {:ok, tarball} <- create_build_context_tarball(context_path) do
      query =
        [t: tag, dockerfile: dockerfile_param] ++
          Enum.flat_map(build_args, fn {k, v} -> [buildargs: Jason.encode!(%{k => v})] end)

      case post(socket, "/build",
             query: query,
             body: tarball,
             headers: [{"content-type", "application/x-tar"}],
             req_opts: [receive_timeout: timeout]
           ) do
        {:ok, %{status: 200, body: body}} ->
          parse_build_response(body, tag)

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create_build_context_tarball(context_path) do
    tarball_path = Path.join(System.tmp_dir!(), "otturnaut-build-#{System.unique_integer([:positive])}.tar")

    args = ["-cf", tarball_path, "-C", context_path, "."]

    case System.cmd("tar", args, stderr_to_stdout: true) do
      {_output, 0} ->
        case File.read(tarball_path) do
          {:ok, data} ->
            File.rm(tarball_path)
            {:ok, data}

          {:error, reason} ->
            {:error, {:tarball_read_failed, reason}}
        end

      {output, code} ->
        {:error, {:tarball_create_failed, code, output}}
    end
  end

  defp parse_build_response(body, tag) when is_binary(body) do
    if String.contains?(body, "error") do
      {:error, {:build_error, body}}
    else
      {:ok, tag}
    end
  end

  defp parse_build_response(body, tag) when is_list(body) do
    error =
      Enum.find_value(body, fn
        %{"error" => err} -> err
        %{"errorDetail" => %{"message" => msg}} -> msg
        _ -> nil
      end)

    if error do
      {:error, {:build_error, error}}
    else
      {:ok, tag}
    end
  end

  defp parse_build_response(_body, tag), do: {:ok, tag}

  @doc """
  Loads an image from a tarball.
  """
  @spec load_image(socket_path(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def load_image(socket, tarball_path) do
    case File.read(tarball_path) do
      {:ok, data} ->
        case post(socket, "/images/load", body: data, headers: [{"content-type", "application/x-tar"}]) do
          {:ok, %{status: 200, body: body}} ->
            parse_loaded_image(body)

          {:ok, %{status: status, body: body}} ->
            {:error, {:http_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  # HTTP helpers

  defp get(socket, path, opts \\ []) do
    request(:get, socket, path, opts)
  end

  defp post(socket, path, opts \\ []) do
    request(:post, socket, path, opts)
  end

  defp delete(socket, path, opts) do
    request(:delete, socket, path, opts)
  end

  defp request(method, socket, path, opts) do
    req_opts = Keyword.get(opts, :req_opts, [])
    query = Keyword.get(opts, :query, [])
    json = Keyword.get(opts, :json)
    body = Keyword.get(opts, :body)
    headers = Keyword.get(opts, :headers, [])

    url = "http://localhost#{path}"

    base_opts =
      if is_tuple(socket) and elem(socket, 0) == Req.Test do
        [plug: socket]
      else
        [unix_socket: socket]
      end

    req =
      Req.new([method: method, url: url, retry: false] ++ base_opts)
      |> Req.merge(req_opts)

    req =
      if query != [] do
        Req.merge(req, params: query)
      else
        req
      end

    req =
      cond do
        json != nil -> Req.merge(req, json: json)
        body != nil -> Req.merge(req, body: body, headers: headers)
        true -> req
      end

    case Req.request(req) do
      {:ok, response} ->
        {:ok, response}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Normalization helpers

  defp normalize_container(container) do
    %{
      id: container["Id"],
      names: container["Names"] || [],
      image: container["Image"],
      state: container["State"],
      status: container["Status"],
      ports: container["Ports"] || []
    }
  end

  defp parse_loaded_image(body) when is_binary(body) do
    case Regex.run(~r/Loaded image: (.+)/, body) do
      [_, image] -> {:ok, String.trim(image)}
      _ -> {:error, :could_not_parse_image}
    end
  end

  defp parse_loaded_image(%{"stream" => stream}) do
    parse_loaded_image(stream)
  end

  defp parse_loaded_image(_), do: {:error, :could_not_parse_image}
end
