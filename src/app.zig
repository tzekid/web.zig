//! Server lifecycle: listener, accept loop, bounded worker pool, graceful
//! drain, signal handling, periodic jobs, and health counters.
//!
//! Linux only, with one active App per process. The accept task either queues a connection or
//! attempts a nonblocking 503 immediately. The idle timeout bounds waiting between
//! requests and cumulative socket I/O within each request. Time spent in handlers
//! between socket calls is excluded; partial progress does not reset the budget. Shutdown
//! stops accepting, drains queued and in-flight connections up to a
//! deadline, then shuts down straggling sockets and reports that it had to.
//! Handlers and jobs must finish bounded work or cooperate with stopping();
//! a socket shutdown cannot interrupt arbitrary application code.

const std = @import("std");
const web_server = @import("web_server");
const web_router = @import("web_router");
const ConnectionIo = @import("connection_io.zig");

pub const Error = error{
    Unsupported,
    OutOfMemory,
    ListenFailed,
    ForcedShutdown,
    AlreadyRunning,
    AlreadyRun,
    TooManyJobs,
};

pub const Counters = struct {
    connections_accepted: u64 = 0,
    requests: u64 = 0,
    responses_5xx: u64 = 0,
    queue_rejections: u64 = 0,
    forced_closes: u64 = 0,
};

pub const RequestLog = struct {
    method: std.http.Method,
    target: []const u8,
    status: std.http.Status,
    duration_ns: u64,
};

pub const JobContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *App,

    pub fn stopping(context: *const JobContext) bool {
        return context.app.stopping.load(.acquire);
    }
};

pub const Job = struct {
    name: []const u8,
    interval_ms: u64,
    run: *const fn (context: *JobContext) anyerror!void,
};

pub const RequestContext = struct {
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    io: std.Io,
    app: *App,
    peer_address: std.Io.net.IpAddress,
};

pub const Options = struct {
    address: std.Io.net.IpAddress,
    workers: ?usize = null,
    queue_depth: ?usize = null,
    connection: web_server.ConnectionOptions = .{},
    /// Initial idle wait and per-request socket I/O budget; zero disables both.
    idle_timeout_ms: u64 = 15_000,
    drain_timeout_ms: u64 = 10_000,
    healthz: bool = true,
    /// Called with every lifecycle anomaly; the lifecycle itself never prints.
    on_error: *const fn (err: anyerror, note: []const u8) void,
    on_request: ?*const fn (log: RequestLog) void = null,
};

/// The signal handler must be async-signal-safe: it stores a flag and calls
/// shutdown(2) on the listener so the blocked accept returns. Everything else
/// happens on ordinary threads.
var signal_listener_socket: std.atomic.Value(i64) = .init(-1);
var signal_requested: std.atomic.Value(bool) = .init(false);
var signal_readers: std.atomic.Value(usize) = .init(0);
// Held only for short ownership changes and shutdown(2), never user code.
var owner_mutex: std.atomic.Mutex = .unlocked;
var active_app: ?*App = null;

