defmodule Otturnaut.Build do
  @moduledoc """
  Build orchestration for source-based deployments.

  Coordinates the full build pipeline: clone repository, build container image,
  and clean up temporary files.

  ## Example

      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main",
        dockerfile: "Dockerfile",
        build_args: %{"MIX_ENV" => "prod"}
      }

      case Build.run("myapp", config) do
        {:ok, "otturnaut-myapp:abc123def456789"} ->
          # Image is ready for deployment (tagged with commit hash)

        {:error, {:clone_failed, reason}} ->
          # Git clone failed

        {:error, {:build_failed, reason}} ->
          # Docker build failed
      end

  ## Streaming Output

  Pass a `:subscriber` option to receive build progress:

      Build.run("myapp", "abc123", config, subscriber: self())

      # Receive messages:
      # {:build_progress, :cloning, "Cloning repository..."}
      # {:command_output, pid, {:stdout, "Step 1/10..."}}
      # {:build_progress, :complete, "otturnaut-myapp:abc123"}

  """

  alias Otturnaut.Source.Git

  @type build_config :: %{
          required(:repo_url) => String.t(),
          required(:ref) => String.t(),
          optional(:dockerfile) => String.t(),
          optional(:build_args) => %{String.t() => String.t()},
          optional(:ssh_key) => String.t()
        }

  @type run_opts :: [
          subscriber: pid(),
          timeout: timeout(),
          runtime: module(),
          runtime_opts: keyword(),
          command_module: module()
        ]

  @default_dockerfile "Dockerfile"
  @default_timeout :timer.minutes(10)

  @doc """
  Builds a container image from a Git repository.

  ## Steps

  1. Clone repository to temp directory
  2. Build image with tag `otturnaut-{app_id}:{commit_hash}`
  3. Clean up temp directory (always, even on failure)
  4. Return `{:ok, image_tag}` or `{:error, reason}`

  ## Options

  - `:subscriber` - PID to receive progress messages
  - `:timeout` - Build timeout (default: 10 minutes)
  - `:runtime` - Runtime module (default: `Otturnaut.Runtime.Docker`)
  - `:runtime_opts` - Options passed to runtime
  - `:command_module` - Module for running commands (for testing)

  """
  @spec run(String.t(), build_config(), run_opts()) ::
          {:ok, String.t()} | {:error, term()}
  def run(app_id, config, opts \\ []) do
    subscriber = Keyword.get(opts, :subscriber)
    runtime = Keyword.get(opts, :runtime, Otturnaut.Runtime.Docker)
    runtime_opts = Keyword.get(opts, :runtime_opts, [])
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    command_module = Keyword.get(opts, :command_module)

    clone_opts =
      [
        ref: config.ref,
        ssh_key: Map.get(config, :ssh_key)
      ]
      |> maybe_add_command_module(command_module)

    notify(subscriber, :cloning, "Cloning repository...")

    case Git.clone(config.repo_url, clone_opts) do
      {:ok, source_dir, commit_hash} ->
        image_tag = image_tag(app_id, commit_hash)
        build_and_cleanup(source_dir, image_tag, config, runtime, runtime_opts, timeout, subscriber)

      {:error, reason} ->
        {:error, {:clone_failed, reason}}
    end
  end

  @doc """
  Generates the image tag for a deployment.

  Format: `otturnaut-{app_id}:{commit_hash}`
  """
  @spec image_tag(String.t(), String.t()) :: String.t()
  def image_tag(app_id, commit_hash) do
    "otturnaut-#{app_id}:#{commit_hash}"
  end

  # Private functions

  defp build_and_cleanup(source_dir, image_tag, config, runtime, runtime_opts, timeout, subscriber) do
    dockerfile = Map.get(config, :dockerfile, @default_dockerfile)
    build_args = Map.get(config, :build_args, %{})

    dockerfile_path = Path.join(source_dir, dockerfile)

    build_opts =
      runtime_opts
      |> Keyword.put(:dockerfile, dockerfile_path)
      |> Keyword.put(:timeout, timeout)
      |> Keyword.put(:build_args, build_args)

    notify(subscriber, :building, "Building image #{image_tag}...")

    try do
      case runtime.build_image(source_dir, image_tag, build_opts) do
        {:ok, ^image_tag} ->
          notify(subscriber, :complete, image_tag)
          {:ok, image_tag}

        {:ok, _pid} ->
          notify(subscriber, :complete, image_tag)
          {:ok, image_tag}

        {:error, reason} ->
          {:error, {:build_failed, reason}}
      end
    after
      notify(subscriber, :cleanup, "Cleaning up source directory...")
      Git.cleanup(source_dir)
    end
  end

  defp notify(nil, _step, _message), do: :ok

  defp notify(subscriber, step, message) do
    send(subscriber, {:build_progress, step, message})
    :ok
  end

  defp maybe_add_command_module(opts, nil), do: opts
  defp maybe_add_command_module(opts, mod), do: Keyword.put(opts, :command_module, mod)
end
