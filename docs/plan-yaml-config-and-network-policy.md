# Plan: Declarative YAML Config + Network Policy

Status: **proposed** — planning doc only, no code changes yet.

Two sequenced plans. They are deliberately ordered: the network policy lives inside
the same YAML config, so **Plan 1 is the foundation Plan 2 builds on**.

Decisions already locked in:

- **YAML parser:** `yq` (mikefarah), installed via Homebrew.
- **Network enforcement:** host `pf` firewall + a filtering egress proxy (and optional
  filtering DNS). Enforced on the host, keyed to the container's VM IP — *not* inside
  the guest, since the agent runs as root and could undo anything applied in-container.

---

## Background: what Apple's `container` CLI gives us

Confirmed via `container --help` / `container network`:

- `container network create` supports custom subnets; default network is `192.168.64.0/24`.
- `container run` supports `--network`, `--dns`, `--publish`.
- The host reaches containers, and containers reach the host, via the bridge gateway
  `192.168.64.1`.
- **No built-in egress ACL / firewall.** This is why enforcement must be host-side.

---

# Plan 1 — Declarative YAML config model

## Goal

Collapse today's scattered settings into one schema with a clear precedence chain.
Configuration currently lives in at least six places:

- Hardcoded in `bin/create.sh`: `profile_port()`, the size presets `case`, the
  auth-mount block, the `^(claude|opencode|pi)$` membership regex, the `-local$` pattern.
- `~/.config/container-dev/config` (auth override).
- `~/.config/container-dev/env` + `profiles/<name>/.env`.
- Profile-detection regexes duplicated in `bin/list.sh` and `bin/delete.sh`.
- CLI flags.

## Target layout

**Repo-level defaults (checked in):** `config/container-dev.yaml` — the profile registry.

```yaml
version: 1

defaults:
  size: medium
  network: standard
  resources:
    small:  { cpus: 2, mem: 2g }
    medium: { cpus: 4, mem: 4g }
    large:  { cpus: 6, mem: 8g }

auth:
  force: null                       # vertex|api|web|null
  detect:                           # first match wins
    - { type: vertex, when_file: "$HOME/.config/gcloud/application_default_credentials.json" }
    - { type: api,    when_env: ANTHROPIC_API_KEY }
    - { type: web }

mounts:                             # reusable named groups
  claude-common:
    - "$HOME/.claude/projects:/root/.claude/projects"
  vertex:
    - "$HOME/.config/gcloud/application_default_credentials.json:/root/.config/gcloud/application_default_credentials.json:ro"
  models:
    - "$CONFIG_DIR/models:/root/.cache/models:ro"

networks:                           # consumed by Plan 2
  standard: { policy: default-deny, allow: ["api.anthropic.com", "*.googleapis.com", "github.com", "registry.npmjs.org"] }
  offline:  { policy: deny-all, dns: false }
  open:     { policy: allow-all }

profiles:
  claude:          { port: 2222, backend: claude, network: standard, mounts: [claude-common] }
  opencode:        { port: 2230, backend: claude, network: standard, mounts: [claude-common] }
  opencode-local:  { port: 2231, backend: local,  network: offline,  mounts: [models] }
  pi:              { port: 2240, backend: claude, network: standard, mounts: [claude-common] }
  pi-local:        { port: 2241, backend: local,  network: offline,  mounts: [models] }
```

**User-level overrides (machine):** `~/.config/container-dev/config.yaml` — same schema,
sparse. Overrides `auth.force`, `defaults.size`, adds env, tweaks a network's `allow`
list, pins a profile to a different network.

**Precedence:** repo defaults → user overrides (deep-merged via `yq eval-all`) → CLI flags.

The `state` file stays a plain pipe-delimited file — it is runtime state, not config,
and is left untouched.

## Work breakdown

1. **Schema + sample files** — add `config/container-dev.yaml` and
   `config/config.example.yaml`. The `backend` field (`claude` / `local`) replaces the
   `^(claude|opencode|pi)$` and `-local$` regexes.

2. **`lib/config.sh`** (new) — thin `yq` wrappers, sourced by all three bin scripts:
   - `cfg_load` — merges repo + user YAML into one document once per invocation (cached
     to a temp file).
   - `cfg_get <path>`, `cfg_list <path>` — scalar / sequence accessors.
   - `cfg_profile_port`, `cfg_profile_backend`, `cfg_profile_network`,
     `cfg_profile_mounts`, `cfg_resource <size>`, `cfg_auth`.
   - `cfg_expand` — expands `$HOME`, `$CONFIG_DIR`, `$WORKSPACE` in mount/allow strings.
   - `cfg_validate` — fails fast on unknown profile / malformed doc.

3. **Refactor `bin/create.sh`** — replace `profile_port()`, the size `case`, the
   auth-mount block, and the membership regexes with `cfg_*` calls. Mounts become:
   iterate `cfg_profile_mounts`, expand, emit `--volume`. Behavior stays identical
   (the `network` field is parsed but not yet enforced until Plan 2).

4. **Refactor `bin/list.sh` + `bin/delete.sh`** — derive the profile-name pattern from
   the `profiles:` keys instead of the hand-maintained regexes.