fn lockOwner() void {
    while (!owner_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    _ = signal_readers.fetchAdd(1, .seq_cst);
    defer _ = signal_readers.fetchSub(1, .seq_cst);
    signal_requested.store(true, .release);
    const handle = signal_listener_socket.load(.seq_cst);
    if (handle >= 0) {
        _ = std.os.linux.shutdown(@intCast(handle), std.os.linux.SHUT.RDWR);
    }
}

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    queue: std.Io.Queue(std.Io.net.Stream),
    queue_buffer: []std.Io.net.Stream,
    workers: []?std.Thread,
    /// One slot per worker: the fd it is currently serving, -1 when idle.
    /// Force-close during drain shuts these down to unblock stalled reads.
    active_sockets: []std.atomic.Value(i64),
    /// True while the worker is inside a handler (not waiting between
    /// keep-alive requests). Drain closes idle connections immediately and
    /// only in-handler connections wait for the deadline.
    active_in_handler: []std.atomic.Value(bool),
    job_slots: [max_jobs]?Job = @splat(null),
    job_threads: [max_jobs]?std.Thread = @splat(null),
    job_count: usize = 0,
    job_mutex: std.Io.Mutex = .init,
    job_condition: std.Io.Condition = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    has_run: bool = false, // protected by owner_mutex
    force_stopping: bool = false, // protected by drain_mutex
    in_flight: std.atomic.Value(usize) = .init(0),
    queued: std.atomic.Value(usize) = .init(0),
    drain_mutex: std.Io.Mutex = .init,
    drain_condition: std.Io.Condition = .init,
    bound_port: std.atomic.Value(u16) = .init(0),
    counter_accepted: std.atomic.Value(u64) = .init(0),
    counter_requests: std.atomic.Value(u64) = .init(0),
    counter_5xx: std.atomic.Value(u64) = .init(0),
    counter_rejections: std.atomic.Value(u64) = .init(0),
    counter_forced: std.atomic.Value(u64) = .init(0),

    const max_jobs = 8;

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) Error!App {
        if (@import("builtin").os.tag != .linux) return Error.Unsupported;
        const worker_count = options.workers orelse @max(@as(usize, 4), std.Thread.getCpuCount() catch 4);
        if (worker_count == 0) return Error.Unsupported;
        const depth = options.queue_depth orelse worker_count * 8;
        const queue_buffer = gpa.alloc(std.Io.net.Stream, depth) catch return Error.OutOfMemory;
        errdefer gpa.free(queue_buffer);
        const workers = gpa.alloc(?std.Thread, worker_count) catch return Error.OutOfMemory;
        errdefer gpa.free(workers);
        @memset(workers, null);
        const active_sockets = gpa.alloc(std.atomic.Value(i64), worker_count) catch return Error.OutOfMemory;
        errdefer gpa.free(active_sockets);
        for (active_sockets) |*slot| slot.* = .init(-1);
        const active_in_handler = gpa.alloc(std.atomic.Value(bool), worker_count) catch return Error.OutOfMemory;
        errdefer gpa.free(active_in_handler);
        for (active_in_handler) |*slot| slot.* = .init(false);
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .queue = .init(queue_buffer),
            .queue_buffer = queue_buffer,
            .workers = workers,
            .active_sockets = active_sockets,
            .active_in_handler = active_in_handler,
        };
    }

    pub fn deinit(app: *App) void {
        app.gpa.free(app.active_in_handler);
        app.gpa.free(app.active_sockets);
        app.gpa.free(app.workers);
        app.gpa.free(app.queue_buffer);
        app.* = undefined;
    }

    /// Register a periodic job before `run`. The job thread sleeps on a
    /// condition, so shutdown interrupts it immediately and idle costs nothing.
    pub fn addJob(app: *App, job: Job) Error!void {
        lockOwner();
        defer owner_mutex.unlock();
        if (app.running.load(.acquire)) return Error.AlreadyRunning;
        if (app.has_run) return Error.AlreadyRun;
        if (app.job_count == max_jobs) return Error.TooManyJobs;
        app.job_slots[app.job_count] = job;
        app.job_count += 1;
    }

    pub fn boundPort(app: *App) u16 {
        return app.bound_port.load(.acquire);
    }

    pub fn counters(app: *App) Counters {
        return .{
            .connections_accepted = app.counter_accepted.load(.monotonic),
            .requests = app.counter_requests.load(.monotonic),
            .responses_5xx = app.counter_5xx.load(.monotonic),
            .queue_rejections = app.counter_rejections.load(.monotonic),
            .forced_closes = app.counter_forced.load(.monotonic),
        };
    }

    pub fn requestShutdown(app: *App) void {
        lockOwner();
        defer owner_mutex.unlock();
        if (active_app != app) return;
        signal_requested.store(true, .release);
        const handle = signal_listener_socket.load(.seq_cst);
        if (handle >= 0) {
            _ = std.os.linux.shutdown(@intCast(handle), std.os.linux.SHUT.RDWR);
        }
    }

    /// Serve until SIGTERM/SIGINT (or `requestShutdown`), then drain.
    /// Returns Error.ForcedShutdown when the drain deadline forced closes.
    /// One run attempt per instance; join run before deinit. Create a new App
    /// after shutdown or startup failure. A second active App is rejected.
    pub fn run(
        app: *App,
        comptime Ctx: type,
        ctx: Ctx,
        handler: *const fn (Ctx, *RequestContext) anyerror!void,
    ) Error!void {
        lockOwner();
        if (active_app != null) {
            owner_mutex.unlock();
            return Error.AlreadyRunning;
        }
        if (app.has_run) {
            owner_mutex.unlock();
            return Error.AlreadyRun;
        }
        active_app = app;
        app.has_run = true;
        signal_requested.store(false, .release);
        app.running.store(true, .release);
        owner_mutex.unlock();
        defer {
            lockOwner();
            app.running.store(false, .release);
            active_app = null;
            owner_mutex.unlock();
        }
        app.stopping.store(false, .release);

        var listener = app.options.address.listen(app.io, .{ .reuse_address = true }) catch {
            return Error.ListenFailed;
        };
        defer listener.deinit(app.io);
        defer app.bound_port.store(0, .release);
        signal_listener_socket.store(@intCast(listener.socket.handle), .release);
        defer {
            lockOwner();
            signal_listener_socket.store(-1, .seq_cst);
            // A handler already reading the old fd must finish before close
            // allows that descriptor to be reused by another thread.
            while (signal_readers.load(.seq_cst) != 0) std.atomic.spinLoopHint();
            owner_mutex.unlock();
        }

        var old_interrupt: std.posix.Sigaction = undefined;
        var old_terminate: std.posix.Sigaction = undefined;
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, &old_interrupt);
        std.posix.sigaction(.TERM, &action, &old_terminate);
        defer {
            std.posix.sigaction(.INT, &old_interrupt, null);
            std.posix.sigaction(.TERM, &old_terminate, null);
        }

        const Bridge = struct {
            fn workerEntry(
                app_pointer: *App,
                context: Ctx,
                request_handler: *const fn (Ctx, *RequestContext) anyerror!void,
                index: usize,
            ) void {
                app_pointer.workerLoop(Ctx, context, request_handler, index);
            }
        };

        var started: usize = 0;
        errdefer {
            app.stopping.store(true, .release);
            app.queue.close(app.io);
            app.stopJobs();
            for (app.workers[0..started]) |*slot| {
                if (slot.*) |thread| thread.join();
                slot.* = null;
            }
        }
        for (app.workers, 0..) |*slot, index| {
            slot.* = std.Thread.spawn(.{}, Bridge.workerEntry, .{ app, ctx, handler, index }) catch {
                return Error.Unsupported;
            };
            started += 1;
        }
        for (app.job_slots[0..app.job_count], 0..) |slot, index| {
            if (slot) |job| {
                app.job_threads[index] = std.Thread.spawn(.{}, jobLoop, .{ app, job }) catch {
                    return Error.Unsupported;
                };
            }
        }

        // The accept loop needs a real unit of concurrency: with inline
        // execution the signal wait below would never be reached on 1-core
        // hosts, and the process would ignore TERM until a connection arrived.
        var accept_group: std.Io.Group = .init;
        accept_group.concurrent(app.io, acceptLoop, .{ app, &listener }) catch {
            app.options.on_error(Error.Unsupported, "no unit of concurrency for the accept loop; configure a threaded Io with a higher async limit");
            return Error.Unsupported;
        };
        defer accept_group.cancel(app.io);
        app.bound_port.store(listener.socket.address.getPort(), .release);

        // Wait for shutdown: the signal handler shuts the listener down, the
        // accept loop observes it and signals this condition. No polling.
        app.drain_mutex.lockUncancelable(app.io);
        while (!app.stopping.load(.acquire)) {
            app.drain_condition.waitUncancelable(app.io, &app.drain_mutex);
        }
        app.drain_mutex.unlock(app.io);
        accept_group.cancel(app.io);

        // Drain: closing the queue lets workers finish the backlog, then exit
        // on error.Closed. Wait on completion signals up to the deadline.
        app.queue.close(app.io);
        var forced = false;
        const deadline_ns: u64 = app.options.drain_timeout_ms * std.time.ns_per_ms;
        const drain_started = std.Io.Timestamp.now(app.io, .awake);
        app.drain_mutex.lockUncancelable(app.io);
        while (app.in_flight.load(.acquire) > 0 or app.queued.load(.acquire) > 0) {
            // Idle keep-alive connections (worker parked between requests)
            // close immediately: nothing is in flight on them, and waiting
            // out the deadline for an idle socket would stall every
            // shutdown. Re-scanned each slice because a worker may still be
            // finishing response bookkeeping when the drain begins.
            for (app.active_sockets, app.active_in_handler) |*socket_slot, *in_handler| {
                const handle = socket_slot.load(.acquire);
                if (handle >= 0 and !in_handler.load(.acquire)) {
                    _ = std.os.linux.shutdown(@intCast(handle), std.os.linux.SHUT.RDWR);
                }
            }
            const waited_ns: u64 = @intCast(@max(0, drain_started.durationTo(std.Io.Timestamp.now(app.io, .awake)).nanoseconds));
            if (waited_ns >= deadline_ns) {
                forced = true;
                break;
            }
            const slice_ns: u64 = @min(deadline_ns - waited_ns, 50 * std.time.ns_per_ms);
            app.drain_condition.waitTimeout(app.io, &app.drain_mutex, .{ .duration = .{ .raw = .{ .nanoseconds = @intCast(slice_ns) }, .clock = .awake } }) catch {};
        }
        if (forced) {
            app.force_stopping = true;
            for (app.active_sockets) |*slot| {
                const handle = slot.load(.acquire);
                if (handle >= 0) {
                    _ = std.os.linux.shutdown(@intCast(handle), std.os.linux.SHUT.RDWR);
                    _ = app.counter_forced.fetchAdd(1, .monotonic);
                }
            }
        }
        app.drain_mutex.unlock(app.io);
        for (app.workers) |*slot| {
            if (slot.*) |thread| thread.join();
            slot.* = null;
        }
        app.stopJobs();
        return if (forced) Error.ForcedShutdown else {};
    }

    fn stopJobs(app: *App) void {
        app.job_mutex.lockUncancelable(app.io);
        app.job_condition.broadcast(app.io);
        app.job_mutex.unlock(app.io);
        for (&app.job_threads) |*slot| {
            if (slot.*) |thread| thread.join();
            slot.* = null;
        }
    }

    fn acceptLoop(app: *App, listener: *std.Io.net.Server) void {
        while (!signal_requested.load(.acquire)) {
            const stream = listener.accept(app.io) catch |err| {
                if (signal_requested.load(.acquire)) break;
                app.options.on_error(err, "accept failed");
                if (err == error.Canceled) break;
                continue;
            };
            _ = app.counter_accepted.fetchAdd(1, .monotonic);
            _ = app.queued.fetchAdd(1, .acq_rel);
            const put = app.queue.put(app.io, &.{stream}, 0) catch 0;
            if (put == 0) {
                // Queue full or closed: bounded, explicit backpressure. The
                // silent alternative (dropping the connection) reads as a
                // network failure to the client and hides overload from the
                // operator.
                _ = app.queued.fetchSub(1, .acq_rel);
                _ = app.counter_rejections.fetchAdd(1, .monotonic);
                app.writeBusy(stream);
            }
        }
        app.beginStopping();
    }

    fn beginStopping(app: *App) void {
        app.stopping.store(true, .release);
        app.drain_mutex.lockUncancelable(app.io);
        app.drain_condition.broadcast(app.io);
        app.drain_mutex.unlock(app.io);
    }

    fn writeBusy(app: *App, stream: std.Io.net.Stream) void {
        const busy_response = "HTTP/1.1 503 Service Unavailable\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: 8\r\n" ++
            "Retry-After: 1\r\n" ++
            "Connection: close\r\n\r\noverload";
        // Never park the accept loop behind an overloaded/non-reading peer.
        // This small response fits a fresh socket's normal send buffer; failed
        // or partial delivery is best effort and the connection still closes.
        _ = std.os.linux.sendto(stream.socket.handle, busy_response.ptr, busy_response.len, std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL, null, 0);
        stream.close(app.io);
    }

    fn workerLoop(
        app: *App,
        comptime Ctx: type,
        ctx: Ctx,
        handler: *const fn (Ctx, *RequestContext) anyerror!void,
        index: usize,
    ) void {
        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        while (true) {
            const stream = app.queue.getOneUncancelable(app.io) catch break;
            app.drain_mutex.lockUncancelable(app.io);
            _ = app.queued.fetchSub(1, .acq_rel);
            if (app.force_stopping) {
                stream.close(app.io);
                _ = app.counter_forced.fetchAdd(1, .monotonic);
                app.drain_condition.broadcast(app.io);
                app.drain_mutex.unlock(app.io);
                continue;
            }
            _ = app.in_flight.fetchAdd(1, .acq_rel);
            app.active_sockets[index].store(@intCast(stream.socket.handle), .release);
            app.drain_mutex.unlock(app.io);
            app.serveStream(Ctx, ctx, handler, stream, &arena_state, index);
            app.drain_mutex.lockUncancelable(app.io);
            app.active_sockets[index].store(-1, .release);
            stream.close(app.io);
            app.active_in_handler[index].store(false, .release);
            _ = app.in_flight.fetchSub(1, .acq_rel);
            app.drain_condition.broadcast(app.io);
            app.drain_mutex.unlock(app.io);
        }
    }

    fn serveStream(
        app: *App,
        comptime Ctx: type,
        ctx: Ctx,
        handler: *const fn (Ctx, *RequestContext) anyerror!void,
        stream: std.Io.net.Stream,
        arena_state: *std.heap.ArenaAllocator,
        worker_index: usize,
    ) void {
        const Wrapper = struct {
            app_pointer: *App,
            context: Ctx,
            request_handler: *const fn (Ctx, *RequestContext) anyerror!void,
            arena: *std.heap.ArenaAllocator,
            peer: std.Io.net.IpAddress,

            fn handle(wrapper: @This(), request: *std.http.Server.Request) anyerror!void {
                const wrapped_app = wrapper.app_pointer;
                defer _ = wrapper.arena.reset(.{ .retain_with_limit = 256 * 1024 });
                _ = wrapped_app.counter_requests.fetchAdd(1, .monotonic);
                var request_context: RequestContext = .{
                    .arena = wrapper.arena.allocator(),
                    .request = request,
                    .io = wrapped_app.io,
                    .app = wrapped_app,
                    .peer_address = wrapper.peer,
                };
                const started = std.Io.Timestamp.now(wrapped_app.io, .awake);
                if (wrapped_app.options.healthz and request.head.method == .GET and
                    std.mem.eql(u8, requestPath(request.head.target), "/healthz"))
                {
                    try wrapped_app.respondHealthz(&request_context);
                } else {
                    wrapper.request_handler(wrapper.context, &request_context) catch |err| {
                        // A broken or timed-out transport cannot carry a 500
                        // and must not enter another keep-alive iteration.
                        switch (err) {
                            error.ReadFailed, error.WriteFailed, error.EndOfStream => return err,
                            else => {},
                        }
                        _ = wrapped_app.counter_5xx.fetchAdd(1, .monotonic);
                        wrapped_app.options.on_error(err, request.head.target);
                        respondServerError(request) catch {};
                        return;
                    };
                }
                if (wrapped_app.options.on_request) |on_request| {
                    const finished = std.Io.Timestamp.now(wrapped_app.io, .awake);
                    on_request(.{
                        .method = request.head.method,
                        .target = request.head.target,
                        // The lifecycle does not parse the response the
                        // handler wrote; applications that need exact status
                        // logging record it in their handler.
                        .status = .ok,
                        .duration_ns = @intCast(@max(0, started.durationTo(finished).nanoseconds)),
                    });
                }
            }
        };
        const wrapper: Wrapper = .{
            .app_pointer = app,
            .context = ctx,
            .request_handler = handler,
            .arena = arena_state,
            .peer = stream.socket.address,
        };

        var request_buffer: [16 * 1024]u8 = undefined;
        var response_buffer: [16 * 1024]u8 = undefined;
        var connection = ConnectionIo.init(app.io, stream, app.options.idle_timeout_ms, &request_buffer, &response_buffer);
        var server = std.http.Server.init(&connection.reader, &connection.writer);
        var handled: usize = 0;
        const maximum_requests = app.options.connection.maximum_requests;
        while (handled < maximum_requests) {
            app.active_in_handler[worker_index].store(false, .release);
            connection.resetBudget();
            if (connection.reader.bufferedLen() == 0 and !connection.waitReadable()) return;
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                error.HttpHeadersOversize => {
                    web_server.writeHeaderTooLarge(&connection.writer) catch {};
                    return;
                },
                error.ReadFailed => return,
                else => {
                    app.options.on_error(err, "receive head");
                    return;
                },
            };
            app.active_in_handler[worker_index].store(true, .release);
            handled += 1;
            if (handled == maximum_requests) request.head.keep_alive = false;
            Wrapper.handle(wrapper, &request) catch |err| switch (err) {
                error.ReadFailed, error.WriteFailed, error.EndOfStream => return,
                else => {
                    app.options.on_error(err, "connection loop");
                    return;
                },
            };
            if (!request.head.keep_alive) return;
        }
    }

    fn respondHealthz(app: *App, context: *RequestContext) !void {
        if (!isLoopback(context.peer_address)) {
            try context.request.respond("{\"error\":\"forbidden\"}", .{
                .status = .forbidden,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        const snapshot = app.counters();
        var body_buffer: [512]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buffer,
            "{{\"status\":\"ok\",\"accepted\":{d},\"requests\":{d},\"responses_5xx\":{d},\"queue_rejections\":{d},\"forced_closes\":{d}}}",
            .{ snapshot.connections_accepted, snapshot.requests, snapshot.responses_5xx, snapshot.queue_rejections, snapshot.forced_closes },
        ) catch unreachable;
        try context.request.respond(body, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
    }

    fn jobLoop(app: *App, job: Job) void {
        var context: JobContext = .{ .gpa = app.gpa, .io = app.io, .app = app };
        app.job_mutex.lockUncancelable(app.io);
        while (!app.stopping.load(.acquire)) {
            app.job_mutex.unlock(app.io);
            job.run(&context) catch |err| app.options.on_error(err, job.name);
            app.job_mutex.lockUncancelable(app.io);
            if (app.stopping.load(.acquire)) break;
            const interval_ns: i96 = @intCast(job.interval_ms * std.time.ns_per_ms);
            app.job_condition.waitTimeout(app.io, &app.job_mutex, .{ .duration = .{ .raw = .{ .nanoseconds = interval_ns }, .clock = .awake } }) catch {};
        }
        app.job_mutex.unlock(app.io);
    }
};

/// Routed dispatch over a comptime-validated table. `Route` needs `method`,
/// `pattern`, and a `handler: *const fn (Ctx, *RequestContext, web_router.Params) anyerror!void`
/// field. `fallback` answers not-found and method-not-allowed.
pub fn runRouted(
    app: *App,
    comptime Route: type,
    comptime routes: []const Route,
    comptime Ctx: type,
    ctx: Ctx,
    fallback: *const fn (Ctx, *RequestContext, web_router.Result(Route)) anyerror!void,
) Error!void {
    comptime web_router.validateRoutes(Route, routes);
    const Dispatch = struct {
        context: Ctx,
        fallback_handler: *const fn (Ctx, *RequestContext, web_router.Result(Route)) anyerror!void,

        fn handle(dispatch: @This(), request_context: *RequestContext) anyerror!void {
            const path = requestPath(request_context.request.head.target);
            const result = web_router.match(Route, routes, request_context.request.head.method, path);
            switch (result) {
                .matched => |matched| try matched.route.handler(dispatch.context, request_context, matched.params),
                .method_not_allowed, .not_found => try dispatch.fallback_handler(dispatch.context, request_context, result),
            }
        }
    };
    const dispatch: Dispatch = .{ .context = ctx, .fallback_handler = fallback };
    return app.run(Dispatch, dispatch, Dispatch.handle);
}

fn requestPath(target: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..query];
}

fn respondServerError(request: *std.http.Server.Request) !void {
    try request.respond("internal error", .{
        .status = .internal_server_error,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

fn sleepMillisecond(io: std.Io) void {
    std.Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = std.time.ns_per_ms }, .clock = .awake } }, io) catch {};
}

