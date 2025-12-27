# Ecto Patterns

## Table of Contents

1. [Schema Design](#schema-design)
2. [Changeset Patterns](#changeset-patterns)
3. [Query Composition](#query-composition)
4. [Preloading Strategies](#preloading-strategies)
5. [Migrations](#migrations)
6. [Multi-tenancy](#multi-tenancy)
7. [Testing with Ecto](#testing-with-ecto)

## Schema Design

### Basic Schema

```elixir
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "posts" do
    field :title, :string
    field :body, :string
    field :status, Ecto.Enum, values: [:draft, :published, :archived]
    field :published_at, :utc_datetime
    field :view_count, :integer, default: 0

    belongs_to :author, MyApp.Accounts.User
    has_many :comments, MyApp.Blog.Comment
    many_to_many :tags, MyApp.Blog.Tag, join_through: "posts_tags"

    timestamps(type: :utc_datetime)
  end
end
```

### Embedded Schemas

For structured data that doesn't need its own table:

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema

  schema "users" do
    field :email, :string
    embeds_one :settings, Settings, on_replace: :update
    embeds_many :addresses, Address, on_replace: :delete
  end

  defmodule Settings do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :theme, :string, default: "light"
      field :notifications_enabled, :boolean, default: true
      field :timezone, :string, default: "UTC"
    end
  end

  defmodule Address do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :label, :string
      field :street, :string
      field :city, :string
      field :country, :string
    end
  end
end
```

### Virtual Fields

```elixir
schema "users" do
  field :email, :string
  field :password, :string, virtual: true  # Not persisted
  field :password_hash, :string

  field :full_name, :string, virtual: true  # Computed
end

def load_full_name(user) do
  %{user | full_name: "#{user.first_name} #{user.last_name}"}
end
```

## Changeset Patterns

### Separate Changesets for Different Operations

```elixir
defmodule MyApp.Accounts.User do
  # Registration: requires password, sets defaults
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password])
    |> validate_required([:email, :password])
    |> validate_email()
    |> validate_password()
    |> hash_password()
    |> put_change(:role, :user)
  end

  # Profile update: no password change
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :bio, :avatar_url])
    |> validate_length(:bio, max: 500)
  end

  # Password change: requires current password verification
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password()
    |> hash_password()
  end

  # Admin operations
  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:role, :verified, :suspended_at])
  end

  # Shared validations
  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, MyApp.Repo)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 12, max: 72)
    |> validate_format(:password, ~r/[a-z]/, message: "must include lowercase")
    |> validate_format(:password, ~r/[A-Z]/, message: "must include uppercase")
    |> validate_format(:password, ~r/[0-9]/, message: "must include number")
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    end
  end
end
```

### Custom Validations

```elixir
def changeset(invoice, attrs) do
  invoice
  |> cast(attrs, [:amount, :due_date, :customer_id])
  |> validate_required([:amount, :due_date])
  |> validate_number(:amount, greater_than: 0)
  |> validate_future_date(:due_date)
  |> validate_customer_active()
end

defp validate_future_date(changeset, field) do
  validate_change(changeset, field, fn _, date ->
    if Date.compare(date, Date.utc_today()) == :gt do
      []
    else
      [{field, "must be in the future"}]
    end
  end)
end

defp validate_customer_active(changeset) do
  case get_field(changeset, :customer_id) do
    nil -> changeset
    customer_id ->
      if MyApp.Customers.active?(customer_id) do
        changeset
      else
        add_error(changeset, :customer_id, "customer account is not active")
      end
  end
end
```

### Handling Associations

```elixir
def changeset(post, attrs) do
  post
  |> cast(attrs, [:title, :body])
  |> cast_assoc(:comments, with: &Comment.changeset/2)
  |> put_assoc(:tags, parse_tags(attrs))
end

defp parse_tags(%{"tags" => tag_names}) when is_list(tag_names) do
  Enum.map(tag_names, &get_or_create_tag/1)
end
defp parse_tags(_), do: []

defp get_or_create_tag(name) do
  Repo.get_by(Tag, name: name) || %Tag{name: name}
