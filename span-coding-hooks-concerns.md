# Re: Span Coding Hooks — recommend we don't install

After unpacking and reading the `1.13.0` installer offline, I don't think the footprint justifies installing it on my machine. It's not a passive config change — it stands up persistent, privileged, network-connected infrastructure that runs whether or not I'm actively coding.

## Security concerns

- **A root-level daemon that runs forever.** It installs a system LaunchDaemon (`com.span.otel-collector`) running as **root**, `KeepAlive` + `RunAtLoad`, that listens on a local socket (`127.0.0.1:14318`) and ships data outbound to `agent-traces.span.app`. A persistent root service with a network listener is exactly the kind of always-on attack surface I try to avoid adding.
- **Broad capture of my work, sent off-machine.** The hooks fire on every prompt, every tool call, tool failures, session stops, and compaction — and forward them to Span's backend, stamped with my work email, git email, and an auth token. That's a continuous stream of my development activity (prompts, commands, file context) leaving the machine.
- **Remote-controlled behavior.** A poller hits `api.span.app/v1/hooks/config` every 5 minutes and writes a local `policy.json` that governs what the hooks do. The behavior of code running on my machine can change remotely without my involvement or review.
- **Auto-trusted, hard-to-see hooks across multiple tools.** Beyond Claude, it writes Cursor hooks and a Codex **managed system hook** at `/etc/codex/hooks.json` that is auto-trusted and bypasses the normal per-hook review prompt. Tooling that deliberately installs itself where the user won't be asked to approve it is a pattern I don't want on a dev box.
- **A long-lived token sitting in plaintext.** The install writes my auth token to `span-config.json` and bakes it into a LaunchDaemon plist — a standing credential on disk and in process env.

## Performance / footprint concerns

- **Always-on background processes.** The root collector daemon plus a per-login agent that wakes every 5 minutes run continuously, independent of whether I'm using an AI tool at all — steady-state cost for no benefit when I'm not coding.
- **Per-event overhead on the hot path.** A hook process spawns on *every* prompt and *every* tool use, each with a watchdog/timeout wrapper. Even at a couple hundred milliseconds, that's latency tax on the inner loop of how I work all day.
- **A 500MB on-disk spool.** The collector keeps a persistent queue (~500MB / 5000 events) under `~/.span/`, plus a local write-ahead log of all events, plus its own logs — disk and I/O that accumulate in the background.
- **~850MB installed + a ~237MB installer**, for telemetry overhead.

## Bottom line

The value to me is zero (this is org/usage telemetry, not a tool I benefit from), while the cost is a permanent root daemon, continuous outbound reporting of my work, remotely-mutable behavior, and measurable per-action latency. I'd rather not install it.