fn isLoopback(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| loopback_ip6: {
            const v6_loopback: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
            const v4_mapped_prefix: [12]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            break :loopback_ip6 std.mem.eql(u8, &ip6.bytes, &v6_loopback) or
                (std.mem.eql(u8, ip6.bytes[0..12], &v4_mapped_prefix) and ip6.bytes[12] == 127);
        },
    };
}

// -- journeys ---------------------------------------------------------------
// Real sockets on port 0, real threads, outcome assertions. These run in
// `zig build test` like every other module test.

const TestHarness = struct {
    var noted_errors: std.atomic.Value(u64) = .init(0);

    fn onError(err: anyerror, note: []const u8) void {
        _ = @errorName(err);
        _ = note;
        _ = noted_errors.fetchAdd(1, .monotonic);
    }

    fn okHandler(_: u8, context: *RequestContext) anyerror!void {
        try context.request.respond("journey body", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
    }

    const Running = struct {
        app: *App,
        thread: ?std.Thread,
        fn finish(self: *Running) void {
            if (self.thread) |thread| {
                self.app.requestShutdown();
                thread.join();
                self.thread = null;
            }
        }
    };

    fn boot(app: *App, comptime handler: fn (u8, *RequestContext) anyerror!void) !Running {
        const Runner = struct {
            fn main(app_pointer: *App, result: *anyerror!void) void {
                result.* = app_pointer.run(u8, 0, handler);
            }
        };
        const thread = try std.Thread.spawn(.{}, Runner.main, .{ app, &run_result });
        var running: Running = .{ .app = app, .thread = thread };
        errdefer running.finish();
        var attempts: usize = 0;
        while (app.boundPort() == 0) : (attempts += 1) {
            if (attempts > 2_000) return error.ServerNeverBound;
            sleepMillisecond(app.io);
        }
        return running;
    }

    var run_result: anyerror!void = {};

    /// Reads one response's bytes until the header terminator plus a small
    /// body window; enough for tests that only need completion.
    fn readOne(reader: *std.Io.Reader) !usize {
        var seen: usize = 0;
        var byte: [1]u8 = undefined;
        var window: [4]u8 = @splat(0);
        while (true) {
            const n = try reader.readSliceShort(&byte);
            if (n == 0) return error.EndOfStream;
            seen += 1;
            window[0] = window[1];
            window[1] = window[2];
            window[2] = window[3];
            window[3] = byte[0];
            if (std.mem.eql(u8, &window, "\r\n\r\n")) break;
        }
        // Drain the fixed body the ok handler writes.
        var body: [64]u8 = undefined;
        try reader.readSliceAll(body[0.."journey body".len]);
        try std.testing.expectEqualStrings("journey body", body[0.."journey body".len]);
        return seen;
    }

    fn request(io: std.Io, port: u16, raw: []const u8, response_storage: []u8) ![]const u8 {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(raw);
        try writer.interface.flush();
        // Retain each received chunk. readSliceShort tries to fill the whole
        // destination and loses its partial count if close-with-unread-input
        // causes a reset after the complete overload response arrived.
        var total: usize = 0;
        while (total < response_storage.len) {
            var chunks = [_][]u8{response_storage[total..]};
            const chunk = stream.read(io, &chunks) catch break;
            if (chunk == 0) break;
            total += chunk;
        }
        return response_storage[0..total];
    }
};

test "boot, serve, keep-alive reuse, healthz, clean shutdown" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 2,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    var server_thread = try TestHarness.boot(&app, TestHarness.okHandler);
    defer server_thread.finish();

    var storage: [4096]u8 = undefined;
    // Two requests on one connection prove keep-alive; the second still
    // answers after the first completed.
    const both = try TestHarness.request(io, app.boundPort(), "GET /a HTTP/1.1\r\nhost: t\r\n\r\nGET /b HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.count(u8, both, "journey body") == 2);

    const health = try TestHarness.request(io, app.boundPort(), "GET /healthz HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"requests\":") != null);

    app.requestShutdown();
    server_thread.finish();
    try TestHarness.run_result;
    try std.testing.expect(app.counters().requests >= 3);
    try std.testing.expectEqual(@as(u64, 0), app.counters().forced_closes);
}

