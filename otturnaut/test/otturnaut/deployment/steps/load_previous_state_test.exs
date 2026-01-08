defmodule Otturnaut.Deployment.Steps.LoadPreviousStateTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment.Steps.LoadPreviousState

  defmodule MockAppState do
    def get("existing-app") do
      {:ok, %{container_name: "otturnaut-existing-app-abc123", port: 10000}}
    end

    def get("new-app") do
      {:error, :not_found}
    end
  end

  describe "run/3" do
    test "returns previous state when app exists" do
      arguments = %{
        app_id: "existing-app",
        app_state: MockAppState
      }

      assert {:ok, result} = LoadPreviousState.run(arguments, %{}, [])

      assert result.previous_container_name == "otturnaut-existing-app-abc123"
      assert result.previous_port == 10000
    end

    test "returns nil values when app does not exist" do
      arguments = %{
        app_id: "new-app",
        app_state: MockAppState
      }

      assert {:ok, result} = LoadPreviousState.run(arguments, %{}, [])

      assert result.previous_container_name == nil
      assert result.previous_port == nil
    end
  end
end
