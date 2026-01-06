defmodule Otturnaut.Source.Git do
  @moduledoc """
  Git source fetching.

  Clones a Git repository to a temporary directory for building.
  Supports both public repos (HTTPS) and private repos (SSH with key).

  ## Examples

      # Public repository
      {:ok, path} = Git.clone("https://github.com/user/app.git")

      # With specific ref
      {:ok, path} = Git.clone("https://github.com/user/app.git", ref: "v1.0.0")

      # Private repository with SSH key
      {:ok, path} = Git.clone("git@github.com:user/private.git",
        ssh_key: "/path/to/deploy_key"
      )

      # Always cleanup after use
      Git.cleanup(path)

  """

  alias Otturnaut.Command
  alias Otturnaut.Command.Result

  @type clone_opts :: [
          ref: String.t(),
          depth: pos_integer() | nil,
          ssh_key: String.t() | nil,
          command_module: module()
        ]

  @default_ref "main"
  @default_depth 1

  @doc """
  Clones a repository to a temporary directory.

  Returns `{:ok, path, commit_hash}` where path is the absolute path to the cloned repo
  and commit_hash is the full SHA of the checked-out commit.

  ## Options

  - `:ref` - Branch, tag, or commit to checkout (default: "main")
  - `:depth` - Shallow clone depth (default: 1)
  - `:ssh_key` - Path to SSH private key for authentication (optional)
  - `:command_module` - Module for running commands (default: `Otturnaut.Command`)

  """
  @spec clone(String.t(), clone_opts()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def clone(repo_url, opts \\ []) do
    ref = Keyword.get(opts, :ref, @default_ref)
    depth = Keyword.get(opts, :depth, @default_depth)
    ssh_key = Keyword.get(opts, :ssh_key)
    cmd = Keyword.get(opts, :command_module, Command)

    with {:ok, temp_dir} <- create_temp_dir(),
         :ok <- do_clone(repo_url, temp_dir, ref, depth, ssh_key, cmd),
         {:ok, commit_hash} <- get_commit_hash(temp_dir, cmd) do
      {:ok, temp_dir, commit_hash}
    end
  end

  @doc """
  Cleans up a cloned repository directory.

  This is idempotent—calling it on a non-existent path succeeds.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(path) do
    File.rm_rf!(path)
    :ok
  end

  # Private functions

  defp create_temp_dir do
    prefix = "otturnaut-source-"
    timestamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    dir_name = "#{prefix}#{timestamp}-#{random}"

    temp_dir = Path.join(System.tmp_dir!(), dir_name)

    case File.mkdir_p(temp_dir) do
      :ok -> {:ok, temp_dir}
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp do_clone(repo_url, target_dir, ref, depth, ssh_key, cmd) do
    args = build_clone_args(repo_url, target_dir, ref, depth)
    env = build_env(ssh_key)

    result = cmd.run("git", args, env: env)

    case result do
      %Result{status: :ok} -> :ok
      %Result{status: :error, error: error, output: output} -> {:error, {:clone_failed, error, output}}
    end
  end

  defp build_clone_args(repo_url, target_dir, ref, depth) do
    base_args = ["clone", "--branch", ref, "--single-branch"]

    depth_args =
      if depth do
        ["--depth", to_string(depth)]
      else
        []
      end

    base_args ++ depth_args ++ [repo_url, target_dir]
  end

  defp build_env(nil), do: []

  defp build_env(ssh_key) do
    # IdentityAgent=none disables SSH agent (overrides ~/.ssh/config IdentityAgent)
    # IdentitiesOnly=yes ensures only the specified key is used
    # StrictHostKeyChecking=accept-new auto-accepts new host keys
    # BatchMode=yes fails immediately instead of prompting for passwords
    ssh_command =
      "ssh -i #{ssh_key} -o IdentityAgent=none -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

    [{"GIT_SSH_COMMAND", ssh_command}]
  end

  defp get_commit_hash(repo_dir, cmd) do
    result = cmd.run("git", ["rev-parse", "HEAD"], working_dir: repo_dir)

    case result do
      %Result{status: :ok, output: output} ->
        commit_hash = String.trim(output)
        {:ok, commit_hash}

      %Result{status: :error, error: error} ->
        {:error, {:get_commit_hash_failed, error}}
    end
  end
end
