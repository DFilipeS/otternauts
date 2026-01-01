defmodule Otturnaut.PortManager do
  @moduledoc """
  Manages dynamic port allocation for deployed applications.

  Allocates ports from a configurable range and tracks which ports are in use.
  State is kept in-memory (ETS) and can be rebuilt on startup by querying
  the runtime for active port mappings.

  ## Configuration

  - `:port_range` - `{min, max}` tuple defining the port range (default: `{10000, 20000}`)
  - `:name` - GenServer name (default: `Otturnaut.PortManager`)

  ## Example

      {:ok, port} = PortManager.allocate()
      # => {:ok, 10001}

      :ok = PortManager.release(port)

  """

  use GenServer

  @default_port_range {10_000, 20_000}

  # Client API

  @doc """
  Starts the PortManager.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Allocates an available port from the pool.

  Returns `{:ok, port}` or `{:error, :exhausted}` if no ports are available.
  """
  @spec allocate(GenServer.server()) :: {:ok, pos_integer()} | {:error, :exhausted}
  def allocate(server \\ __MODULE__) do
    GenServer.call(server, :allocate)
  end

  @doc """
  Releases a port back to the pool.
  """
  @spec release(pos_integer(), GenServer.server()) :: :ok
  def release(port, server \\ __MODULE__) when is_integer(port) do
    GenServer.call(server, {:release, port})
  end

  @doc """
  Checks if a port is currently allocated.
  """
  @spec in_use?(pos_integer(), GenServer.server()) :: boolean()
  def in_use?(port, server \\ __MODULE__) when is_integer(port) do
    GenServer.call(server, {:in_use?, port})
  end

  @doc """
  Returns a list of all currently allocated ports.
  """
  @spec list_allocated(GenServer.server()) :: [pos_integer()]
  def list_allocated(server \\ __MODULE__) do
    GenServer.call(server, :list_allocated)
  end

  @doc """
  Marks a port as in use. Used during state recovery to register
  ports discovered from the runtime.
  """
  @spec mark_in_use(pos_integer(), GenServer.server()) :: :ok | {:error, :out_of_range}
  def mark_in_use(port, server \\ __MODULE__) when is_integer(port) do
    GenServer.call(server, {:mark_in_use, port})
  end

  @doc """
  Returns the configured port range.
  """
  @spec get_range(GenServer.server()) :: {pos_integer(), pos_integer()}
  def get_range(server \\ __MODULE__) do
    GenServer.call(server, :get_range)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    {min_port, max_port} = Keyword.get(opts, :port_range, @default_port_range)

    state = %{
      min_port: min_port,
      max_port: max_port,
      allocated: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:allocate, _from, state) do
    case find_available_port(state) do
      {:ok, port} ->
        new_state = %{state | allocated: MapSet.put(state.allocated, port)}
        {:reply, {:ok, port}, new_state}

      :error ->
        {:reply, {:error, :exhausted}, state}
    end
  end

  def handle_call({:release, port}, _from, state) do
    new_state = %{state | allocated: MapSet.delete(state.allocated, port)}
    {:reply, :ok, new_state}
  end

  def handle_call({:in_use?, port}, _from, state) do
    {:reply, MapSet.member?(state.allocated, port), state}
  end

  def handle_call(:list_allocated, _from, state) do
    {:reply, MapSet.to_list(state.allocated), state}
  end

  def handle_call({:mark_in_use, port}, _from, state) do
    if port >= state.min_port and port <= state.max_port do
      new_state = %{state | allocated: MapSet.put(state.allocated, port)}
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :out_of_range}, state}
    end
  end

  def handle_call(:get_range, _from, state) do
    {:reply, {state.min_port, state.max_port}, state}
  end

  # Private functions

  defp find_available_port(state) do
    # Try random ports first for better distribution. There is probably a 
    # more clever way of finding an open network port, but for now this
    # should be good enough.
    case find_random_port(state, 10) do
      {:ok, port} -> {:ok, port}
      :error -> find_sequential_port(state)
    end
  end

  defp find_random_port(_state, 0), do: :error

  defp find_random_port(state, attempts) do
    port = Enum.random(state.min_port..state.max_port)

    if MapSet.member?(state.allocated, port) do
      find_random_port(state, attempts - 1)
    else
      {:ok, port}
    end
  end

  defp find_sequential_port(state) do
    state.min_port..state.max_port
    |> Enum.find(fn port -> not MapSet.member?(state.allocated, port) end)
    |> case do
      nil -> :error
      port -> {:ok, port}
    end
  end
end
