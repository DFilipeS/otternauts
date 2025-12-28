defmodule Otturnaut.CommandTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Command
  alias Otturnaut.Command.Result

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
end
