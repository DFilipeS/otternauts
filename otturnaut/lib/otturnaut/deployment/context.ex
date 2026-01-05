defmodule Otturnaut.Deployment.Context do
  @moduledoc """
  Context for deployment operations.

  Contains the infrastructure modules used during deployment, undeploy, and
  rollback operations. Provides sensible defaults for production use while
  allowing tests to override specific modules.

  ## Default Modules

  - `:port_manager` - `Otturnaut.PortManager`
  - `:app_state` - `Otturnaut.AppState`
  - `:caddy` - `Otturnaut.Caddy`

  ## Usage

  In production, no context is needed—defaults are used:

      Deployment.execute(deployment, Strategy.BlueGreen)
      Deployment.undeploy(deployment)

  In tests, override only what you need:

      Deployment.execute(deployment, Strategy.BlueGreen, %{port_manager: MockPortManager})

  """

  @type t :: %__MODULE__{
          port_manager: module(),
          app_state: module(),
          caddy: module()
        }

  defstruct port_manager: Otturnaut.PortManager,
            app_state: Otturnaut.AppState,
            caddy: Otturnaut.Caddy

  @doc """
  Creates a new context with defaults, merging any overrides.

  Accepts either a map or keyword list of overrides.

  ## Examples

      # Use all defaults
      Context.new()

      # Override specific modules
      Context.new(%{port_manager: MockPortManager})
      Context.new(port_manager: MockPortManager, caddy: MockCaddy)

  """
  @spec new(map() | keyword()) :: t()
  def new(overrides \\ %{})

  def new(overrides) when is_list(overrides) do
    new(Map.new(overrides))
  end

  def new(overrides) when is_map(overrides) do
    struct(__MODULE__, overrides)
  end
end