test "queue saturation answers 503 with retry-after instead of dropping" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Gate = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn slowHandler(_: u8, context: *RequestContext) anyerror!void {
            while (!release.load(.acquire)) sleepMillisecond(context.io);
            try context.request.respond("slow done", .{});
        }
    };
    Gate.release.store(false, .release);

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 1,
        .queue_depth = 1,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    var server_thread = try TestHarness.boot(&app, Gate.slowHandler);
    defer server_thread.finish();
    defer Gate.release.store(true, .release);
    const port = app.boundPort();

    // One request occupies the worker; one sits in the queue; further
    // connections must be told to back off explicitly.
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var held = try address.connect(io, .{ .mode = .stream });
    defer held.close(io);
    var held_writer_buffer: [256]u8 = undefined;
    var held_writer = held.writer(io, &held_writer_buffer);
    try held_writer.interface.writeAll("GET /hold HTTP/1.1\r\nhost: t\r\n\r\n");
    try held_writer.interface.flush();
    var ready_attempts: usize = 0;
    while (app.counters().requests == 0) : (ready_attempts += 1) {
        if (ready_attempts > 2000) return error.HandlerNeverStarted;
        sleepMillisecond(io);
    }
    var queued = try address.connect(io, .{ .mode = .stream });
    defer queued.close(io);
    var queued_writer_buffer: [256]u8 = undefined;
    var queued_writer = queued.writer(io, &queued_writer_buffer);
    try queued_writer.interface.writeAll("GET /queued HTTP/1.1\r\nhost: t\r\n\r\n");
    try queued_writer.interface.flush();
    ready_attempts = 0;
    while (app.queued.load(.acquire) == 0) : (ready_attempts += 1) {
        if (ready_attempts > 2000) return error.ConnectionNeverQueued;
        sleepMillisecond(io);
    }

    var storage: [1024]u8 = undefined;
    const response = try TestHarness.request(io, port, "GET /extra HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 503 "));
    try std.testing.expect(std.mem.indexOf(u8, response, "Retry-After: 1\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, response, "\r\n\r\noverload"));
    try std.testing.expectEqual(@as(u64, 1), app.counters().queue_rejections);

    Gate.release.store(true, .release);
    app.requestShutdown();
    server_thread.finish();
    try TestHarness.run_result;
}

test "drain deadline force-closes a stalled handler and reports it" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Stall = struct {
        fn handler(_: u8, context: *RequestContext) anyerror!void {
            // Blocks reading a request body the client never sends. Only the
            // drain's force-close (or the idle timeout, set far higher here)
            // can unblock it.
            var transfer_buffer: [256]u8 = undefined;
            const reader = try context.request.readerExpectContinue(&transfer_buffer);
            var sink: [16]u8 = undefined;
            _ = try reader.readSliceShort(&sink);
            try context.request.respond("late", .{});
        }
    };

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 1,
        .queue_depth = 1,
        .drain_timeout_ms = 300,
        .idle_timeout_ms = 60_000,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    var server_thread = try TestHarness.boot(&app, Stall.handler);
    defer server_thread.finish();
    const port = app.boundPort();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stalled = try address.connect(io, .{ .mode = .stream });
    defer stalled.close(io);
    var stalled_writer_buffer: [256]u8 = undefined;
    var stalled_writer = stalled.writer(io, &stalled_writer_buffer);
    try stalled_writer.interface.writeAll("POST /stall HTTP/1.1\r\nhost: t\r\ncontent-length: 5\r\n\r\n");
    try stalled_writer.interface.flush();
    // Give the worker a moment to pick the connection up.
    var attempts: usize = 0;
    while (app.counters().requests == 0) : (attempts += 1) {
        if (attempts > 1_000) return error.HandlerNeverStarted;
        sleepMillisecond(io);
    }

    // The backlog must not start another stalled handler after force-close.
    var queued = try address.connect(io, .{ .mode = .stream });
    defer queued.close(io);
    var queued_buffer: [256]u8 = undefined;
    var queued_writer = queued.writer(io, &queued_buffer);
    try queued_writer.interface.writeAll("POST /queued HTTP/1.1\r\nhost: t\r\ncontent-length: 5\r\n\r\n");
    try queued_writer.interface.flush();
    attempts = 0;
    while (app.queued.load(.acquire) == 0) : (attempts += 1) {
        if (attempts > 1000) return error.ConnectionNeverQueued;
        sleepMillisecond(io);
    }
    app.requestShutdown();
    server_thread.finish();
    try std.testing.expectError(Error.ForcedShutdown, TestHarness.run_result);
    try std.testing.expectEqual(@as(u64, 2), app.counters().forced_closes);
    try std.testing.expectEqual(@as(u64, 1), app.counters().requests);
}

