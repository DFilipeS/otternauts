# Phoenix Framework Patterns

## Table of Contents

1. [Verified Routes](#verified-routes)
2. [Function Components](#function-components)
3. [LiveView Patterns](#liveview-patterns)
4. [Context Design](#context-design)
5. [Testing Phoenix](#testing-phoenix)

## Verified Routes

Phoenix 1.7+ uses the `~p` sigil for compile-time verified paths:

```elixir
# Old (deprecated)
Routes.user_path(conn, :show, user)

# New: verified routes
~p"/users/#{user}"
~p"/posts/#{post}/comments"

# With query params
url(~p"/posts?#{%{page: 1, sort: "date"}}")

# In templates
<.link navigate={~p"/users/#{@user}"}>Profile</.link>
```

Routes are verified against the router at compile time—typos become compile errors.

## Function Components

Phoenix 1.7+ uses function components in `core_components.ex`:

```elixir
defmodule MyAppWeb.CoreComponents do
  use Phoenix.Component

  attr :field, Phoenix.HTML.FormField, required: true
  attr :type, :string, default: "text"
  attr :label, :string, default: nil
  attr :errors, :list, default: []
  slot :inner_block

  def input(assigns) do
    ~H"""
    <div phx-feedback-for={@field.name}>
      <label :if={@label}><%= @label %></label>
      <input
        type={@type}
        name={@field.name}
        id={@field.id}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        class={["input", @errors != [] && "input-error"]}
      />
      <.error :for={msg <- @errors}><%= msg %></.error>
    </div>
    """
  end

  slot :col, required: true do
    attr :label, :string, required: true
  end
  attr :rows, :list, required: true

  def table(assigns) do
    ~H"""
    <table>
      <thead>
        <tr>
          <th :for={col <- @col}><%= col.label %></th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows}>
          <td :for={col <- @col}><%= render_slot(col, row) %></td>
        </tr>
      </tbody>
    </table>
    """
  end
end
```

Key principles:
- Declare all attributes with `attr` and slots with `slot`
- Use `:if` and `:for` special attributes
- Components are stateless—data flows down via assigns

## LiveView Patterns

### Use handle_params for URL State

```elixir
defmodule MyAppWeb.PostLive.Index do
  use MyAppWeb, :live_view

  # mount for session/static setup only
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  # handle_params for URL-dependent state (called on mount AND navigation)
  def handle_params(params, _uri, socket) do
    page = String.to_integer(params["page"] || "1")
    posts = Blog.list_posts(page: page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:posts, posts)}
  end
end
```

### Streams for Large Collections

Streams avoid storing entire lists in socket assigns:

```elixir
def mount(_params, _session, socket) do
  {:ok, stream(socket, :posts, Blog.list_posts())}
end

def handle_info({:post_created, post}, socket) do
  {:noreply, stream_insert(socket, :posts, post, at: 0)}
end

def handle_info({:post_deleted, post}, socket) do
  {:noreply, stream_delete(socket, :posts, post)}
end
```

Template usage:

```heex
<div id="posts" phx-update="stream">
  <div :for={{dom_id, post} <- @streams.posts} id={dom_id}>
    <%= post.title %>
  </div>
</div>
```

### Async Data Loading

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:page_title, "Dashboard")
   |> assign_async(:stats, fn -> {:ok, %{stats: fetch_stats()}} end)
   |> assign_async(:recent_orders, fn -> {:ok, %{recent_orders: fetch_orders()}} end)}
end
```

Template handles loading/error states:

```heex
<.async_result :let={stats} assign={@stats}>
  <:loading>Loading stats...</:loading>
  <:failed :let={_reason}>Failed to load</:failed>
  <%= stats.total_users %> users
</.async_result>
```

### LiveView as Data Source

**Critical pattern**: LiveView loads data, function components render it. Never query databases in components:

```elixir
# Good: LiveView loads, passes to component
def mount(_params, _session, socket) do
  {:ok, assign(socket, :user, Accounts.get_user!(socket.assigns.current_user.id))}
end

def render(assigns) do
  ~H"""
  <.user_card user={@user} />
  """
end

# Bad: Component queries database
def user_card(assigns) do
  user = Accounts.get_user!(assigns.user_id)  # DON'T DO THIS
  ...
end
```

### Form Handling

```elixir
def mount(_params, _session, socket) do
  changeset = Accounts.change_user(%User{})
  {:ok, assign(socket, form: to_form(changeset))}
end

def handle_event("validate", %{"user" => params}, socket) do
  changeset =
    %User{}
    |> Accounts.change_user(params)
    |> Map.put(:action, :validate)

  {:noreply, assign(socket, form: to_form(changeset))}
end

def handle_event("save", %{"user" => params}, socket) do
  case Accounts.create_user(params) do
    {:ok, user} ->
      {:noreply,
       socket
       |> put_flash(:info, "User created")
       |> push_navigate(to: ~p"/users/#{user}")}

    {:error, changeset} ->
      {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

## Context Design

Contexts are bounded domain modules grouping related functionality:

```elixir
defmodule MyApp.Accounts do
  @moduledoc """
  The Accounts context handles user management and authentication.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.{User, Credential}

  # Public API - these are the context boundaries
  def get_user!(id), do: Repo.get!(User, id)

  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def authenticate_user(email, password) do
    with {:ok, user} <- get_user_by_email(email),
         {:ok, user} <- verify_password(user, password) do
      {:ok, user}
    end
  end

  # Private implementation details
  defp get_user_by_email(email) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp verify_password(user, password) do
    if Credential.valid_password?(user.credential, password) do
      {:ok, user}
    else
      {:error, :invalid_password}
    end
  end
end
```

### When to Split Contexts

Split when:
- Vocabularies diverge (same word means different things)
- Lifecycles differ significantly
- Team boundaries demand it
- Cross-cutting concerns emerge

### Cross-Context Communication

Use anti-corruption layers—convert data at boundaries:

```elixir
defmodule MyApp.Orders do
  alias MyApp.Accounts

  def create_order(user_id, items) do
    # Get user through Accounts context, not direct query
    user = Accounts.get_user!(user_id)

    # Convert to order-specific representation
    order_owner = %{id: user.id, name: user.name, email: user.email}

    %Order{}
    |> Order.changeset(%{owner: order_owner, items: items})
    |> Repo.insert()
  end
end
```

## Testing Phoenix

### Controller Tests

```elixir
defmodule MyAppWeb.UserControllerTest do
  use MyAppWeb.ConnCase, async: true

  describe "GET /users/:id" do
    test "renders user when found", %{conn: conn} do
      user = insert(:user)

      conn = get(conn, ~p"/users/#{user}")

      assert html_response(conn, 200) =~ user.name
    end

    test "returns 404 when not found", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/users/999999")
      end
    end
  end
end
```

### LiveView Tests

```elixir
defmodule MyAppWeb.PostLive.IndexTest do
  use MyAppWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "index" do
    test "lists posts", %{conn: conn} do
      post = insert(:post, title: "Hello World")

      {:ok, view, html} = live(conn, ~p"/posts")

      assert html =~ "Hello World"
    end

    test "creates new post", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/posts")

      view
      |> form("#post-form", post: %{title: "New Post"})
      |> render_submit()

      assert has_element?(view, ".post", "New Post")
    end

    test "navigates to post", %{conn: conn} do
      post = insert(:post)

      {:ok, view, _html} = live(conn, ~p"/posts")

      view
      |> element("a", post.title)
      |> render_click()

      assert_redirect(view, ~p"/posts/#{post}")
    end
  end
end
```

### phoenix_test for Unified Testing

```elixir
defmodule MyAppWeb.PurchaseFlowTest do
  use MyAppWeb.ConnCase, async: true
  use PhoenixTest

  test "complete purchase flow", %{conn: conn} do
    conn
    |> visit(~p"/products")
    |> click_link("Widget")
    |> click_button("Add to Cart")
    |> visit(~p"/cart")
    |> fill_in("Quantity", with: "2")
    |> click_button("Checkout")
    |> assert_has(".success", text: "Order placed")
  end
end
```
