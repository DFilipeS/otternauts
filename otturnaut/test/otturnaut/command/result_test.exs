defmodule Otturnaut.Command.ResultTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Command.Result

  describe "success/2" do
    test "creates a successful result" do
      result = Result.success("output", 100)

      assert result.status == :ok
      assert result.exit_code == 0
      assert result.output == "output"
      assert result.error == nil
      assert result.duration_ms == 100
    end
  end

  describe "failure/3" do
    test "creates a failure result with exit code" do
      result = Result.failure(1, "error output", 50)

      assert result.status == :error
      assert result.exit_code == 1
      assert result.output == "error output"
      assert result.error == {:exit, 1}
      assert result.duration_ms == 50
    end
  end

  describe "error/3" do
    test "creates a failure result with error reason" do
      result = Result.error(:timeout, "partial output", 5000)

      assert result.status == :error
      assert result.exit_code == nil
      assert result.output == "partial output"
      assert result.error == :timeout
      assert result.duration_ms == 5000
    end

    test "handles command_not_found" do
      result = Result.error(:command_not_found, "", 0)

      assert result.status == :error
      assert result.error == :command_not_found
    end

    test "handles runner_crashed" do
      result = Result.error(:runner_crashed, "partial", 100)

      assert result.status == :error
      assert result.error == :runner_crashed
    end
  end

  describe "ok?/1" do
    test "returns true for successful results" do
      result = Result.success("output", 100)
      assert Result.ok?(result)
    end

    test "returns false for failed results" do
      result = Result.failure(1, "error", 100)
      refute Result.ok?(result)
    end

    test "returns false for error results" do
      result = Result.error(:timeout, "", 100)
      refute Result.ok?(result)
    end
  end
end
