defmodule Otturnaut.Command.Runner do
  @moduledoc """
  Executes a command via Port and streams output to a subscriber.

  This module is typically not called directly. Use `Otturnaut.Command.run_async/3`
  to start a runner under the command supervisor.

  ## Messages sent to subscriber

      {:command_output, runner_pid, {:stdout | :stderr, line}}
      {:command_done, runner_pid, %Result{}}

  Note: Currently stdout and stderr are merged, so all output is tagged as `:stdout`.
  This will be improved in a future version.
  """

  alias Otturnaut.Command.Result
  alias Otturnaut.Command.PortWrapper

  @default_timeout :timer.minutes(5)
  @line_buffer_size 10 * 1024

  @type option ::
          {:timeout, timeout()}
          | {:subscriber, pid()}
          | {:working_dir, String.t()}
          | {:env, [{String.t(), String.t()}]}

  @doc """
  Runs the command and streams output to the subscriber.

  This function blocks until the command completes or times out.
  It's designed to be called from a Task.

  Returns the final `%Result{}`.
  """
  @spec run(String.t(), [String.t()], [option()]) :: Result.t()
  def run(command, args, opts \\ []) do
    subscriber = Keyword.get(opts, :subscriber, self())
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    working_dir = Keyword.get(opts, :working_dir)
    env = Keyword.get(opts, :env, [])

    start_time = System.monotonic_time(:millisecond)

    case find_executable(command) do
      nil ->
        result = Result.error(:command_not_found, "", 0)
        send(subscriber, {:command_done, self(), result})
        result

      executable ->
        run_with_port(executable, args, subscriber, timeout, working_dir, env, start_time)
    end
  end

  defp find_executable(command) do
    System.find_executable(command)
  end

  defp run_with_port(executable, args, subscriber, timeout, working_dir, env, start_time) do
    port_opts = build_port_opts(working_dir, env)

    port = Port.open({:spawn_executable, executable}, [{:args, args} | port_opts])
    timer_ref = schedule_timeout(timeout)

    try do
      result = receive_loop(port, subscriber, timer_ref, start_time, [])
      send(subscriber, {:command_done, self(), result})
      result
    after
      cancel_timeout(timer_ref)
      safe_close_port(port)
    end
  end

  defp build_port_opts(working_dir, env) do
    base_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, @line_buffer_size}
    ]

    base_opts
    |> maybe_add_working_dir(working_dir)
    |> maybe_add_env(env)
  end

  defp maybe_add_working_dir(opts, nil), do: opts
  defp maybe_add_working_dir(opts, dir), do: [{:cd, dir} | opts]

  defp maybe_add_env(opts, []), do: opts

  defp maybe_add_env(opts, env) do
    env_charlist = Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    [{:env, env_charlist} | opts]
  end

  defp schedule_timeout(:infinity), do: nil

  defp schedule_timeout(timeout) when is_integer(timeout) do
    Process.send_after(self(), :command_timeout, timeout)
  end

  defp cancel_timeout(nil), do: :ok
  defp cancel_timeout(ref), do: Process.cancel_timer(ref)

  defp receive_loop(port, subscriber, timer_ref, start_time, output_acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        send(subscriber, {:command_output, self(), {:stdout, line}})
        receive_loop(port, subscriber, timer_ref, start_time, [[line, "\n"] | output_acc])

      {^port, {:data, {:noeol, line}}} ->
        # Partial line (exceeded buffer or no newline yet)
        send(subscriber, {:command_output, self(), {:stdout, line}})
        receive_loop(port, subscriber, timer_ref, start_time, [line | output_acc])

      {^port, {:exit_status, 0}} ->
        duration = duration_since(start_time)
        output = build_output(output_acc)
        Result.success(output, duration)

      {^port, {:exit_status, code}} ->
        duration = duration_since(start_time)
        output = build_output(output_acc)
        Result.failure(code, output, duration)

      :command_timeout ->
        duration = duration_since(start_time)
        output = build_output(output_acc)
        kill_port(port)
        Result.error(:timeout, output, duration)
    end
  end

  defp duration_since(start_time) do
    System.monotonic_time(:millisecond) - start_time
  end

  defp build_output(output_acc) do
    output_acc
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp kill_port(port) do
    # Get the OS PID and attempt to kill it
    case PortWrapper.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    safe_close_port(port)
  end

  defp safe_close_port(port) do
    if PortWrapper.info(port) != nil do
      PortWrapper.close(port)
    end
  rescue
    # Port may already be closed
    ArgumentError -> :ok
  end
end
