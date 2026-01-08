defmodule Otturnaut.Deployment.Steps.AllocatePortTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment.Steps.AllocatePort

  defmodule MockPortManager do
    def allocate do
      port = Process.get(:next_port, 10000)
      Process.put(:next_port, port + 1)
      Process.put({:allocated, port}, true)
      {:ok, port}
    end

    def release(port) do
      Process.delete({:allocated, port})
      :ok
    end
  end

  defmodule FailingPortManager do
    def allocate, do: {:error, :exhausted}
  end

  describe "run/3" do
    test "allocates a port successfully" do
      arguments = %{port_manager: MockPortManager}

      assert {:ok, port} = AllocatePort.run(arguments, %{}, [])
      assert is_integer(port)
    end

    test "returns error when port allocation fails" do
      arguments = %{port_manager: FailingPortManager}

      assert {:error, {:port_allocation_failed, :exhausted}} =
               AllocatePort.run(arguments, %{}, [])
    end
  end

  describe "undo/4" do
    test "releases the allocated port" do
      Process.put({:allocated, 10000}, true)
      arguments = %{port_manager: MockPortManager}

      assert :ok = AllocatePort.undo(10000, arguments, %{}, [])

      refute Process.get({:allocated, 10000})
    end
  end
end
