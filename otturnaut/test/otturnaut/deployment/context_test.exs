defmodule Otturnaut.Deployment.ContextTest do
  use ExUnit.Case, async: true

  alias Otturnaut.Deployment.Context

  describe "new/0" do
    test "returns context with default modules" do
      context = Context.new()

      assert context.port_manager == Otturnaut.PortManager
      assert context.app_state == Otturnaut.AppState
      assert context.caddy == Otturnaut.Caddy
    end
  end

  describe "new/1" do
    test "accepts map overrides and merges with defaults" do
      context = Context.new(%{port_manager: MockPortManager})

      assert context.port_manager == MockPortManager
      assert context.app_state == Otturnaut.AppState
      assert context.caddy == Otturnaut.Caddy
    end

    test "accepts keyword list overrides and merges with defaults" do
      context = Context.new(port_manager: MockPortManager, caddy: MockCaddy)

      assert context.port_manager == MockPortManager
      assert context.app_state == Otturnaut.AppState
      assert context.caddy == MockCaddy
    end

    test "overrides all modules when all are provided" do
      context =
        Context.new(%{
          port_manager: MockPortManager,
          app_state: MockAppState,
          caddy: MockCaddy
        })

      assert context.port_manager == MockPortManager
      assert context.app_state == MockAppState
      assert context.caddy == MockCaddy
    end
  end
end
