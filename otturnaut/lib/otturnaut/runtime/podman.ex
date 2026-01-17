defmodule Otturnaut.Runtime.Podman do
  @moduledoc """
  Podman runtime implementation using the Podman REST API.

  Communicates with Podman via HTTP over Unix socket (`/run/podman/podman.sock`).
  For Docker, use `Otturnaut.Runtime.Docker` instead.

  The Podman API is Docker-compatible, so this module delegates to the same
  `Otturnaut.Runtime.ContainerAPI` functions as the Docker module, just with
  a different socket path.

  ## Socket Activation

  Podman's API socket may need to be activated:

      # For rootful podman
      sudo systemctl start podman.socket

      # For rootless podman
      systemctl --user start podman.socket

  ## Options

  Most functions accept an `opts` keyword list with:

  - `:api_module` - Module implementing container API. Defaults to `Otturnaut.Runtime.ContainerAPI`.
    Used for testing.

  ## Naming Convention

  Containers are named `otturnaut-{app_id}-{deploy_id}` to enable discovery
  after agent restart.
  """

  @behaviour Otturnaut.Runtime

  alias Otturnaut.Runtime.ContainerAPI

  @socket "/run/podman/podman.sock"
  @otturnaut_prefix "otturnaut-"

  defp api_module(opts), do: Keyword.get(opts, :api_module, ContainerAPI)
  defp socket(opts), do: Keyword.get(opts, :socket, @socket)

  @impl true
  def list_apps(opts \\ []) do
    api = api_module(opts)

    case api.list_containers(socket(opts), filters: %{"name" => [@otturnaut_prefix]}) do
      {:ok, containers} ->
        apps =
          containers
          |> Enum.filter(&otturnaut_container?/1)
          |> Enum.map(&container_to_app_info/1)

        {:ok, apps}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def start(opts) do
    opts_list = if is_map(opts), do: Map.to_list(opts), else: opts
    api = api_module(opts_list)
    sock = socket(opts_list)

    %{
      image: image,
      port: host_port,
      container_port: container_port,
      env: env,
      name: name
    } = Map.new(opts_list)

    create_opts = %{
      image: image,
      name: name,
      env: env,
      port_bindings: %{"#{container_port}/tcp" => host_port}
    }

    with {:ok, container_id} <- api.create_container(sock, create_opts),
         :ok <- api.start_container(sock, container_id) do
      {:ok, container_id}
    end
  end

  @impl true
  def stop(name, opts \\ []) do
    api = api_module(opts)
    api.stop_container(socket(opts), name)
  end

  @impl true
  def remove(name, opts \\ []) do
    api = api_module(opts)
    api.remove_container(socket(opts), name)
  end

  @impl true
  def status(name, opts \\ []) do
    api = api_module(opts)

    case api.inspect_container(socket(opts), name) do
      {:ok, %{"State" => %{"Status" => status_str}}} ->
        {:ok, parse_status(status_str)}

      {:error, :not_found} ->
        {:ok, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_port(name, opts \\ []) do
    api = api_module(opts)

    case api.inspect_container(socket(opts), name) do
      {:ok, info} ->
        extract_host_port(info)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def load_image(tarball_path, opts \\ []) do
    api = api_module(opts)
    api.load_image(socket(opts), tarball_path)
  end

  @impl true
  def build_image(context_path, tag, opts \\ []) do
    opts_list = if is_map(opts), do: Map.to_list(opts), else: opts
    api = api_module(opts_list)
    api.build_image(socket(opts_list), context_path, tag, opts_list)
  end

  # Private helpers (identical to Docker module)

  defp otturnaut_container?(%{names: names}) do
    Enum.any?(names, fn name ->
      name = String.trim_leading(name, "/")
      String.starts_with?(name, @otturnaut_prefix)
    end)
  end

  defp container_to_app_info(%{id: id, names: names, image: image, state: state, ports: ports}) do
    name = names |> List.first() |> String.trim_leading("/")

    %{
      id: extract_app_id(name),
      container_id: id,
      container_name: name,
      status: parse_status(state),
      image: image,
      port: extract_port_from_ports(ports)
    }
  end

  defp extract_app_id(name) do
    case String.split(name, "-", parts: 3) do
      ["otturnaut", app_id, _deploy_id] -> app_id
      ["otturnaut", app_id] -> app_id
      _ -> name
    end
  end

  defp parse_status("running"), do: :running
  defp parse_status("exited"), do: :stopped
  defp parse_status("created"), do: :stopped
  defp parse_status("paused"), do: :stopped
  defp parse_status(_), do: :unknown

  defp extract_port_from_ports(ports) when is_list(ports) do
    case Enum.find(ports, fn p -> Map.has_key?(p, "PublicPort") end) do
      %{"PublicPort" => port} -> port
      _ -> nil
    end
  end

  defp extract_port_from_ports(_), do: nil

  defp extract_host_port(%{"NetworkSettings" => %{"Ports" => ports}}) when is_map(ports) do
    case find_first_host_port(ports) do
      nil -> {:error, :no_port_mapping}
      port -> {:ok, port}
    end
  end

  defp extract_host_port(_), do: {:error, :no_port_mapping}

  defp find_first_host_port(ports) do
    Enum.find_value(ports, fn
      {_container_port, [%{"HostPort" => host_port} | _]} when is_binary(host_port) ->
        String.to_integer(host_port)

      _ ->
        nil
    end)
  end
end