end
```

## Query Composition

### Building Queries Incrementally

```elixir
defmodule MyApp.Blog do
  import Ecto.Query

  def list_posts(criteria \\ []) do
    Post
    |> by_author(criteria[:author_id])
    |> by_status(criteria[:status])
    |> by_tag(criteria[:tag])
    |> published_since(criteria[:since])
    |> search(criteria[:search])
    |> order_by_criteria(criteria[:order_by])
    |> paginate(criteria[:page], criteria[:per_page])
    |> Repo.all()
  end

  # Each filter handles nil gracefully
  defp by_author(query, nil), do: query
  defp by_author(query, author_id) do
    where(query, [p], p.author_id == ^author_id)
  end

  defp by_status(query, nil), do: query
  defp by_status(query, status) do
    where(query, [p], p.status == ^status)
  end

  defp by_tag(query, nil), do: query
  defp by_tag(query, tag_name) do
    query
    |> join(:inner, [p], t in assoc(p, :tags))
    |> where([p, t], t.name == ^tag_name)
  end

  defp published_since(query, nil), do: query
  defp published_since(query, date) do
    where(query, [p], p.published_at >= ^date)
  end

  defp search(query, nil), do: query
  defp search(query, term) do
    term = "%#{term}%"
    where(query, [p], ilike(p.title, ^term) or ilike(p.body, ^term))
  end

  defp order_by_criteria(query, nil), do: order_by(query, [p], desc: p.inserted_at)
  defp order_by_criteria(query, :oldest), do: order_by(query, [p], asc: p.inserted_at)
  defp order_by_criteria(query, :popular), do: order_by(query, [p], desc: p.view_count)
  defp order_by_criteria(query, :title), do: order_by(query, [p], asc: p.title)

  defp paginate(query, nil, _), do: query
  defp paginate(query, page, per_page) do
    per_page = per_page || 20
    offset = (page - 1) * per_page

    query
    |> limit(^per_page)
    |> offset(^offset)
  end
end
```

### Reusable Query Modules

```elixir
defmodule MyApp.Blog.PostQuery do
  import Ecto.Query
  alias MyApp.Blog.Post

  def base, do: Post

  def published(query \\ base()) do
    where(query, [p], p.status == :published and not is_nil(p.published_at))
  end

  def by_author(query \\ base(), author_id) do
    where(query, [p], p.author_id == ^author_id)
  end

  def with_author(query \\ base()) do
    preload(query, :author)
  end

  def with_comment_count(query \\ base()) do
    from p in query,
      left_join: c in assoc(p, :comments),
      group_by: p.id,
      select_merge: %{comment_count: count(c.id)}
  end

  def recent(query \\ base(), limit \\ 10) do
    query
    |> order_by([p], desc: p.inserted_at)
    |> limit(^limit)
  end
end

# Usage
PostQuery.base()
|> PostQuery.published()
|> PostQuery.by_author(user.id)
|> PostQuery.with_comment_count()
|> PostQuery.recent(5)
|> Repo.all()
```

## Preloading Strategies

### Basic Preloading

```elixir
# Separate queries (default) - often faster for has_many
Repo.all(Post) |> Repo.preload(:comments)

# Join preload - one query, good for belongs_to
Repo.all(from p in Post, preload: [author: :profile])

# Preload in initial query
Repo.all(from p in Post, preload: [:author, :tags])
```

### Custom Preload Queries

```elixir
# Only approved comments, sorted
comments_query = from c in Comment,
  where: c.status == :approved,
  order_by: [desc: c.inserted_at],
  limit: 5

posts = Repo.all(
  from p in Post,
    preload: [comments: ^comments_query]
)

# Nested preloads with custom queries
users_query = from u in User, select: %{id: u.id, name: u.name}

posts = Repo.all(
  from p in Post,
    preload: [comments: [author: ^users_query]]
)
```

### Avoiding N+1 with Dataloader (for GraphQL)

```elixir
defmodule MyApp.Dataloader do
  def data do
    Dataloader.new()
    |> Dataloader.add_source(:blog, blog_source())
  end

  defp blog_source do
    Dataloader.Ecto.new(MyApp.Repo,
      query: &blog_query/2
    )
  end

  defp blog_query(Comment, _args) do
    from c in Comment, where: c.status == :approved
  end

  defp blog_query(queryable, _args), do: queryable
end
```

## Migrations

### Safe Migration Practices

```elixir
defmodule MyApp.Repo.Migrations.AddIndexToPosts do
  use Ecto.Migration

  # Concurrent index - won't lock table
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:posts, [:author_id], concurrently: true)
  end
end
```

### Two-Step Column Removal

**Step 1**: Remove from schema, keep in database

```elixir
# In schema - remove the field
# field :deprecated_field, :string  # REMOVED

# Deploy this first
```

**Step 2**: Migration to remove column

```elixir
defmodule MyApp.Repo.Migrations.RemoveDeprecatedField do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove :deprecated_field
    end
  end
