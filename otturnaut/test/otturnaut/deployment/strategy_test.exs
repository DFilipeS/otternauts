defmodule Otturnaut.Deployment.StrategyTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment.Strategy

  describe "notify_progress/3" do
    test "sends message to subscriber when configured" do
      opts = [subscriber: self()]

      assert :ok = Strategy.notify_progress(opts, :allocate_port, "Allocating port")

      assert_received {:deployment_progress, %{step: :allocate_port, message: "Allocating port"}}
    end

    test "does nothing when no subscriber configured" do
      opts = []

      assert :ok = Strategy.notify_progress(opts, :allocate_port, "Allocating port")

      refute_received {:deployment_progress, _}
    end
  end
end
