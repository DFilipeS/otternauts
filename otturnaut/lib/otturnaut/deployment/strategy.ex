defmodule Otturnaut.Deployment.Strategy do
  @moduledoc """
  Behaviour for deployment strategies.

  Different strategies implement different ways of deploying applications with
  various trade-offs around downtime, risk, and complexity.

  ## Available Strategies

  - `Otturnaut.Deployment.Strategy.BlueGreen` — Zero-downtime by running two versions
    simultaneously and switching traffic instantly (Phase 1)
  - `Otturnaut.Deployment.Strategy.Canary` — Route percentage of traffic to new version (future)
  - `Otturnaut.Deployment.Strategy.Rolling` — For multi-instance deployments (future)

  ## Context

  The strategy receives a context struct with infrastructure modules. Runtime
  configuration (module and options) is on the deployment struct itself.

  See `Otturnaut.Deployment.Context` for context details.
  """

  alias Otturnaut.Deployment
  alias Otturnaut.Deployment.Context

  @type context :: Context.t()

  @type step ::
          :allocate_port
          | :start_container
          | :health_check
          | :switch_route
          | :stop_old
          | :release_port

  @type progress :: %{
          step: step(),
          message: String.t()
        }

  @type result :: {:ok, Deployment.t()} | {:error, term(), Deployment.t()}

  @doc """
  Executes a deployment using this strategy.

  Takes a deployment struct and a context map containing runtime dependencies.
  Returns the updated deployment struct with new container info, or an error
  with the partial deployment state for cleanup.

  Options:
  - `:subscriber` - PID to receive progress updates (optional)
  """
  @callback execute(deployment :: Deployment.t(), context :: context(), opts :: keyword()) ::
              result()

  @doc """
  Rolls back a failed or in-progress deployment.

  Cleans up any resources created during a partial deployment (e.g., stop new
  container, release port, restore old route).
  """
  @callback rollback(deployment :: Deployment.t(), context :: context(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Returns the name of the strategy for display purposes.
  """
  @callback name() :: String.t()

  @doc """
  Sends progress update to subscriber if one is configured.
  """
  @spec notify_progress(keyword(), step(), String.t()) :: :ok
  def notify_progress(opts, step, message) do
    case Keyword.get(opts, :subscriber) do
      nil -> :ok
      pid -> send(pid, {:deployment_progress, %{step: step, message: message}})
    end

    :ok
  end
end
