# ADR 002: Command Execution Design

**Status:** Accepted
**Date:** 2025-12-28

## Context

Otturnaut needs to execute external commands for deployments (git clone, docker build, docker run) and status checks. Key requirements:

- Real-time output streaming to Mission Control
- Non-blocking execution (parallel deployments)
- Structured error handling
- Visibility into stdout vs stderr origin

## Decision

### Execution model

Use Erlang Ports wrapped in processes managed by a Task.Supervisor.

- **Async execution** — Commands run in separate processes, output streams to a subscriber PID via messages
- **Sync convenience** — A blocking wrapper for quick commands (status checks)

### Output streaming

- **Merged stream with metadata** — stdout and stderr are interleaved in arrival order, but each message is tagged with its source
- **Line-buffered** — Output is sent line-by-line for cleaner display

Message format:

```elixir
{:command_output, runner_pid, {:stdout | :stderr, line}}
{:command_done, runner_pid, %Result{}}
```

### Error handling

Structured result type with explicit error reasons:

```elixir
%Result{
  status: :ok | :error,
  exit_code: non_neg_integer() | nil,
  output: String.t(),
  error: {:exit, code} | :timeout | :command_not_found | :runner_crashed | nil,
  duration_ms: non_neg_integer()
}
```

### Supervision

Runners are started under a Task.Supervisor with `:temporary` restart strategy:

- No automatic restarts — a crashed runner reports failure to subscriber
- Clean shutdown — all runners terminate when Otturnaut stops
- Tracking — ability to list and cancel running commands

## Consequences

### Benefits

- **Real-time feedback** — Mission Control sees build progress as it happens
- **Non-blocking** — Multiple deployments can run in parallel
- **Debuggable** — Tagged output makes it clear where each line came from
- **Predictable failures** — Structured errors are easier to handle than parsing stderr

### Drawbacks

- **More complex than System.cmd** — Port handling requires more code
- **Line buffering edge cases** — Very long lines or missing final newlines need handling

### Implications

- Need to handle Port messages and exit signals correctly
- Subscriber must be prepared to receive messages asynchronously
- Full output is accumulated for the final Result (memory consideration for very large outputs)
