# web.zig

Small, composable Zig libraries for server-complete HTML applications.

The default architecture is intentionally old-fashioned:

1. Authenticate and parse a bounded request.
2. Load all state needed for the first useful view.
3. Construct a typed application-owned view model.
4. Render semantic HTML on the server.
5. Let normal links and forms work without JavaScript.
6. Optionally add HTMX to improve later navigation and replacement.

The browser must not need JavaScript to discover information the server already
knows. JavaScript islands remain appropriate for browser-only APIs such as
WebAuthn, but they are application concerns.

## Modules

- `web_html`: context-safe, writer-first HTML rendering.
- `web_request`: bounded HTTP request parsing helpers.
- `web_response`: response, redirect, and content helpers.
- `web_router`: allocation-free route matching.
- `web_assets`: explicit embedded and disk-backed asset delivery.
- `web_cache`: conditional request and cache policy helpers.
- `web_security_headers`: explicit browser security policies.
- `web_server`: bounded `std.http` connection handling.
- `web_app`: optional Linux listener, worker queue, drain, signals, and periodic jobs.
- `web_htmx`: optional HTMX request and response semantics.
- `web_testing`: shared consumer and protocol test helpers.

Each module is independently importable. Applications own their database,
authentication, authorization, route policy, view models, CSS, and product
components. There is no middleware framework, service container, template
language, client state store, hydration layer, SSE, Datastar, or WebSocket
abstraction.

## Development

The exact Zig release is pinned in `.zigversion`, with archive
checksums in `.zig-sha256`.

```sh
zig build test journeys consumer
# Export the declared package files and exercise them in ReleaseSafe:
tools/package-check.sh
```

Committed consumers should use an immutable Git revision and Zig package hash.
During coordinated development, Zig's local package override or a temporary
path dependency can point at a neighboring checkout.

See [`docs/architecture.md`](docs/architecture.md) for invariants and
non-goals.

`web_app` supports one active App per process and one run attempt per instance.
Create a fresh App after shutdown or startup failure, and join `run` before
`deinit`. Register jobs before starting `run`. `requestShutdown` only affects
its owning instance; the prior SIGINT/SIGTERM handlers are restored on exit.
The idle timeout bounds the wait between requests and cumulative socket I/O
within each request. Partial headers, bodies and slow readers cannot replenish
the budget; handler work between socket calls is excluded. Zero disables these
network limits. Overloaded connections receive a nonblocking, best-effort 503.
Drain interrupts socket reads after
its deadline, but handlers and job callbacks must finish bounded work or check
`JobContext.stopping()` / `app.stopping`; arbitrary application code cannot be
forcibly interrupted. The runtime is optional; independent modules remain usable
on other operating systems.

The concurrency journey verifies every response and connection reuse. It does
not impose a universal throughput or memory floor. CI bounds the entire journey
process so regressions cannot leave the job waiting indefinitely.