end
```

### Batch Data Migrations

```elixir
defmodule MyApp.Repo.Migrations.BackfillSlugs do
  use Ecto.Migration
  import Ecto.Query

  @batch_size 1000
  @throttle_ms 100

  def up do
    throttle_change_in_batches(&backfill_batch/1)
  end

  defp backfill_batch(last_id) do
    posts =
      from(p in "posts",
        where: is_nil(p.slug) and p.id > ^last_id,
        order_by: p.id,
        limit: @batch_size,
        select: %{id: p.id, title: p.title}
      )
      |> repo().all()

    Enum.each(posts, fn post ->
      slug = Slug.slugify(post.title)
      repo().update_all(
        from(p in "posts", where: p.id == ^post.id),
        set: [slug: slug]
      )
    end)

    List.last(posts)[:id]
  end

  defp throttle_change_in_batches(fun, last_id \\ 0) do
    case fun.(last_id) do
      nil -> :ok
      new_last_id ->
        Process.sleep(@throttle_ms)
        throttle_change_in_batches(fun, new_last_id)
    end
  end

  def down, do: :ok
end
```

## Multi-tenancy

### Foreign Key-Based (Simpler)

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app

  require Ecto.Query

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:skip_org_id] || opts[:schema_migration] ->
        {query, opts}

      org_id = opts[:org_id] ->
        {Ecto.Query.where(query, org_id: ^org_id), opts}

      true ->
        raise "expected org_id or skip_org_id to be set"
    end
  end
end

# Usage
Repo.all(Post, org_id: current_org.id)
Repo.insert(post, org_id: current_org.id)
```

### Composite Foreign Keys for Safety

```elixir
defmodule MyApp.Repo.Migrations.AddCompositeConstraint do
  use Ecto.Migration

  def change do
    # Ensures comments can only reference posts in same org
    alter table(:comments) do
      add :org_id, references(:organizations), null: false
    end

    create index(:comments, [:org_id, :post_id])

    # Composite foreign key
    execute """
      ALTER TABLE comments
      ADD CONSTRAINT comments_post_org_fkey
      FOREIGN KEY (org_id, post_id)
      REFERENCES posts (org_id, id)
    """
  end
end
```

### Prefix-Based (Schema per Tenant)

```elixir
defmodule MyApp.Repo do
  def with_prefix(prefix) do
    %{__struct__: __MODULE__, prefix: prefix}
  end

  def all(queryable, opts \\ []) do
    prefix = opts[:prefix] || default_prefix()
    super(queryable, Keyword.put(opts, :prefix, prefix))
  end
end

# Usage
Repo.all(Post, prefix: "tenant_#{org.id}")
```

## Testing with Ecto

### DataCase Setup

```elixir
defmodule MyApp.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MyApp.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MyApp.DataCase
    end
  end

  setup tags do
    MyApp.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

### Testing Changesets

```elixir
defmodule MyApp.Accounts.UserTest do
  use MyApp.DataCase, async: true

  alias MyApp.Accounts.User

  describe "registration_changeset/2" do
    test "valid with proper attributes" do
      attrs = %{email: "test@example.com", password: "SecurePass123!"}
      changeset = User.registration_changeset(%User{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :password_hash)
    end

    test "invalid without email" do
      changeset = User.registration_changeset(%User{}, %{password: "SecurePass123!"})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).email
    end

    test "invalid with weak password" do
      attrs = %{email: "test@example.com", password: "weak"}
      changeset = User.registration_changeset(%User{}, attrs)

      refute changeset.valid?
      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end
  end
end
```

### Factories with ExMachina

```elixir
defmodule MyApp.Factory do
  use ExMachina.Ecto, repo: MyApp.Repo

  def user_factory do
    %MyApp.Accounts.User{
      email: sequence(:email, &"user#{&1}@example.com"),
      name: "Test User",
      password_hash: Bcrypt.hash_pwd_salt("password123")
    }
  end

  def post_factory do
    %MyApp.Blog.Post{
      title: sequence(:title, &"Post #{&1}"),
      body: "Post content",
      status: :draft,
      author: build(:user)  # build, not insert - avoids extra DB calls
    }
  end

  def published_post_factory do
    struct!(
      post_factory(),
      status: :published,
      published_at: DateTime.utc_now()
    )
  end
end
```

### Testing Async Processes

```elixir
defmodule MyApp.WorkerTest do
  use MyApp.DataCase, async: true

  test "worker processes user" do
    user = insert(:user)

    # Allow the worker process to use this test's DB connection
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker_pid)

    # Or use shared mode for LiveView tests
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
  end
end
```
