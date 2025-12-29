# ADR 004: Caddy Integration

**Status:** Accepted
**Date:** 2025-12-28

## Context

Otturnaut needs to configure Caddy as a reverse proxy, dynamically adding and removing routes when applications are deployed or stopped. Caddy provides an admin API for runtime configuration changes.

## Decision

We integrate with Caddy via its JSON admin API (default: `localhost:2019`), managing routes under a dedicated server named `otturnaut`.

### API Quirks Discovered

Several non-obvious behaviors required workarounds:

#### 1. Trailing Slash Required

Caddy redirects requests without trailing slashes (e.g., `/config` → `/config/`). During redirects, POST request bodies are lost.

**Solution:** Always append trailing slashes to config paths.

```elixir
# Wrong - body lost on redirect
POST http://localhost:2019/config

# Correct
POST http://localhost:2019/config/
```

#### 2. ID Endpoint Location

The `/id/{id}` endpoint for accessing objects by their `@id` field is at the API root, not under `/config/`.

```elixir
# Wrong
GET http://localhost:2019/config/id/myapp

# Correct
GET http://localhost:2019/id/myapp
```

#### 3. Automatic HTTPS Binding

When a route includes host matching, Caddy's automatic HTTPS feature attempts to:
- Bind to port 80 for HTTP→HTTPS redirects
- Bind to port 443 for HTTPS

This fails without root privileges and causes 500 errors when adding routes.

**Solution:** Disable automatic HTTPS on the server for development/testing:

```json
{
  "servers": {
    "otturnaut": {
      "listen": [":8080"],
      "automatic_https": {
        "disable": true
      }
    }
  }
}
```

In production with proper privileges (via `setcap`), automatic HTTPS can remain enabled.

#### 4. Empty Config Bootstrapping

When Caddy's config is `null` (fresh start), you cannot POST to nested paths like `/config/apps/http/servers`. The parent path must exist first.

**Solution:** Check if config is `null` and POST the full structure to `/config/` in one request:

```json
{
  "apps": {
    "http": {
      "servers": {
        "otturnaut": {
          "listen": [":80", ":443"],
          "routes": []
        }
      }
    }
  }
}
```

### Route Structure

Routes are stored with an `@id` field for later retrieval/deletion:

```json
{
  "@id": "myapp",
  "match": [{"host": ["myapp.com"]}],
  "handle": [{
    "handler": "reverse_proxy",
    "upstreams": [{"dial": "localhost:3000"}]
  }]
}
```

## Consequences

### Benefits

- **Dynamic configuration** — Routes can be added/removed without restarting Caddy
- **Automatic HTTPS** — Caddy handles certificate provisioning (when enabled)
- **ID-based access** — Routes can be retrieved and deleted by ID without tracking array indices

### Drawbacks

- **API quirks** — Several non-obvious behaviors required investigation and workarounds
- **State dependency** — Must handle various config states (null, partial, complete)

### Implications

- Client code must ensure trailing slashes on all paths
- Integration tests require Caddy to be running
- Development/testing needs `disable_auto_https: true` option
