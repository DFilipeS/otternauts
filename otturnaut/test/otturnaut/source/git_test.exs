defmodule Otturnaut.Source.GitTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Otturnaut.Source.Git
  alias Otturnaut.Command
  alias Otturnaut.Command.Result

  setup do
    on_exit(fn ->
      # Clean up any leftover otturnaut temp directories
      System.tmp_dir!()
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "otturnaut-"))
      |> Enum.each(fn dir ->
        Path.join(System.tmp_dir!(), dir) |> File.rm_rf!()
      end)
    end)

    :ok
  end

  defmodule MockCommand do
    def run(command, args, opts \\ [])

    def run("git", ["rev-parse", "HEAD"], opts) do
      send(self(), {:git_rev_parse_called, opts})

      case Process.get(:mock_rev_parse_result, :success) do
        :success ->
          Result.success("abc123def456789\n", 100)

        :failure ->
          Result.failure(128, "fatal: not a git repository", 100)
      end
    end

    def run("git", args, opts) do
      send(self(), {:git_called, args, opts})

      case Process.get(:mock_git_result, :success) do
        :success ->
          Result.success("", 100)

        :failure ->
          Result.failure(128, "fatal: error", 100)
      end
    end
  end

  describe "clone/2" do
    test "clones a repository to a temp directory and returns commit hash" do
      repo_url = "https://github.com/user/app.git"

      {:ok, path, commit_hash} = Git.clone(repo_url, command_module: MockCommand)

      assert_received {:git_called, args, _opts}
      assert "--branch" in args
      assert "main" in args
      assert "--depth" in args
      assert "1" in args
      assert repo_url in args
      assert path in args

      assert String.starts_with?(path, System.tmp_dir!())
      assert String.contains?(path, "otturnaut-source-")
      assert commit_hash == "abc123def456789"

      Git.cleanup(path)
    end

    test "uses specified ref" do
      repo_url = "https://github.com/user/app.git"

      {:ok, path, _commit_hash} = Git.clone(repo_url, ref: "v1.0.0", command_module: MockCommand)

      assert_received {:git_called, args, _opts}
      assert "v1.0.0" in args
      refute "main" in args

      Git.cleanup(path)
    end

    test "uses specified depth" do
      repo_url = "https://github.com/user/app.git"

      {:ok, path, _commit_hash} = Git.clone(repo_url, depth: 5, command_module: MockCommand)

      assert_received {:git_called, args, _opts}
      assert "5" in args

      Git.cleanup(path)
    end

    test "passes SSH key via GIT_SSH_COMMAND env" do
      repo_url = "git@github.com:user/private.git"
      ssh_key = "/path/to/deploy_key"

      {:ok, path, _commit_hash} = Git.clone(repo_url, ssh_key: ssh_key, command_module: MockCommand)

      assert_received {:git_called, _args, opts}
      env = Keyword.get(opts, :env, [])
      assert {"GIT_SSH_COMMAND", ssh_command} = List.keyfind(env, "GIT_SSH_COMMAND", 0)
      assert String.contains?(ssh_command, "-i #{ssh_key}")
      assert String.contains?(ssh_command, "IdentityAgent=none")
      assert String.contains?(ssh_command, "IdentitiesOnly=yes")
      assert String.contains?(ssh_command, "StrictHostKeyChecking=accept-new")
      assert String.contains?(ssh_command, "BatchMode=yes")

      Git.cleanup(path)
    end

    test "does not set GIT_SSH_COMMAND when no ssh_key provided" do
      repo_url = "https://github.com/user/app.git"

      {:ok, path, _commit_hash} = Git.clone(repo_url, command_module: MockCommand)

      assert_received {:git_called, _args, opts}
      env = Keyword.get(opts, :env, [])
      assert env == []

      Git.cleanup(path)
    end

    test "returns error when clone fails" do
      Process.put(:mock_git_result, :failure)
      repo_url = "https://github.com/user/app.git"

      result = Git.clone(repo_url, command_module: MockCommand)

      assert {:error, {:clone_failed, {:exit, 128}, "fatal: error"}} = result
    after
      Process.delete(:mock_git_result)
    end

    test "supports nil depth for full clone" do
      repo_url = "https://github.com/user/app.git"

      {:ok, path, _commit_hash} = Git.clone(repo_url, depth: nil, command_module: MockCommand)

      assert_received {:git_called, args, _opts}
      refute "--depth" in args

      Git.cleanup(path)
    end
  end

  describe "clone/1 default argument path" do
    test "exercises default opts using Mimic" do
      # Mock Command.run to avoid network calls
      stub(Command, :run, fn
        "git", ["rev-parse", "HEAD"], _opts ->
          Result.success("abc123def456789\n", 100)

        "git", _args, _opts ->
          Result.success("", 100)
      end)

      {:ok, path, commit_hash} = Git.clone("https://github.com/user/app.git")

      assert String.starts_with?(path, System.tmp_dir!())
      assert commit_hash == "abc123def456789"
      Git.cleanup(path)
    end

    test "returns error when mkdir_p fails" do
      # Mock File.mkdir_p to simulate failure
      stub(File, :mkdir_p, fn _path -> {:error, :eacces} end)

      result = Git.clone("https://github.com/user/app.git", command_module: MockCommand)

      assert {:error, {:mkdir_failed, :eacces}} = result
    end

    test "returns error when rev-parse fails" do
      Process.put(:mock_rev_parse_result, :failure)

      repo_url = "https://github.com/user/app.git"

      result = Git.clone(repo_url, command_module: MockCommand)

      assert {:error, {:get_commit_hash_failed, _reason}} = result
    after
      Process.delete(:mock_rev_parse_result)
    end
  end

  describe "cleanup/1" do
    test "removes the directory" do
      {:ok, temp_dir} = create_temp_dir_with_files()

      assert File.exists?(temp_dir)
      assert :ok = Git.cleanup(temp_dir)
      refute File.exists?(temp_dir)
    end

    test "is idempotent - succeeds for non-existent path" do
      non_existent = Path.join(System.tmp_dir!(), "otturnaut-does-not-exist-#{:rand.uniform(10000)}")
      refute File.exists?(non_existent)

      assert :ok = Git.cleanup(non_existent)
    end
  end

  # Helper to create a temp directory with some files
  defp create_temp_dir_with_files do
    dir = Path.join(System.tmp_dir!(), "otturnaut-test-#{:rand.uniform(10000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "test.txt"), "hello")
    {:ok, dir}
  end
end
