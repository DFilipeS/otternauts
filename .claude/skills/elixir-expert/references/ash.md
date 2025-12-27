# Ash Framework Patterns

## Table of Contents

1. [Resource Basics](#resource-basics)
2. [Actions](#actions)
3. [Attributes and Relationships](#attributes-and-relationships)
4. [Policies](#policies)
5. [Calculations and Aggregates](#calculations-and-aggregates)
6. [Code Interface](#code-interface)
7. [AshPhoenix Integration](#ashphoenix-integration)
8. [Testing Ash](#testing-ash)

## Resource Basics

Ash resources combine schema, behavior, and authorization in one declaration:

```elixir
defmodule MyApp.Support.Ticket do
  use Ash.Resource,
    domain: MyApp.Support,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "tickets"
    repo MyApp.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :open do
      accept [:subject, :body]
      change set_attribute(:status, :open)
      change relate_actor(:reporter)
    end

    update :close do
      accept []
      change set_attribute(:status, :closed)
      change set_attribute(:closed_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :subject, :string do
      allow_nil? false
      public? true
    end

    attribute :body, :string, public?: true
    attribute :status, :atom, constraints: [one_of: [:open, :in_progress, :closed]]
    attribute :closed_at, :utc_datetime

    timestamps()
  end

  relationships do
    belongs_to :reporter, MyApp.Accounts.User
    belongs_to :assignee, MyApp.Accounts.User
    has_many :comments, MyApp.Support.Comment
  end
end
```

Domain groups related resources:

```elixir
defmodule MyApp.Support do
  use Ash.Domain

  resources do
    resource MyApp.Support.Ticket
    resource MyApp.Support.Comment
  end
end
```

## Actions

### Named Actions Express Intent

Prefer named actions over generic CRUD:

```elixir
actions do
  # Generic CRUD for simple cases
  defaults [:read, :destroy]

  # Named actions express domain operations
  create :open do
    accept [:subject, :body]
    change set_attribute(:status, :open)
  end

  create :submit_via_email do
    accept [:subject, :body, :email_message_id]
    change set_attribute(:source, :email)
  end

  update :assign do
    accept []
    argument :assignee_id, :uuid, allow_nil?: false
    change manage_relationship(:assignee_id, :assignee, type: :append)
    change set_attribute(:status, :in_progress)
  end

  update :escalate do
    accept []
    argument :reason, :string, allow_nil?: false
    change set_attribute(:priority, :high)
    change {MyApp.Changes.NotifyManager, reason: arg(:reason)}
  end
end
```

### Accept Lists Whitelist Attributes

```elixir
create :register do
  accept [:email, :name]  # Only these can be set by caller
  change set_attribute(:role, :user)  # Always set internally
end
```

### Arguments for Non-Attribute Data

```elixir
update :change_password do
  accept []

  argument :current_password, :string, allow_nil?: false, sensitive?: true
  argument :new_password, :string, allow_nil?: false, sensitive?: true
  argument :password_confirmation, :string, allow_nil?: false, sensitive?: true

  validate confirm(:new_password, :password_confirmation)
  validate {MyApp.Validations.CorrectPassword, attribute: :current_password}

  change {MyApp.Changes.HashPassword, source: :new_password}
end
```

### Custom Changes

```elixir
defmodule MyApp.Changes.HashPassword do
  use Ash.Resource.Change

  def change(changeset, opts, _context) do
    source = opts[:source] || :password

    case Ash.Changeset.get_argument(changeset, source) do
      nil -> changeset
      password ->
        hashed = Bcrypt.hash_pwd_salt(password)
        Ash.Changeset.change_attribute(changeset, :hashed_password, hashed)
    end
  end
end
```

## Attributes and Relationships

### Attribute Options

```elixir
attributes do
  uuid_primary_key :id

  attribute :email, :ci_string do  # Case-insensitive string
    allow_nil? false
    public? true
  end

  attribute :status, :atom do
    constraints [one_of: [:draft, :published, :archived]]
    default :draft
  end

  attribute :metadata, :map  # Flexible JSON storage

  attribute :tags, {:array, :string}, default: []

  create_timestamp :inserted_at
  update_timestamp :updated_at
end
```

### Relationships

```elixir
relationships do
  belongs_to :author, MyApp.Accounts.User do
    allow_nil? false
  end

  has_many :comments, MyApp.Blog.Comment do
    destination_attribute :post_id
  end

  has_many :published_comments, MyApp.Blog.Comment do
    filter expr(status == :published)
  end

  many_to_many :tags, MyApp.Blog.Tag do
    through MyApp.Blog.PostTag
    source_attribute_on_join_resource :post_id
    destination_attribute_on_join_resource :tag_id
  end
end
```

### Managing Relationships in Actions

```elixir
create :create do
  accept [:title, :body]

  argument :tag_ids, {:array, :uuid}

  change manage_relationship(:tag_ids, :tags, type: :append_and_remove)
end

update :update do
  accept [:title, :body]

  argument :add_tag_id, :uuid
  argument :remove_tag_id, :uuid

  change manage_relationship(:add_tag_id, :tags, type: :append)
  change manage_relationship(:remove_tag_id, :tags, type: :remove)
end
```

## Policies

Policies define authorization rules:

```elixir
policies do
  # Bypass for admins
  bypass actor_attribute_equals(:role, :admin) do
    authorize_if always()
  end

  # Read: anyone can read published, authors can read their own
  policy action_type(:read) do
    authorize_if expr(status == :published)
    authorize_if relates_to_actor_via(:author)
  end

  # Create: authenticated users only
  policy action_type(:create) do
    authorize_if actor_present()
  end

  # Update/destroy: only authors
  policy action_type([:update, :destroy]) do
    authorize_if relates_to_actor_via(:author)
  end

  # Specific action policies
  policy action(:publish) do
    authorize_if relates_to_actor_via(:author)
    authorize_if actor_attribute_equals(:role, :editor)
  end
end
```

### Field Policies

```elixir
field_policies do
  field_policy :email do
    authorize_if relates_to_actor_via(:self)
    authorize_if actor_attribute_equals(:role, :admin)
  end

  field_policy :hashed_password do
    authorize_if never()  # Never expose
  end
end
```

## Calculations and Aggregates

### Expression Calculations

```elixir
calculations do
  calculate :full_name, :string, expr(first_name <> " " <> last_name)

  calculate :display_name, :string, expr(
    if is_nil(nickname) do
      first_name <> " " <> last_name
    else
      nickname
    end
  )

  calculate :status_label, :string, expr(
    case status do
      :draft -> "Draft"
      :published -> "Published"
      :archived -> "Archived"
    end
  )
end
```

### Module Calculations

```elixir
calculations do
  calculate :age, :integer, {MyApp.Calculations.Age, field: :birth_date}
end

defmodule MyApp.Calculations.Age do
  use Ash.Resource.Calculation

  def calculate(records, opts, _context) do
    field = opts[:field]
    today = Date.utc_today()

    Enum.map(records, fn record ->
      birth_date = Map.get(record, field)
      if birth_date, do: years_between(birth_date, today), else: nil
    end)
  end

  defp years_between(from, to) do
    # Age calculation logic
  end
end
```

### Aggregates

```elixir
aggregates do
  count :comment_count, :comments

  count :published_comment_count, :comments do
    filter expr(status == :published)
  end

  sum :total_sales, :orders, :amount

  first :latest_comment_at, :comments, :inserted_at do
    sort inserted_at: :desc
  end

  list :tag_names, :tags, :name
end
```

## Code Interface

Generate clean function APIs:

```elixir
code_interface do
  define :open, args: [:subject, :body]
  define :close
  define :assign, args: [:assignee_id]

  define :get_by_id, get_by: [:id], action: :read
  define :list_open, action: :read, args: [] do
    filter expr(status == :open)
  end
end
```

Usage:

```elixir
# Instead of: Ash.create(Ticket, %{subject: "Help", body: "..."}, action: :open)
{:ok, ticket} = MyApp.Support.Ticket.open("Help", "Need assistance")

# Instead of: Ash.get(Ticket, id)
{:ok, ticket} = MyApp.Support.Ticket.get_by_id(id)

# Bang variants for raising
ticket = MyApp.Support.Ticket.get_by_id!(id)
```

## AshPhoenix Integration

### Forms

```elixir
defmodule MyAppWeb.TicketLive.New do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    form =
      MyApp.Support.Ticket
      |> AshPhoenix.Form.for_create(:open, actor: socket.assigns.current_user)
      |> to_form()

    {:ok, assign(socket, form: form)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, form: to_form(form))}
  end

  def handle_event("submit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, ticket} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ticket opened")
         |> push_navigate(to: ~p"/tickets/#{ticket}")}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def render(assigns) do
    ~H"""
    <.form for={@form} phx-change="validate" phx-submit="submit">
      <.input field={@form[:subject]} label="Subject" />
      <.input field={@form[:body]} type="textarea" label="Description" />
      <.button>Open Ticket</.button>
    </.form>
    """
  end
end
```

### Update Forms

```elixir
def mount(%{"id" => id}, _session, socket) do
  ticket = MyApp.Support.Ticket.get_by_id!(id)

  form =
    ticket
    |> AshPhoenix.Form.for_update(:assign, actor: socket.assigns.current_user)
    |> to_form()

  {:ok, assign(socket, ticket: ticket, form: form)}
end
```

### Nested Forms

```elixir
form =
  MyApp.Blog.Post
  |> AshPhoenix.Form.for_create(:create,
    actor: user,
    forms: [
      comments: [
        type: :list,
        resource: MyApp.Blog.Comment,
        create_action: :create
      ]
    ]
  )
```

## Testing Ash

### Basic Action Tests

```elixir
defmodule MyApp.Support.TicketTest do
  use MyApp.DataCase, async: true

  describe "open/2" do
    test "creates ticket with valid data" do
      user = insert(:user)

      assert {:ok, ticket} =
               MyApp.Support.Ticket.open("Help needed", "Description",
                 actor: user
               )

      assert ticket.subject == "Help needed"
      assert ticket.status == :open
      assert ticket.reporter_id == user.id
    end

    test "fails without subject" do
      user = insert(:user)

      assert {:error, changeset} =
               MyApp.Support.Ticket.open(nil, "Description", actor: user)

      assert "is required" in errors_on(changeset).subject
    end
  end

  describe "policies" do
    test "users can read their own tickets" do
      user = insert(:user)
      ticket = insert(:ticket, reporter: user)

      assert {:ok, _} = MyApp.Support.Ticket.get_by_id(ticket.id, actor: user)
    end

    test "users cannot read others' private tickets" do
      user = insert(:user)
      other_ticket = insert(:ticket, status: :draft)

      assert {:error, %Ash.Error.Forbidden{}} =
               MyApp.Support.Ticket.get_by_id(other_ticket.id, actor: user)
    end
  end
end
```

### Testing with Ash.Test

```elixir
defmodule MyApp.Support.TicketTest do
  use MyApp.DataCase, async: true
  import Ash.Test

  test "escalate notifies manager" do
    ticket = insert(:ticket, status: :open)
    user = insert(:user, role: :support)

    expect(MyApp.NotifierMock, :notify_escalation, fn ^ticket, _reason -> :ok end)

    assert {:ok, updated} =
             ticket
             |> Ash.Changeset.for_update(:escalate, %{reason: "Urgent"}, actor: user)
             |> Ash.update()

    assert updated.priority == :high
  end
end
```
