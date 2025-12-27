# Oban Patterns

## Table of Contents

1. [Worker Basics](#worker-basics)
2. [Job Options](#job-options)
3. [Return Values and Error Handling](#return-values-and-error-handling)
4. [Unique Jobs](#unique-jobs)
5. [Queue Configuration](#queue-configuration)
6. [Testing Oban](#testing-oban)
7. [Oban Pro Features](#oban-pro-features)

## Worker Basics

### Simple Worker

```elixir
defmodule MyApp.Workers.EmailWorker do
  use Oban.Worker, queue: :mailers

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"to" => to, "template" => template, "data" => data}}) do
    case MyApp.Mailer.send(to, template, data) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

# Enqueue a job
%{to: "user@example.com", template: "welcome", data: %{name: "Alice"}}
|> MyApp.Workers.EmailWorker.new()
|> Oban.insert()
```

### String Keys in Args

Always use string keys when pattern matching args (JSON serialization):

```elixir
# Good: string keys
def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
  ...
end

# Bad: atom keys won't match
def perform(%Oban.Job{args: %{user_id: user_id}}) do
  # This won't match - args are string-keyed from JSON
end
```

### Transactional Job Insertion

Jobs are inserted in the same transaction as other changes:

```elixir
def create_order(attrs) do
  Multi.new()
  |> Multi.insert(:order, Order.changeset(%Order{}, attrs))
  |> Multi.run(:confirmation_job, fn _repo, %{order: order} ->
    %{order_id: order.id}
    |> MyApp.Workers.OrderConfirmation.new()
    |> Oban.insert()
  end)
  |> Repo.transaction()
end

# Job only exists if transaction commits
```

## Job Options

```elixir
defmodule MyApp.Workers.ReportWorker do
  use Oban.Worker,
    queue: :reports,
    max_attempts: 5,
    priority: 1,  # 0 is highest priority
    tags: ["reports", "analytics"]

  @impl Oban.Worker
  def perform(job), do: ...
end

# Per-job options override defaults
%{report_id: id}
|> MyApp.Workers.ReportWorker.new(
  priority: 0,  # Urgent
  scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second),  # 1 hour later
  max_attempts: 10,
  queue: :urgent_reports  # Override queue
)
|> Oban.insert()
```

### Scheduled Jobs

```elixir
# Schedule for specific time
MyApp.Workers.ReminderWorker.new(%{user_id: id})
|> Oban.insert(scheduled_at: ~U[2024-12-25 09:00:00Z])

# Schedule relative to now
MyApp.Workers.FollowUpWorker.new(%{lead_id: id})
|> Oban.insert(schedule_in: {1, :hour})

# Or in seconds
|> Oban.insert(schedule_in: 3600)
```

## Return Values and Error Handling

```elixir
defmodule MyApp.Workers.ExternalAPIWorker do
  use Oban.Worker, queue: :external, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"endpoint" => endpoint, "payload" => payload}}) do
    case HTTPClient.post(endpoint, payload) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 429}} ->
        # Rate limited - retry after delay
        {:snooze, 300}  # 5 minutes

      {:ok, %{status: 400, body: body}} ->
        # Client error - don't retry
        {:cancel, "Bad request: #{inspect(body)}"}

      {:ok, %{status: status}} when status >= 500 ->
        # Server error - retry with backoff
        {:error, "Server error: #{status}"}

      {:error, :timeout} ->
        {:error, :timeout}  # Will retry

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Custom backoff for rate limits
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt, unsaved_error: error}) do
    case error do
      %{reason: %{status: 429}} ->
        # Longer wait for rate limits
        300

      _ ->
        # Exponential backoff with jitter
        trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
    end
  end
end
```

### Return Value Summary

| Return | Effect |
|--------|--------|
| `:ok` | Job completed successfully |
| `{:ok, result}` | Success, result stored in job |
| `{:error, reason}` | Job failed, will retry |
| `{:cancel, reason}` | Job cancelled, no retry |
| `{:snooze, seconds}` | Reschedule without counting as attempt |
| `{:discard, reason}` | Discard job, no retry (deprecated, use `:cancel`) |

## Unique Jobs

Prevent duplicate jobs:

```elixir
defmodule MyApp.Workers.SyncWorker do
  use Oban.Worker,
    queue: :sync,
    unique: [
      period: 60,  # seconds
      fields: [:worker, :args],
      keys: [:user_id],  # specific arg keys
      states: [:available, :scheduled, :executing]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    MyApp.Sync.sync_user(user_id)
  end
end

# These are considered duplicates within 60 seconds
MyApp.Workers.SyncWorker.new(%{user_id: 1, source: "web"})
MyApp.Workers.SyncWorker.new(%{user_id: 1, source: "api"})
# Second insert is no-op (same user_id)
```

### Replace vs Ignore

```elixir
use Oban.Worker,
  unique: [
    period: :infinity,
    keys: [:order_id],
    replace: [:scheduled_at]  # Update scheduled time on conflict
  ]
```

## Queue Configuration

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    default: 10,        # 10 concurrent workers
    mailers: 20,        # High volume
    reports: 5,         # Resource intensive
    external: [limit: 5, paused: false],  # Explicit options
    critical: [limit: 50, dispatch_cooldown: 5]
  ],
  plugins: [
    Oban.Plugins.Pruner,  # Clean old jobs
    {Oban.Plugins.Cron, crontab: [
      {"0 * * * *", MyApp.Workers.HourlySync},
      {"0 0 * * *", MyApp.Workers.DailyReport},
      {"*/5 * * * *", MyApp.Workers.HealthCheck, queue: :critical}
    ]}
  ]

# config/test.exs
config :my_app, Oban,
  testing: :inline  # Jobs execute immediately in test
```

### Dynamic Queue Control

```elixir
# Pause a queue
Oban.pause_queue(queue: :external)

# Resume
Oban.resume_queue(queue: :external)

# Scale workers
Oban.scale_queue(queue: :mailers, limit: 50)

# Drain for shutdown
Oban.drain_queue(queue: :default, with_safety: true)
```

## Testing Oban

### Setup

```elixir
# test/support/data_case.ex
setup tags do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)

  unless tags[:async] do
    Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
  end

  :ok
end
```

### Unit Testing Workers

```elixir
defmodule MyApp.Workers.EmailWorkerTest do
  use MyApp.DataCase, async: true
  use Oban.Testing, repo: MyApp.Repo

  alias MyApp.Workers.EmailWorker

  describe "perform/1" do
    test "sends email successfully" do
      user = insert(:user)

      # perform_job validates args schema and executes
      assert :ok = perform_job(EmailWorker, %{
        to: user.email,
        template: "welcome",
        data: %{name: user.name}
      })
    end

    test "returns error on invalid email" do
      assert {:error, :invalid_email} = perform_job(EmailWorker, %{
        to: "not-an-email",
        template: "welcome",
        data: %{}
      })
    end
  end
end
```

### Integration Testing

```elixir
defmodule MyApp.OrdersTest do
  use MyApp.DataCase, async: true
  use Oban.Testing, repo: MyApp.Repo

  alias MyApp.Orders

  test "creating order enqueues confirmation email" do
    user = insert(:user)

    {:ok, order} = Orders.create_order(user, %{product_id: 1})

    # Assert job was enqueued with correct args
    assert_enqueued worker: MyApp.Workers.OrderConfirmation,
                    args: %{order_id: order.id}
  end

  test "confirmation not enqueued on validation failure" do
    user = insert(:user)

    {:error, _} = Orders.create_order(user, %{})  # Missing product

    refute_enqueued worker: MyApp.Workers.OrderConfirmation
  end
end
```

### Testing with drain_queue

```elixir
test "full order flow" do
  user = insert(:user)

  {:ok, order} = Orders.create_order(user, %{product_id: 1})

  # Process all enqueued jobs synchronously
  assert %{success: 1} = Oban.drain_queue(queue: :mailers)

  # Verify side effects
  assert_email_sent(to: user.email, subject: "Order Confirmation")
end
```

### Inline Mode for Simple Tests

```elixir
# config/test.exs
config :my_app, Oban, testing: :inline

# Jobs execute immediately when inserted
{:ok, order} = Orders.create_order(user, attrs)
# Confirmation email already sent at this point
```

## Oban Pro Features

### Workflows (Job Dependencies)

```elixir
alias Oban.Pro.Workers.Workflow

def process_order(order) do
  Workflow.new()
  |> Workflow.add(:validate, ValidateWorker.new(%{order_id: order.id}))
  |> Workflow.add(:charge, ChargeWorker.new(%{order_id: order.id}),
      deps: [:validate])
  |> Workflow.add(:fulfill, FulfillWorker.new(%{order_id: order.id}),
      deps: [:charge])
  |> Workflow.add(:notify, NotifyWorker.new(%{order_id: order.id}),
      deps: [:fulfill])
  |> Oban.insert_all()
end
```

### Batches (Parallel with Callback)

```elixir
alias Oban.Pro.Workers.Batch

def process_users(user_ids) do
  jobs = Enum.map(user_ids, &SyncUserWorker.new(%{user_id: &1}))

  Batch.new(jobs,
    callback: BatchCallbackWorker,
    callback_args: %{total: length(user_ids)}
  )
  |> Oban.insert_all()
end

defmodule BatchCallbackWorker do
  use Oban.Pro.Workers.Batch

  @impl true
  def handle_completed(%{args: %{"total" => total}}, results) do
    Logger.info("Processed #{total} users: #{inspect(results)}")
    :ok
  end
end
```

### Structured Jobs (Type-Safe Args)

```elixir
defmodule MyApp.Workers.InvoiceWorker do
  use Oban.Pro.Worker

  args do
    field :invoice_id, :integer, required: true
    field :notify, :boolean, default: true
    field :format, Ecto.Enum, values: [:pdf, :html], default: :pdf
  end

  @impl true
  def process(%__MODULE__{invoice_id: id, notify: notify, format: format}) do
    # Args are validated and typed
    invoice = Invoices.get!(id)
    generate_and_send(invoice, format, notify)
  end
end
```

### Rate Limiting

```elixir
defmodule MyApp.Workers.APIWorker do
  use Oban.Pro.Worker,
    queue: :external

  @impl Oban.Pro.Worker
  def process(job) do
    ...
  end

  @impl Oban.Pro.Worker
  def rate_limit(_job) do
    # 100 requests per minute
    {:rate_limit, [allowed: 100, period: 60]}
  end
end
```