test "jobs tick on their interval and stop promptly at shutdown" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Tick = struct {
        var count: std.atomic.Value(u64) = .init(0);
        fn run(_: *JobContext) anyerror!void {
            _ = count.fetchAdd(1, .monotonic);
        }
    };
    Tick.count.store(0, .release);

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 1,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    try app.addJob(.{ .name = "tick", .interval_ms = 10, .run = Tick.run });
    var server_thread = try TestHarness.boot(&app, TestHarness.okHandler);
    defer server_thread.finish();

    var attempts: usize = 0;
    while (Tick.count.load(.acquire) < 3) : (attempts += 1) {
        if (attempts > 2_000) return error.JobNeverTicked;
        sleepMillisecond(io);
    }

    const shutdown_started = std.Io.Timestamp.now(io, .awake);
    app.requestShutdown();
    server_thread.finish();
    try TestHarness.run_result;
    const shutdown_finished = std.Io.Timestamp.now(io, .awake);
    // Joining must not wait out a full interval-less sleep; generous bound
    // for slow CI.
    try std.testing.expect(shutdown_started.durationTo(shutdown_finished).nanoseconds < 5 * std.time.ns_per_s);
}

test "routed dispatch serves matched routes and falls back for the rest" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Routed = struct {
        const Route = struct {
            method: std.http.Method,
            pattern: []const u8,
            handler: *const fn (u8, *RequestContext, web_router.Params) anyerror!void,
        };
        fn item(_: u8, context: *RequestContext, params: web_router.Params) anyerror!void {
            var body: [128]u8 = undefined;
            const rendered = try std.fmt.bufPrint(&body, "item={s}", .{params.get("id").?});
            try context.request.respond(rendered, .{});
        }
        fn fallback(_: u8, context: *RequestContext, result: web_router.Result(Route)) anyerror!void {
            const status: std.http.Status = switch (result) {
                .method_not_allowed => .method_not_allowed,
                else => .not_found,
            };
            try context.request.respond("fallback", .{ .status = status });
        }
        const routes = [_]Route{
            .{ .method = .GET, .pattern = "/items/:id", .handler = item },
        };
    };

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 2,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    const Runner = struct {
        fn main(app_pointer: *App, result: *anyerror!void) void {
            result.* = runRouted(app_pointer, Routed.Route, &Routed.routes, u8, 0, Routed.fallback);
        }
    };
    TestHarness.run_result = {};
    var server_thread: TestHarness.Running = .{ .app = &app, .thread = try std.Thread.spawn(.{}, Runner.main, .{ &app, &TestHarness.run_result }) };
    defer server_thread.finish();
    var attempts: usize = 0;
    while (app.boundPort() == 0) : (attempts += 1) {
        if (attempts > 2_000) return error.ServerNeverBound;
        sleepMillisecond(io);
    }

    var storage: [2048]u8 = undefined;
    const matched = try TestHarness.request(io, app.boundPort(), "GET /items/42 HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.indexOf(u8, matched, "item=42") != null);
    const missing = try TestHarness.request(io, app.boundPort(), "GET /unknown HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.indexOf(u8, missing, "404") != null);
    const wrong_method = try TestHarness.request(io, app.boundPort(), "POST /items/42 HTTP/1.1\r\nhost: t\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.indexOf(u8, wrong_method, "405") != null);

    app.requestShutdown();
    server_thread.finish();
    try TestHarness.run_result;
}

test "an idle keep-alive connection does not stall graceful shutdown" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 2,
        .drain_timeout_ms = 5_000,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    var server_thread = try TestHarness.boot(&app, TestHarness.okHandler);
    defer server_thread.finish();
    const port = app.boundPort();

    // Complete one request, then leave the connection idle (keep-alive).
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var idle = try address.connect(io, .{ .mode = .stream });
    defer idle.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = idle.writer(io, &write_buffer);
    try writer.interface.writeAll("GET /idle HTTP/1.1\r\nhost: t\r\n\r\n");
    try writer.interface.flush();
    var read_buffer: [1024]u8 = undefined;
    var reader = idle.reader(io, &read_buffer);
    _ = try TestHarness.readOne(&reader.interface);

    // A second peer starts a header but never finishes it. Socket shutdown
    // must interrupt receiveHead as well as the idle poll on the first peer.
    var partial = try address.connect(io, .{ .mode = .stream });
    defer partial.close(io);
    var partial_buffer: [128]u8 = undefined;
    var partial_writer = partial.writer(io, &partial_buffer);
    try partial_writer.interface.writeAll("GET /partial HTTP/1.1\r\nhost:");
    try partial_writer.interface.flush();
    var attempts: usize = 0;
    while (app.counters().connections_accepted < 2) : (attempts += 1) {
        if (attempts > 2000) return error.ConnectionNeverAccepted;
        sleepMillisecond(io);
    }
    const started = std.Io.Timestamp.now(io, .awake);
    app.requestShutdown();
    server_thread.finish();
    const finished = std.Io.Timestamp.now(io, .awake);
    try TestHarness.run_result;
    // Idle connections close at drain start, far inside the deadline, and
    // are not counted as forced.
    try std.testing.expect(started.durationTo(finished).nanoseconds < 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 0), app.counters().forced_closes);
}