5. **`install.sh`** — add `command -v yq || brew install yq`; on first run, migrate any
   existing `~/.config/container-dev/config` and `env` into `config.yaml`, then back up
   the originals with a `.bak` suffix.

6. **Docs** — rewrite the config sections of `CLAUDE.md` and `README.md` around the schema.

## Risk / mitigation

- `yq` becomes a hard dependency (accepted). Every accessor gets a default so a missing
  key degrades to current behavior rather than erroring.
- Migration is one-way, leaving `.bak` copies of the originals.
- Plan 1 is a **behavior-preserving refactor** — no functional change until Plan 2.

---

# Plan 2 — Network policy (host `pf` + filtering egress)

## Enforcement model

Enforcement lives on the **host**, keyed to the container's VM IP (assigned from
`192.168.64.0/24`, reachable back at gateway `192.168.64.1`).

Architecture — **default-deny at `pf`, allow only to a filtering proxy**:

```
container (192.168.64.x)  ──TCP──▶  host filtering proxy (192.168.64.1:3128)  ──▶  allowlisted hosts
        │                                     ▲
        └── all other egress ── pf: block drop ┘   (fail-closed)
```

- **`pf`** blocks *all* outbound from the container IP except TCP to the proxy port
  (and optionally DNS to a local filtering resolver). The agent cannot touch host `pf`,
  so this is a real boundary.
- **Filtering proxy** (tinyproxy or squid, host-run via launchd) enforces the domain
  allowlist by CONNECT / SNI hostname — **no TLS interception needed** to allowlist by
  host. It also performs name resolution, so the container needs no external DNS for
  the common case.
- **Fail-closed:** if the proxy is down or `pf` fails to load for a `default-deny`
  profile, the container gets *no* egress and `create.sh` aborts — never silently open.

The allowlist comes from the **same `networks:` block in the YAML** — one source of
truth, rendered to the proxy's config format.

## Work breakdown

1. **Schema** — already defined in Plan 1 (`networks:` + `profiles.<p>.network`). Add a
   `--network <name>` CLI override to `bin/create.sh`.

2. **Filtering proxy service** — a `net/` dir with a proxy config template + a launchd
   plist (`com.container-dev.proxy`) listening on `192.168.64.1:3128`. `lib/net.sh`
   renders the allowlist from `networks:` into proxy config. Recommend **tinyproxy**
   (simple CONNECT allowlist); note squid if arbitrary-TCP / SOCKS is needed later.

3. **`pf` scaffolding** — `/etc/pf.anchors/container-dev` anchor; a one-time
   `container-dev net setup` (sudo) that idempotently adds `anchor "container-dev/*"` +
   `load anchor …` to `/etc/pf.conf`, enables pf, and installs a launchd job to
   re-apply after macOS updates reset `pf.conf`. Per-container rule template:

   ```
   pass out quick proto tcp from <ip> to 192.168.64.1 port 3128
   pass out quick proto { tcp udp } from <ip> to 192.168.64.1 port 53   # local resolver only
   block drop out quick from <ip> to any
   ```

4. **Enforcement hooks in `bin/create.sh`** — after `container run`:
   - `container inspect <name>` → resolve VM IP.
   - Look up the profile's network policy; if `default-deny` / `deny-all`, render that
     IP's rules and `pfctl -a container-dev/<name> -f`; inject `HTTP_PROXY` /
     `HTTPS_PROXY` / `NO_PROXY` env.
   - If enforcement fails → `container rm` the just-started container and exit non-zero
     (fail-closed).
   - `allow-all` / `open` → skip pf (explicit escape hatch, logged).

5. **Revoke hooks** — `bin/delete.sh` and the stop path flush that container's `pf`
   sub-anchor. `bin/list.sh` gains a policy column and reconciles orphaned anchors
   alongside its existing state cleanup.

6. **New commands** — `container-dev net setup | status | reload`. `status` shows proxy
   state + per-container anchor + effective allowlist; `reload` regenerates proxy config
   + `pf` from YAML after an allowlist edit.

7. **DNS hardening (optional)** — local dnsmasq / unbound answering only allowlisted
   names, as defense-in-depth behind the proxy.

8. **Verification + docs** — a documented smoke test: from inside a `standard`
   container, `curl https://api.anthropic.com` (allowed) vs `curl https://example.com`
   (blocked) vs raw `nc` to a random IP (blocked by pf). Add a Network Policy section to
   `CLAUDE.md`, and document the `pf.conf`-reset-on-update caveat + the `sudo`
   requirement.

## Known limitations to document

- v1 allowlists HTTP / HTTPS via CONNECT; arbitrary-TCP protocols (e.g. git-over-ssh)
  need either an explicit CIDR allow or a SOCKS proxy (squid) — deferred to a follow-up.
- `pf` anchors are host-global, so a second tool using `pf` could interact; the
  dedicated anchor namespace minimizes this.
- `net setup` requires `sudo` and edits `/etc/pf.conf` (idempotently).

---

## Suggested implementation order

1. **Plan 1** first — safe, behavior-preserving refactor; also creates the `networks:`
   schema.
2. **Plan 2** on top. Within Plan 2, land steps 1–4 as the MVP (real enforcement for
   `default-deny` profiles); treat step 7 (DNS hardening) as optional.
