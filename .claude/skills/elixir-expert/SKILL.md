---
name: elixir-expert
description: Expert guidance on Elixir programming language best practices, idioms, and patterns, plus deep knowledge of the core ecosystem libraries including Phoenix Framework, Ash Framework, Ecto, and Oban. Use when working on Elixir codebases for code review, writing idiomatic code, debugging, architecture decisions, project structure, OTP patterns, testing strategies, or understanding library-specific patterns. Triggers on Elixir, Phoenix, LiveView, Ash, Ecto, Oban, GenServer, Supervisor, or OTP-related questions.
---

# Elixir Expert

Expert guidance for idiomatic Elixir development and its core ecosystem.

## Core Elixir Patterns

### Naming Conventions

- `snake_case` for functions, variables, atoms
- `CamelCase` for modules
- Trailing `?` for boolean-returning functions: `valid?`, `admin?`
- Trailing `!` for functions that raise: `Repo.get!`, `File.read!`
- `is_` prefix only for guard-friendly macros: `defguard is_admin(user)`

### Error Handling

Use tagged tuples `{:ok, result}` / `{:error, reason}` for expected failures. Reserve exceptions for programmer errors:

```elixir
# Good: tagged tuples with normalized errors
def create_order(params) do
  with {:ok, user} <- fetch_user(params.user_id),
       {:ok, product} <- fetch_product(params.product_id),
       {:ok, order} <- build_order(user, product) do
    {:ok, order}
  end
end

defp fetch_user(id) do
  case Repo.get(User, id) do
    nil -> {:error, :user_not_found}
    user -> {:ok, user}
  end
end
```

Avoid complex `else` blocks in `with`—normalize errors in helper functions instead.

### GenServer Best Practices

Use GenServer for state management, not code organization. Keep handlers thin:

```elixir
defmodule OrderProcessor do
  use GenServer
  alias MyApp.Orders

  # Client API hides implementation
  def process(order), do: GenServer.call(__MODULE__, {:process, order})

  # Thin handler delegates to pure functions
  def handle_call({:process, order}, _from, state) do
    result = Orders.process(order)  # Business logic in pure module
    {:reply, result, state}
  end

  # Use handle_continue for slow initialization
  def init(args) do
    {:ok, %{}, {:continue, :load_data}}
  end

  def handle_continue(:load_data, state) do
    {:noreply, %{state | data: load_expensive_data()}}
  end
end
```

Prefer `call/2` over `cast/2` for backpressure and error visibility.

### Supervisor Patterns

- Default to `:one_for_one` strategy
- Use `DynamicSupervisor` for runtime-spawned children
- Use `Registry` for process discovery
- Module-based supervisors enable cleaner testing

### Common Anti-Patterns to Avoid

- **Dynamic atom creation**: Never `String.to_atom(user_input)`—use `to_existing_atom/1`
- **Underscore catch-all hiding errors**: Match explicitly, don't `_ -> handle_error()`
- **GenServer for code organization**: Plain modules work for stateless logic
- **Large structs (32+ fields)**: Loses compile-time optimizations; group into embedded maps
- **`&&`/`||` with booleans**: Use `and`/`or`/`not` for boolean operands

## Project Structure

### Prefer Flat Apps with Contexts

For most projects, use a single app with Phoenix Contexts for organization:

```
lib/my_app/
├── accounts/          # Context: User, credentials, auth
├── orders/            # Context: Order, payment logic
├── catalog/           # Context: Product, inventory
└── my_app_web/        # Phoenix web layer
```

### Poncho Projects for Multi-App Needs

When separation is genuinely needed (different deployment targets, Nerves), use poncho projects over umbrellas:

```
my_project/
├── my_project_core/      # Standalone app with own mix.exs
│   ├── lib/
│   ├── mix.exs
│   └── config/
├── my_project_web/       # Depends on core via path
│   ├── lib/
│   ├── mix.exs           # deps: [{:my_project_core, path: "../my_project_core"}]
│   └── config/
└── my_project_firmware/  # Nerves app, depends on core
    ├── lib/
    └── mix.exs
```

Key differences from umbrella:
- Each app has independent `config/` (explicit imports required)
- Standard path dependencies with `env: Mix.env()`
- No shared build artifacts or implicit config merging

### When to Use Umbrella (Rarely)

Only when you need: multiple Phoenix endpoints with different assets, different deployment scaling, or strict compile-time dependency enforcement.

## Testing Patterns

### Testing Pyramid

Follow the testing pyramid—prioritize in this order:

1. **Unit tests (most)**: Test individual functions, modules, changesets, and workers in isolation. Fast, focused, easy to debug.
2. **Integration tests (some)**: Test context functions with database, multi-module interactions.
3. **End-to-end tests (few)**: Test full user flows through LiveView or controllers. Slower, more brittle.

```
        /\
       /  \      E2E (few)
      /----\
     /      \    Integration (some)
    /--------\
   /          \  Unit (most)
  /____________\
```

When adding tests, ask: "Can I test this at a lower level?" If yes, do that instead.

### ExUnit Best Practices

```elixir
defmodule MyApp.UsersTest do
  use MyApp.DataCase, async: true  # async when no shared state

  describe "create_user/1" do
    test "with valid params returns ok tuple" do
      assert {:ok, %User{name: "Alice"}} = Users.create_user(%{name: "Alice"})
    end

    test "with invalid params returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Users.create_user(%{})
    end
  end
end
```

### Mox for External Services

Define behaviors, create mocks, verify in tests:

```elixir
# In test/support/mocks.ex
Mox.defmock(MyApp.HTTPClientMock, for: MyApp.HTTPClient)

# In test
expect(MyApp.HTTPClientMock, :get, fn url -> {:ok, %{status: 200}} end)
```

## Library-Specific References

For detailed patterns on each library, see:

- **Phoenix Framework**: See [references/phoenix.md](references/phoenix.md) for Phoenix 1.7+ patterns, verified routes, function components, LiveView, and context design
- **Ash Framework**: See [references/ash.md](references/ash.md) for resource definitions, actions, policies, calculations, and AshPhoenix integration
- **Ecto**: See [references/ecto.md](references/ecto.md) for schema design, changeset patterns, query composition, migrations, and multi-tenancy
- **Oban**: See [references/oban.md](references/oban.md) for worker patterns, queue configuration, error handling, and testing

## Quick Reference

| Task | Pattern |
|------|---------|
| Error handling | Tagged tuples `{:ok, _}` / `{:error, _}` |
| State management | GenServer with thin handlers |
| Code organization | Contexts (not GenServer or umbrella) |
| Multi-app projects | Poncho projects |
| Background jobs | Oban with transactional inserts |
| Data layer | Ecto with composable queries |
| Declarative resources | Ash Framework |
| LiveView data | Load in LiveView, pass to components |
