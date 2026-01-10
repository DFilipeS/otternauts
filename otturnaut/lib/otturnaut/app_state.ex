defmodule Otturnaut.AppState do
  @moduledoc """
  Manages runtime state for deployed applications.

  State is stored in ETS for fast access and is rebuilt on startup by querying
  the runtime (Docker, systemd, etc.). This keeps the agent stateless - no
  persistence required.

  ## State Structure

  Each app has:
  - `id` - Application identifier
  - `deployment_id` - Current deployment ID
  - `container_name` - Full container/service name
  - `port` - Host port the app is listening on
  - `domains` - List of domains routed to this app
  - `status` - Current status (:running, :stopped, :deploying)

  ## Example

      # Register a new app
      AppState.put("myapp", %{
        deployment_id: "abc123",
        container_name: "otturnaut-myapp-abc123",
        port: 10042,
        domains: ["myapp.com"],
        status: :running
      })

      # Get app state
      {:ok, state} = AppState.get("myapp")

      # List all apps
      apps = AppState.list()

  """

  use GenServer

  @type app_id :: String.t()

  @type app :: %{
          deployment_id: String.t(),
          container_name: String.t(),
          port: pos_integer(),
          domains: [String.t()],
          status: :running | :stopped | :deploying
        }

  # Client API

  @doc """
  Starts the AppState GenServer.

  ## Options
  - `:name` - GenServer name (default: `Otturnaut.AppState`)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stores or updates state for an app.
  """
  @spec put(app_id(), app(), GenServer.server()) :: :ok
  def put(app_id, app, server \\ __MODULE__) when is_binary(app_id) and is_map(app) do
    GenServer.call(server, {:put, app_id, app})
  end

  @doc """
  Gets state for an app.

  Returns `{:ok, app}` or `{:error, :not_found}`.
  """
  @spec get(app_id(), GenServer.server()) :: {:ok, app()} | {:error, :not_found}
  def get(app_id, server \\ __MODULE__) when is_binary(app_id) do
    GenServer.call(server, {:get, app_id})
  end

  @doc """
  Deletes state for an app.
  """
  @spec delete(app_id(), GenServer.server()) :: :ok
  def delete(app_id, server \\ __MODULE__) when is_binary(app_id) do
    GenServer.call(server, {:delete, app_id})
  end

  @doc """
  Lists all apps.

  Returns a list of `{app_id, app}` tuples.
  """
  @spec list(GenServer.server()) :: [{app_id(), app()}]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc """
  Updates a specific field for an app.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec update(app_id(), atom(), term(), GenServer.server()) :: :ok | {:error, :not_found}
  def update(app_id, field, value, server \\ __MODULE__)
      when is_binary(app_id) and is_atom(field) do
    GenServer.call(server, {:update, app_id, field, value})
  end

  @doc """
  Updates the status of an app.
  """
  @spec update_status(app_id(), :running | :stopped | :deploying, GenServer.server()) ::
          :ok | {:error, :not_found}
  def update_status(app_id, status, server \\ __MODULE__) do
    update(app_id, :status, status, server)
  end

  @doc """
  Clears all state. Useful for testing.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(:app_state, [:set, :private])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, app_id, app}, _from, %{table: table} = state) do
    :ets.insert(table, {app_id, app})
    {:reply, :ok, state}
  end

  def handle_call({:get, app_id}, _from, %{table: table} = state) do
    result =
      case :ets.lookup(table, app_id) do
        [{^app_id, app}] -> {:ok, app}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:delete, app_id}, _from, %{table: table} = state) do
    :ets.delete(table, app_id)
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, %{table: table} = state) do
    {:reply, :ets.tab2list(table), state}
  end

  def handle_call({:update, app_id, field, value}, _from, %{table: table} = state) do
    result =
      case :ets.lookup(table, app_id) do
        [{^app_id, app}] ->
          updated_app = Map.put(app, field, value)
          :ets.insert(table, {app_id, updated_app})
          :ok

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call(:clear, _from, %{table: table} = state) do
    :ets.delete_all_objects(table)
    {:reply, :ok, state}
  end
end
