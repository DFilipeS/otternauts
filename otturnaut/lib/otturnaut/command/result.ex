defmodule Otturnaut.Command.Result do
  @moduledoc """
  Structured result from command execution.

  Contains the exit status, output, timing, and any error information
  from running an external command.
  """

  @type error_reason ::
          {:exit, non_neg_integer()}
          | :timeout
          | :command_not_found
          | :runner_crashed

  @type t :: %__MODULE__{
          status: :ok | :error,
          exit_code: non_neg_integer() | nil,
          output: String.t(),
          error: error_reason() | nil,
          duration_ms: non_neg_integer()
        }

  @enforce_keys [:status, :duration_ms]
  defstruct [
    :status,
    :exit_code,
    :error,
    output: "",
    duration_ms: 0
  ]

  @doc """
  Creates a successful result.
  """
  @spec success(String.t(), non_neg_integer()) :: t()
  def success(output, duration_ms) do
    %__MODULE__{
      status: :ok,
      exit_code: 0,
      output: output,
      duration_ms: duration_ms
    }
  end

  @doc """
  Creates a failure result from a non-zero exit code.
  """
  @spec failure(non_neg_integer(), String.t(), non_neg_integer()) :: t()
  def failure(exit_code, output, duration_ms) do
    %__MODULE__{
      status: :error,
      exit_code: exit_code,
      output: output,
      error: {:exit, exit_code},
      duration_ms: duration_ms
    }
  end

  @doc """
  Creates a failure result from an error reason.
  """
  @spec error(error_reason(), String.t(), non_neg_integer()) :: t()
  def error(reason, output, duration_ms) do
    %__MODULE__{
      status: :error,
      exit_code: nil,
      output: output,
      error: reason,
      duration_ms: duration_ms
    }
  end

  @doc """
  Returns true if the result represents a successful execution.
  """
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{status: :ok}), do: true
  def ok?(%__MODULE__{}), do: false
end
