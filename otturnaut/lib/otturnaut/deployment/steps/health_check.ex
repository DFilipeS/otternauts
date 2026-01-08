defmodule Otturnaut.Deployment.Steps.HealthCheck do
  @moduledoc """
  Verifies the new container is healthy before switching traffic.

  This is a read-only step that performs health checks with retries.
  If the container fails health checks, the deployment fails and
  previous steps are undone.
  """

  use Reactor.Step

  @impl true
  def run(arguments, _context, _options) do
    %{
      deployment: deployment,
      container: container,
      opts: opts
    } = arguments

    %{runtime: runtime, runtime_opts: runtime_opts} = deployment
    %{container_name: container_name} = container

    check_config = %{
      type: :running,
      runtime: runtime,
      runtime_opts: runtime_opts,
      name: container_name
    }

    health_opts = Keyword.get(opts, :health_check, [])
    max_attempts = Keyword.get(health_opts, :max_attempts, 10)
    interval = Keyword.get(health_opts, :interval, 1_000)

    case Otturnaut.HealthCheck.check_with_retry(check_config,
           max_attempts: max_attempts,
           interval: interval
         ) do
      :healthy ->
        {:ok, :healthy}

      :unhealthy ->
        {:error, :health_check_failed}
    end
  end
end
