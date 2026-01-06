defmodule Otturnaut.BuildTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Otturnaut.Build
  alias Otturnaut.Source.Git
  alias Otturnaut.Runtime.Docker
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
          Result.failure(128, "fatal: repo not found", 100)
      end
    end
  end

  defmodule MockRuntime do
    def build_image(context_path, tag, opts) do
      send(self(), {:build_image_called, context_path, tag, opts})

      case Process.get(:mock_build_result, :success) do
        :success -> {:ok, tag}
        :async -> {:ok, self()}
        :failure -> {:error, {{:exit, 1}, "build failed"}}
      end
    end
  end

  describe "run/4" do
    test "clones and builds successfully with commit hash as tag" do
      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main"
      }

      {:ok, image_tag} =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand
        )

      assert image_tag == "otturnaut-myapp:abc123def456789"

      assert_received {:git_called, args, _opts}
      assert "https://github.com/user/app.git" in args

      assert_received {:build_image_called, context_path, "otturnaut-myapp:abc123def456789", opts}
      assert String.contains?(context_path, "otturnaut-source-")
      assert Keyword.get(opts, :dockerfile) |> String.ends_with?("Dockerfile")
    end

    test "uses custom dockerfile" do
      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main",
        dockerfile: "docker/Dockerfile.prod"
      }

      {:ok, _image_tag} =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand
        )

      assert_received {:build_image_called, _context_path, _tag, opts}
      dockerfile = Keyword.get(opts, :dockerfile)
      assert String.ends_with?(dockerfile, "docker/Dockerfile.prod")
    end

    test "passes build_args to runtime" do
      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main",
        build_args: %{"MIX_ENV" => "prod", "NODE_ENV" => "production"}
      }

      {:ok, _image_tag} =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand
        )

      assert_received {:build_image_called, _context_path, _tag, opts}
      build_args = Keyword.get(opts, :build_args)
      assert build_args == %{"MIX_ENV" => "prod", "NODE_ENV" => "production"}
    end

    test "passes ssh_key to git clone via GIT_SSH_COMMAND env" do
      config = %{
        repo_url: "git@github.com:user/private.git",
        ref: "main",
        ssh_key: "/path/to/key"
      }

      {:ok, _image_tag} =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand
        )

      assert_received {:git_called, _args, opts}
      env = Keyword.get(opts, :env, [])
      assert {"GIT_SSH_COMMAND", ssh_command} = List.keyfind(env, "GIT_SSH_COMMAND", 0)
      assert String.contains?(ssh_command, "-i /path/to/key")
    end

    test "passes timeout to runtime" do
      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main"
      }

      {:ok, _image_tag} =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand,
          timeout: :timer.minutes(20)
        )

      assert_received {:build_image_called, _context_path, _tag, opts}
      assert Keyword.get(opts, :timeout) == :timer.minutes(20)
    end

    test "sends progress notifications to subscriber" do
      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main"
      }

      {:ok, _image_tag} =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand,
          subscriber: self()
        )

      assert_received {:build_progress, :cloning, _}
      assert_received {:build_progress, :building, _}
      assert_received {:build_progress, :cleanup, _}
      assert_received {:build_progress, :complete, "otturnaut-myapp:abc123def456789"}
    end

    test "returns error when clone fails" do
      Process.put(:mock_git_result, :failure)

      config = %{
        repo_url: "https://github.com/user/nonexistent.git",
        ref: "main"
      }

      result =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand
        )

      assert {:error, {:clone_failed, _reason}} = result
    after
      Process.delete(:mock_git_result)
    end

    test "returns error when build fails" do
      Process.put(:mock_build_result, :failure)

      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main"
      }

      result =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand
        )

      assert {:error, {:build_failed, _reason}} = result
    after
      Process.delete(:mock_build_result)
    end

    test "cleans up source directory even on build failure" do
      Process.put(:mock_build_result, :failure)

      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main"
      }

      {:error, _} =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand,
          subscriber: self()
        )

      assert_received {:build_progress, :cleanup, _}
    after
      Process.delete(:mock_build_result)
    end

    test "handles async build returning pid" do
      Process.put(:mock_build_result, :async)

      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main"
      }

      {:ok, image_tag} =
        Build.run("myapp", config,
          runtime: MockRuntime,
          command_module: MockCommand
        )

      assert image_tag == "otturnaut-myapp:abc123def456789"
    after
      Process.delete(:mock_build_result)
    end
  end

  describe "image_tag/2" do
    test "generates correct format with commit hash" do
      assert Build.image_tag("myapp", "abc123def456789") == "otturnaut-myapp:abc123def456789"
      assert Build.image_tag("api", "1a2b3c4d5e6f") == "otturnaut-api:1a2b3c4d5e6f"
    end
  end

  describe "run/3 default argument path" do
    test "exercises default opts using Mimic" do
      # Mock Git.clone to avoid network calls
      stub(Git, :clone, fn _repo_url, _opts ->
        temp_dir = Path.join(System.tmp_dir!(), "otturnaut-test-#{:rand.uniform(10000)}")
        File.mkdir_p!(temp_dir)
        {:ok, temp_dir, "abc123def456789"}
      end)

      stub(Git, :cleanup, fn _path -> :ok end)

      # Mock Docker.build_image to avoid actual builds
      stub(Docker, :build_image, fn _context, tag, _opts ->
        {:ok, tag}
      end)

      config = %{
        repo_url: "https://github.com/user/app.git",
        ref: "main"
      }

      {:ok, image_tag} = Build.run("myapp", config)

      assert image_tag == "otturnaut-myapp:abc123def456789"
    end
  end
end
