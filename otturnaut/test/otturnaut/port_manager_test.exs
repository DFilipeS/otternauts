defmodule Otturnaut.PortManagerTest do
  @moduledoc """
  Tests for Otturnaut.PortManager using isolated, uniquely-named server instances.

  These tests run async (concurrently) because each test starts its own server
  with a unique name, avoiding shared state conflicts.

  Default argument coverage tests (e.g., `PortManager.allocate/0` without the server param)
  are in `port_manager_default_args_test.exs` - those must run synchronously because
  they use the global `Otturnaut.PortManager` server to exercise the default arg paths.
  """
  use ExUnit.Case, async: true

  alias Otturnaut.PortManager

  # Use a small range for testing
  @test_range {50000, 50010}

  setup do
    # Start a uniquely named instance for this test
    server_name = :"port_manager_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = PortManager.start_link(name: server_name, port_range: @test_range)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, server: server_name}
  end

  describe "allocate/0" do
    test "allocates a port from the range", %{server: server} do
      assert {:ok, port} = PortManager.allocate(server)
      assert port >= 50000 and port <= 50010
    end

    test "allocated ports are marked as in use", %{server: server} do
      {:ok, port} = PortManager.allocate(server)
      assert PortManager.in_use?(port, server)
    end

    test "does not allocate the same port twice", %{server: server} do
      {:ok, port1} = PortManager.allocate(server)
      {:ok, port2} = PortManager.allocate(server)
      assert port1 != port2
    end

    test "returns error when all ports are exhausted", %{server: server} do
      # Allocate all 11 ports (50000-50010)
      for _ <- 1..11 do
        assert {:ok, _port} = PortManager.allocate(server)
      end

      assert {:error, :exhausted} = PortManager.allocate(server)
    end
  end

  describe "release/1" do
    test "releases a port back to the pool", %{server: server} do
      {:ok, port} = PortManager.allocate(server)
      assert PortManager.in_use?(port, server)

      :ok = PortManager.release(port, server)
      refute PortManager.in_use?(port, server)
    end

    test "released port can be allocated again", %{server: server} do
      {:ok, port} = PortManager.allocate(server)
      :ok = PortManager.release(port, server)

      # Should be able to allocate again
      assert {:ok, _} = PortManager.allocate(server)
    end
  end

  describe "in_use?/1" do
    test "returns false for unallocated port", %{server: server} do
      refute PortManager.in_use?(50005, server)
    end

    test "returns true for allocated port", %{server: server} do
      {:ok, port} = PortManager.allocate(server)
      assert PortManager.in_use?(port, server)
    end
  end

  describe "list_allocated/0" do
    test "returns empty list initially", %{server: server} do
      assert PortManager.list_allocated(server) == []
    end

    test "returns all allocated ports", %{server: server} do
      {:ok, port1} = PortManager.allocate(server)
      {:ok, port2} = PortManager.allocate(server)

      allocated = PortManager.list_allocated(server)
      assert length(allocated) == 2
      assert port1 in allocated
      assert port2 in allocated
    end
  end

  describe "mark_in_use/1" do
    test "marks a port as in use", %{server: server} do
      refute PortManager.in_use?(50005, server)

      :ok = PortManager.mark_in_use(50005, server)

      assert PortManager.in_use?(50005, server)
    end

    test "returns error for port outside range", %{server: server} do
      assert {:error, :out_of_range} = PortManager.mark_in_use(9999, server)
      assert {:error, :out_of_range} = PortManager.mark_in_use(60000, server)
    end

    test "prevents allocation of marked port", %{server: server} do
      # Mark most ports as in use
      for port <- 50000..50009 do
        PortManager.mark_in_use(port, server)
      end

      # Only 50010 should be available
      {:ok, port} = PortManager.allocate(server)
      assert port == 50010

      # Now exhausted
      assert {:error, :exhausted} = PortManager.allocate(server)
    end
  end

  describe "get_range/0" do
    test "returns the configured port range", %{server: server} do
      assert PortManager.get_range(server) == @test_range
    end
  end

  describe "sequential port fallback" do
    test "falls back to sequential allocation when random fails repeatedly", %{server: server} do
      # Allocate all but one port to maximize chance of random failure
      # With 10/11 ports allocated, random has ~39% chance of failing 10 times
      # Running multiple allocate/release cycles should eventually trigger sequential
      for port <- 50000..50009 do
        PortManager.mark_in_use(port, server)
      end

      # Now only port 50010 is free
      # Random selection will likely hit allocated ports multiple times
      # Eventually triggering the sequential fallback
      {:ok, port} = PortManager.allocate(server)
      # Sequential would find this
      assert port == 50010

      # Release and try again multiple times to increase coverage
      PortManager.release(port, server)

      # Do several allocation cycles
      for _ <- 1..5 do
        {:ok, p} = PortManager.allocate(server)
        assert p == 50010
        PortManager.release(p, server)
      end
    end
  end
end
