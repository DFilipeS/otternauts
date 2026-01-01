defmodule Otturnaut.CommandTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Otturnaut.Command
  alias Otturnaut.Command.Result
  alias Otturnaut.Command.PortWrapper

  setup do
    # Ensure the application is started (may have been stopped by other tests)
    {:ok, _} = Application.ensure_all_started(:otturnaut)
    :ok
  end

  describe "run/3 (sync)" do
    test "executes a command and returns output" do
      result = Command.run("echo", ["hello", "world"])

      assert %Result{status: :ok} = result
      assert result.exit_code == 0
      assert result.output == "hello world\n"
      assert result.duration_ms >= 0
    end

    test "captures multiline output" do
      result = Command.run("printf", ["line1\\nline2\\nline3\\n"])

      assert result.status == :ok
      assert result.output == "line1\nline2\nline3\n"
    end

    test "returns failure for non-zero exit code" do
      result = Command.run("sh", ["-c", "exit 42"])

      assert result.status == :error
      assert result.exit_code == 42
      assert result.error == {:exit, 42}
    end

    test "returns error for command not found" do
      result = Command.run("nonexistent_command_12345", [])

      assert result.status == :error
      assert result.error == :command_not_found
    end

    test "respects working_dir option" do
      result = Command.run("pwd", [], working_dir: "/tmp")

      assert result.status == :ok
      assert String.trim(result.output) == "/tmp"
    end

    test "respects timeout option" do
      result = Command.run("sleep", ["10"], timeout: 100)

      assert result.status == :error
      assert result.error == :timeout
      assert result.duration_ms >= 100
    end

    test "handles empty output" do
      result = Command.run("true", [])

      assert result.status == :ok
      assert result.output == ""
    end

    test "handles infinity timeout" do
      result = Command.run("echo", ["quick"], timeout: :infinity)

      assert result.status == :ok
      assert result.output == "quick\n"
    end

    test "handles output exceeding line buffer (noeol case)" do
      # Generate a line longer than the buffer size (10KB) to trigger noeol handling
      # The buffer size is 10 * 1024 = 10240 bytes
      # Use a command that outputs a very long line
      long_string = String.duplicate("x", 15_000)
      result = Command.run("printf", [long_string])

      assert result.status == :ok
      # Output is captured even though it exceeds the line buffer
      # The noeol case handles partial lines
      assert String.length(result.output) > 0
    end
  end

  describe "run_async/3" do
    test "returns {:ok, pid} immediately" do
      assert {:ok, pid} = Command.run_async("echo", ["test"])
      assert is_pid(pid)

      # Clean up by receiving the messages
      receive do
        {:command_output, ^pid, _} -> :ok
      after
        100 -> :ok
      end

      receive do
        {:command_done, ^pid, _} -> :ok
      after
        100 -> :ok
      end
    end

    test "streams output to subscriber" do
      {:ok, pid} = Command.run_async("echo", ["hello"])

      assert_receive {:command_output, ^pid, {:stdout, "hello"}}, 1000
      assert_receive {:command_done, ^pid, %Result{status: :ok}}, 1000
    end

    test "streams multiple lines" do
      {:ok, pid} = Command.run_async("printf", ["line1\\nline2\\nline3\\n"])

      assert_receive {:command_output, ^pid, {:stdout, "line1"}}, 1000
      assert_receive {:command_output, ^pid, {:stdout, "line2"}}, 1000
      assert_receive {:command_output, ^pid, {:stdout, "line3"}}, 1000
      assert_receive {:command_done, ^pid, %Result{status: :ok}}, 1000
    end

    test "sends done message on failure" do
      {:ok, pid} = Command.run_async("sh", ["-c", "echo error; exit 1"])

      assert_receive {:command_output, ^pid, {:stdout, "error"}}, 1000
      assert_receive {:command_done, ^pid, %Result{status: :error, exit_code: 1}}, 1000
    end

    test "sends done message for command not found" do
      {:ok, pid} = Command.run_async("nonexistent_command_12345", [])

      assert_receive {:command_done, ^pid, %Result{error: :command_not_found}}, 1000
    end

    test "can send to custom subscriber" do
      test_pid = self()
      subscriber = spawn(fn -> forward_messages(test_pid) end)

      {:ok, pid} = Command.run_async("echo", ["custom"], subscriber: subscriber)

      assert_receive {:forwarded, {:command_output, ^pid, {:stdout, "custom"}}}, 1000
      assert_receive {:forwarded, {:command_done, ^pid, %Result{status: :ok}}}, 1000
    end
  end

  describe "cancel/1" do
    test "terminates a running command" do
      {:ok, pid} = Command.run_async("sleep", ["10"])
      ref = Process.monitor(pid)

      :ok = Command.cancel(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000
    end
  end

  # Helper to forward messages from a subscriber process
  defp forward_messages(target) do
    receive do
      msg ->
        send(target, {:forwarded, msg})
        forward_messages(target)
    after
      5000 -> :ok
    end
  end

  describe "default argument coverage" do
    # Test calling run/2 without opts to exercise the default argument path
    test "run with only command and args" do
      result = Command.run("echo", ["hello"])
      assert result.status == :ok
      assert result.output == "hello\n"
    end

    test "Runner.run/2 without opts exercises default argument path" do
      # This directly calls the Runner module's default argument variant
      result = Otturnaut.Command.Runner.run("echo", ["test"])
      assert result.status == :ok
      assert result.output == "test\n"
    end
  end

  describe "port cleanup edge cases" do
    test "handles port already closed when getting os_pid during timeout" do
      # Mock PortWrapper to simulate port already closed before os_pid lookup
      stub(PortWrapper, :info, fn _port, :os_pid -> nil end)
      stub(PortWrapper, :info, fn _port -> nil end)

      # Run a command that will timeout
      result = Command.run("sleep", ["10"], timeout: 50)

      assert result.status == :error
      assert result.error == :timeout
    end

    test "handles ArgumentError when closing port during cleanup" do
      call_count = :counters.new(1, [:atomics])

      # Mock PortWrapper to raise ArgumentError on close (simulating race condition)
      stub(PortWrapper, :info, fn port, :os_pid ->
        # Return real info for the first call (during kill_port)
        Port.info(port, :os_pid)
      end)

      stub(PortWrapper, :info, fn port ->
        # First call returns info, subsequent calls depend on state
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          Port.info(port)
        else
          # Return non-nil to enter the close branch
          [:some_info]
        end
      end)

      stub(PortWrapper, :close, fn _port ->
        # Simulate port already closed - raise ArgumentError
        raise ArgumentError, "argument error"
      end)

      # Run a command that will timeout to trigger cleanup
      result = Command.run("sleep", ["10"], timeout: 50)

      assert result.status == :error
      assert result.error == :timeout
    end
  end

  describe "PortWrapper direct usage" do
    # These tests exercise the real PortWrapper functions for coverage
    test "info/1 returns port info for open port" do
      port = Port.open({:spawn, "cat"}, [:binary])

      info = PortWrapper.info(port)
      assert is_list(info)
      assert Keyword.has_key?(info, :name)

      Port.close(port)
    end

    test "info/2 returns specific port info" do
      port = Port.open({:spawn, "cat"}, [:binary])

      {:os_pid, os_pid} = PortWrapper.info(port, :os_pid)
      assert is_integer(os_pid)

      Port.close(port)
    end

    test "close/1 closes a port" do
      port = Port.open({:spawn, "cat"}, [:binary])

      assert Port.info(port) != nil
      PortWrapper.close(port)
      assert Port.info(port) == nil
    end
  end
end
