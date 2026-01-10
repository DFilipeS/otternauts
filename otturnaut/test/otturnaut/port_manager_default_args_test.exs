defmodule Otturnaut.PortManagerDefaultArgsTest do
  @moduledoc """
  Tests for default argument coverage of PortManager functions.
  These tests use the globally named server and must run synchronously.
  """
  use ExUnit.Case, async: false

  alias Otturnaut.PortManager

  # Test start_link default args separately since it changes server configuration
  describe "start_link default arguments" do
    test "start_link without opts uses default configuration" do
      # Stop existing default server
      if pid = Process.whereis(PortManager) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      # Start without opts - uses default port range
      case PortManager.start_link() do
        {:ok, pid} ->
          assert is_pid(pid)
          assert Process.whereis(PortManager) == pid
          # Verify default range
          assert PortManager.get_range() == {10_000, 20_000}

        {:error, {:already_started, pid}} ->
          # Another process started it between stop and start
          assert is_pid(pid)
      end
    end
  end

  # Test other default args with a controlled port range
  describe "function default arguments" do
    setup do
      # Ensure the default named server is running with test range
      ensure_server_with_range({60000, 60010})

      on_exit(fn ->
        # Safely release any allocated ports if server still exists
        if pid = Process.whereis(PortManager) do
          try do
            for port <- PortManager.list_allocated(pid) do
              PortManager.release(port, pid)
            end
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok
    end

    test "allocate/0 with default server" do
      # Get the current range to validate against it
      {min, max} = PortManager.get_range()
      assert {:ok, port} = PortManager.allocate()
      assert port >= min and port <= max
    end

    test "release/1 with default server" do
      {:ok, port} = PortManager.allocate()
      assert :ok = PortManager.release(port)
    end

    test "in_use?/1 with default server" do
      {:ok, port} = PortManager.allocate()
      assert PortManager.in_use?(port)
      PortManager.release(port)
      refute PortManager.in_use?(port)
    end

    test "list_allocated/0 with default server" do
      {:ok, port} = PortManager.allocate()
      assert port in PortManager.list_allocated()
      PortManager.release(port)
    end

    test "get_range/0 with default server" do
      {min, max} = PortManager.get_range()
      assert is_integer(min)
      assert is_integer(max)
    end
  end

  defp ensure_server_with_range(port_range) do
    case Process.whereis(PortManager) do
      nil ->
        case PortManager.start_link(port_range: port_range) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      pid ->
        # Stop and restart with the required range
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

        case PortManager.start_link(port_range: port_range) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
    end
  end
end