test "only the owning App controls shutdown and ownership can transfer" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var first = try App.init(std.testing.allocator, io, .{ .address = .{ .ip4 = .loopback(0) }, .workers = 1, .on_error = TestHarness.onError });
    defer first.deinit();
    var second = try App.init(std.testing.allocator, io, first.options);
    defer second.deinit();
    var original_term: std.posix.Sigaction = undefined;
    var original_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, null, &original_term);
    std.posix.sigaction(.INT, null, &original_int);
    var running = try TestHarness.boot(&first, TestHarness.okHandler);
    defer running.finish();
    const port = first.boundPort();
    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, null, &before);
    try std.testing.expectError(Error.AlreadyRunning, second.run(u8, 0, TestHarness.okHandler));
    try std.testing.expectError(Error.AlreadyRunning, first.run(u8, 0, TestHarness.okHandler));
    second.requestShutdown();
    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, null, &after);
    try std.testing.expectEqual(before.handler.handler, after.handler.handler);
    try std.testing.expectEqual(port, first.boundPort());
    var storage: [1024]u8 = undefined;
    const response = try TestHarness.request(io, port, "GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.endsWith(u8, response, "journey body"));
    running.finish();
    try TestHarness.run_result;
    try std.testing.expectError(Error.AlreadyRun, first.run(u8, 0, TestHarness.okHandler));
    var next = try TestHarness.boot(&second, TestHarness.okHandler);
    defer next.finish();
    const next_response = try TestHarness.request(io, second.boundPort(), "GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.endsWith(u8, next_response, "journey body"));
    // Exercise the installed signal handler, and prove it restores the caller's handler.
    _ = std.os.linux.kill(std.os.linux.getpid(), .TERM);
    var attempts: usize = 0;
    while (second.boundPort() != 0) : (attempts += 1) {
        if (attempts > 2000) return error.SignalDidNotStopApp;
        sleepMillisecond(io);
    }
    next.finish();
    std.posix.sigaction(.TERM, null, &after);
    try std.testing.expectEqual(original_term.handler.handler, after.handler.handler);
    std.posix.sigaction(.INT, null, &after);
    try std.testing.expectEqual(original_int.handler.handler, after.handler.handler);
    try TestHarness.run_result;
}

test "listen failure releases process ownership" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var occupied = try address.listen(io, .{});
    defer occupied.deinit(io);
    var failed = try App.init(std.testing.allocator, io, .{ .address = occupied.socket.address, .workers = 1, .on_error = TestHarness.onError });
    defer failed.deinit();
    try std.testing.expectError(Error.ListenFailed, failed.run(u8, 0, TestHarness.okHandler));
    var next = try App.init(std.testing.allocator, io, .{ .address = address, .workers = 1, .on_error = TestHarness.onError });
    defer next.deinit();
    var running = try TestHarness.boot(&next, TestHarness.okHandler);
    defer running.finish();
    var storage: [1024]u8 = undefined;
    const response = try TestHarness.request(io, next.boundPort(), "GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
    try std.testing.expect(std.mem.endsWith(u8, response, "journey body"));
    running.finish();
    try TestHarness.run_result;
}

test "drain wakeups do not consume the grace period" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Gate = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn handle(_: u8, context: *RequestContext) anyerror!void {
            while (!release.load(.acquire)) sleepMillisecond(context.io);
            try context.request.respond("finished within grace", .{});
        }
        fn wake(app: *App) void {
            while (!app.stopping.load(.acquire)) sleepMillisecond(app.io);
            for (0..100) |_| {
                app.drain_mutex.lockUncancelable(app.io);
                app.drain_condition.broadcast(app.io);
                app.drain_mutex.unlock(app.io);
                sleepMillisecond(app.io);
            }
            release.store(true, .release);
        }
    };
    Gate.release.store(false, .release);
    var app = try App.init(std.testing.allocator, io, .{ .address = .{ .ip4 = .loopback(0) }, .workers = 1, .drain_timeout_ms = 1000, .on_error = TestHarness.onError });
    defer app.deinit();
    var running = try TestHarness.boot(&app, Gate.handle);
    defer running.finish();
    defer Gate.release.store(true, .release);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(app.boundPort()) };
    var held = try address.connect(io, .{ .mode = .stream });
    defer held.close(io);
    var buffer: [256]u8 = undefined;
    var writer = held.writer(io, &buffer);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n");
    try writer.interface.flush();
    var attempts: usize = 0;
    while (app.counters().requests == 0) : (attempts += 1) {
        if (attempts > 2000) return error.HandlerNeverStarted;
        sleepMillisecond(io);
    }
    const waker = try std.Thread.spawn(.{}, Gate.wake, .{&app});
    app.requestShutdown();
    waker.join();
    running.finish();
    try TestHarness.run_result;
    var read_buffer: [512]u8 = undefined;
    var reader = held.reader(io, &read_buffer);
    var response: [512]u8 = undefined;
    const len = try reader.interface.readSliceShort(&response);
    try std.testing.expect(std.mem.endsWith(u8, response[0..len], "finished within grace"));
    try std.testing.expectEqual(@as(u64, 0), app.counters().forced_closes);
}

