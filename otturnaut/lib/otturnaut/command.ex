defmodule Otturnaut.Command do
  @moduledoc """
  Execute external commands with streaming output.

  This module provides two ways to run commands:

  - `run_async/3` — Non-blocking, streams output to a subscriber
  - `run/3` — Blocking, returns when the command completes

  ## Async execution

  For long-running commands like builds, use async execution to stream
  output back to Mission Control:

      {:ok, pid} = Command.run_async("docker", ["build", "-t", "myapp", "."],
        timeout: :timer.minutes(10),
        working_dir: "/app"
      )

      # Caller receives messages:
      # {:command_output, pid, {:stdout, "Step 1/10 : FROM elixir:1.19"}}
      # {:command_output, pid, {:stdout, "Step 2/10 : WORKDIR /app"}}
      # ...
      # {:command_done, pid, %Result{status: :ok, exit_code: 0, ...}}

  ## Sync execution

  For quick commands like status checks, use sync execution:

      result = Command.run("docker", ["ps", "--format", "{{.Names}}"])

      case result do
        %Result{status: :ok, output: output} -> parse_containers(output)
        %Result{status: :error, error: reason} -> handle_error(reason)
      end

  ## Options

  - `:timeout` — Maximum duration in milliseconds (default: 5 minutes)
  - `:subscriber` — PID to receive output messages (default: `self()`)
  - `:working_dir` — Directory to run the command in
  """

  alias Otturnaut.Command.{Result, Runner}

  @type option ::
          {:timeout, timeout()}
          | {:subscriber, pid()}
          | {:working_dir, String.t()}
          | {:env, [{String.t(), String.t()}]}

  @doc """
  Runs a command asynchronously under the command supervisor.

  Returns `{:ok, pid}` immediately. The runner process sends output
  messages to the subscriber (defaults to the caller).

  ## Messages

      {:command_output, runner_pid, {:stdout | :stderr, line}}
      {:command_done, runner_pid, %Result{}}

  ## Examples

      {:ok, pid} = Command.run_async("git", ["clone", repo_url])

      receive do
        {:command_output, ^pid, {:stdout, line}} ->
          IO.puts("Output: \#{line}")

        {:command_done, ^pid, result} ->
          IO.inspect(result)
      end
  """
  @spec run_async(String.t(), [String.t()], [option()]) :: {:ok, pid()}
  def run_async(command, args, opts \\ []) do
    opts = Keyword.put_new(opts, :subscriber, self())

    task =
      Task.Supervisor.async_nolink(
        Otturnaut.Command.Supervisor,
        Runner,
        :run,
        [command, args, opts]
      )

    {:ok, task.pid}
  end

  @doc """
  Runs a command synchronously and returns the result.

  This blocks the caller until the command completes or times out.
  Useful for quick commands like status checks.

  ## Examples

      case Command.run("docker", ["inspect", container_id]) do
        %Result{status: :ok, output: json} ->
          {:ok, Jason.decode!(json)}

        %Result{status: :error, error: {:exit, 1}} ->
          {:error, :not_found}

        %Result{status: :error, error: :timeout} ->
          {:error, :timeout}
      end
  """
  @spec run(String.t(), [String.t()], [option()]) :: Result.t()
  def run(command, args, opts \\ []) do
    Runner.run(command, args, opts)
  end

  @doc """
  Cancels a running async command.

  This terminates the runner process, which will close the port
  and attempt to kill the underlying OS process.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    :ok
  end
end