test "accept startup failure joins workers and cooperative jobs" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    const Tick = struct {
        var count: std.atomic.Value(usize) = .init(0);
        fn run(context: *JobContext) anyerror!void {
            while (!context.stopping()) {
                _ = count.fetchAdd(1, .monotonic);
                sleepMillisecond(context.io);
            }
        }
    };
    var app = try App.init(std.testing.allocator, io, .{ .address = .{ .ip4 = .loopback(0) }, .workers = 2, .on_error = TestHarness.onError });
    defer app.deinit();
    try app.addJob(.{ .name = "cooperative", .interval_ms = 10000, .run = Tick.run });
    try std.testing.expectError(Error.Unsupported, app.run(u8, 0, TestHarness.okHandler));
    const count = Tick.count.load(.acquire);
    for (0..10) |_| sleepMillisecond(io);
    try std.testing.expectEqual(count, Tick.count.load(.acquire));
    try std.testing.expectEqual(@as(u16, 0), app.boundPort());
}

test "stalled heads bodies and trickles release the worker and recover" {
    const io = std.testing.io;
    const ReadBody = struct {
        fn handle(_: u8, context: *RequestContext) !void {
            if (context.request.head.method == .POST) {
                var buffer: [64]u8 = undefined;
                const reader = try context.request.readerExpectContinue(&buffer);
                var body: [10]u8 = undefined;
                try reader.readSliceAll(&body);
            }
            try TestHarness.okHandler(0, context);
        }
    };
    var app = try App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .workers = 1,
        .idle_timeout_ms = 120,
        .on_error = TestHarness.onError,
    });
    defer app.deinit();
    var running = try TestHarness.boot(&app, ReadBody.handle);
    defer running.finish();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(app.boundPort()) };
    const partials = [_][]const u8{
        "GET / HTTP/1.1\r\nhost: t\r\n",
        "POST / HTTP/1.1\r\nhost: t\r\ncontent-length: 10\r\n\r\nx",
        "GET / HTTP/1.1\r\nhost: t\r\nX-Slow: ",
    };
    for (partials, 0..) |partial, index| {
        const client = try address.connect(io, .{ .mode = .stream });
        defer client.close(io);
        var buffer: [256]u8 = undefined;
        var writer = client.writer(io, &buffer);
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        try writer.interface.writeAll(partial);
        try writer.interface.flush();
        var fds = [_]std.posix.pollfd{.{ .fd = client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        while (try std.posix.poll(&fds, 10) == 0) {
            if (started.untilNow(io).raw.toMilliseconds() > 2000) return error.StalledRequestOutlivedBudget;
            if (index == 2) {
                // Progress must not reset the cumulative wait budget.
                try writer.interface.writeAll("x");
                writer.interface.flush() catch {};
            }
        }
        try std.testing.expect(started.untilNow(io).raw.toMilliseconds() >= 80);
        var response: [1]u8 = undefined;
        const rc = std.os.linux.recvfrom(client.socket.handle, &response, response.len, std.os.linux.MSG.DONTWAIT, null, null);
        try std.testing.expect(rc == 0 or std.os.linux.errno(rc) == .CONNRESET);
        var storage: [4096]u8 = undefined;
        const recovered = try TestHarness.request(io, app.boundPort(), "GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
        try std.testing.expect(std.mem.endsWith(u8, recovered, "journey body"));
    }
    running.finish();
    try TestHarness.run_result;
    try std.testing.expectEqual(@as(u64, 0), app.counters().responses_5xx);
}

test "request budgets reset on reuse exclude handlers and honor zero disable" {
    const io = std.testing.io;
    const Delayed = struct {
        fn handle(_: u8, context: *RequestContext) !void {
            if (std.mem.eql(u8, context.request.head.target, "/delay"))
                try std.Io.sleep(context.io, .fromMilliseconds(300), .awake);
            try TestHarness.okHandler(0, context);
        }
    };
    for ([_]u64{ 120, 0 }) |timeout| {
        var app = try App.init(std.testing.allocator, io, .{
            .address = .{ .ip4 = .loopback(0) },
            .workers = 1,
            .idle_timeout_ms = timeout,
            .on_error = TestHarness.onError,
        });
        defer app.deinit();
        var running = try TestHarness.boot(&app, Delayed.handle);
        defer running.finish();
        {
            const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(app.boundPort()) };
            const client = try address.connect(io, .{ .mode = .stream });
            defer client.close(io);
            var write_buffer: [256]u8 = undefined;
            var writer = client.writer(io, &write_buffer);
            var read_buffer: [1024]u8 = undefined;
            var reader = client.reader(io, &read_buffer);
            for (0..2) |_| {
                try writer.interface.writeAll("GET / HTTP/1.1\r\nhost: t\r\n");
                try writer.interface.flush();
                try std.Io.sleep(io, .fromMilliseconds(if (timeout == 0) 250 else 80), .awake);
                try writer.interface.writeAll("\r\n");
                try writer.interface.flush();
                var fds = [_]std.posix.pollfd{.{ .fd = client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                try std.testing.expect(try std.posix.poll(&fds, 2000) > 0);
                _ = try TestHarness.readOne(&reader.interface);
            }
        }
        var storage: [4096]u8 = undefined;
        const response = try TestHarness.request(io, app.boundPort(), "GET /delay HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", &storage);
        try std.testing.expect(std.mem.endsWith(u8, response, "journey body"));
        running.finish();
        try TestHarness.run_result;
    }
}
