# Plan: Network Policy (host `pf` + filtering egress)

Status: **proposed** — planning doc only, not implemented yet.

## Status of the YAML config work

This doc originally covered two sequenced plans: a declarative YAML config model, and
network policy built on top of it. **The YAML config plan is done** — see
`config/container-dev.yaml` (the profile registry: ports, backends, auth detection,
mount groups, named `configs:`), `config/config.example.yaml` (user overrides), and
`lib/config.sh` (the `cfg_*` accessors sourced by `bin/create.sh`/`list.sh`/`delete.sh`).
`CLAUDE.md` documents the schema in full.

What's left, and what this doc now covers exclusively, is **network policy**: the
`networks:` block already exists in `config/container-dev.yaml` and is parsed
(`cfg_profile_network`, `cfg_profile_config_network`), but nothing enforces it yet —
every container currently gets unrestricted egress regardless of its declared policy.

Decisions already locked in:

- **Network enforcement:** host `pf` firewall + a filtering egress proxy (and optional
  filtering DNS). Enforced on the host, keyed to the container's VM IP — *not* inside
  the guest, since the agent runs as root and could undo anything applied in-container.
- **No backwards compatibility required.** This is a new capability, not a migration —
  containers created before enforcement lands simply get no policy until recreated.
- **Codex CLI — still deferred, not decided.** `opencode`'s `work-openai` config
  (declared in YAML, not yet implemented — see `CLAUDE.md`) is why an `openai-standard`
  network entry already exists in the schema, allowlisting `api.openai.com` /
  `chatgpt.com` / `auth.openai.com`. Whether work ends up on `opencode` + an OpenAI
  backend or the literal Codex CLI is still open; either way this network entry is the
  right shape once that config is wired up.
- **Claude Pro/Max stays on the `claude` profile only**, using its existing `web` auth
  mount — not relevant to enforcement design directly, but explains why there's no
  "anthropic-oauth" network variant: Pro/Max traffic goes through the same `standard`
  network as API-key/Vertex Claude traffic.

---

## Background: what Apple's `container` CLI gives us

Confirmed via `container --help` / `container network`:

- `container network create` supports custom subnets; default network is `192.168.64.0/24`.
- `container run` supports `--network`, `--dns`, `--publish`.
- The host reaches containers, and containers reach the host, via the bridge gateway
  `192.168.64.1`.
- **No built-in egress ACL / firewall.** This is why enforcement must be host-side.

---

## The `networks:` schema (already implemented)

Already live in `config/container-dev.yaml`:

```yaml
networks:
  standard:        { policy: default-deny, allow: ["api.anthropic.com", "*.googleapis.com", "github.com", "registry.npmjs.org"] }
  openai-standard: { policy: default-deny, allow: ["api.openai.com", "chatgpt.com", "auth.openai.com", "github.com", "registry.npmjs.org"] }
  offline:         { policy: deny-all, dns: false }
  open:            { policy: allow-all }

profiles:
  opencode:
    configs:
      work-vertex:  { auth: vertex,     network: standard }
      work-openai:  { auth: openai-api, network: openai-standard }
      home-local:   { auth: local,      network: offline }
  # ...
```

A network can be selected per-profile (`profiles.<p>.network`) or per named config
(`profiles.<p>.configs.<c>.network`, overriding the profile default) — `opencode` spans
both a `deny-all`/offline local-model config and `default-deny` cloud-backed configs, so
enforcement must key off the **resolved config** at `create` time (profile default, or
the `--config` entry's override), not a static per-profile lookup.

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
  policy, the container gets *no* egress and `create.sh` aborts — never silently open.

The allowlist comes from the **same `networks:` block in the YAML** — one source of
truth, rendered to the proxy's config format.

## Work breakdown

1. **CLI** — add a `--network <name>` override to `bin/create.sh`, alongside the
   existing `cfg_profile_network` / `cfg_profile_config_network` lookups (already
   implemented; just not consumed for enforcement yet).

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
   - Look up the network policy for the **resolved config** (profile default, or the
     `--config` entry's `network` override when given); if `default-deny` / `deny-all`,
     render that IP's rules and `pfctl -a container-dev/<name> -f`; inject `HTTP_PROXY` /
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

## Suggested implementation order

Land steps 1–4 as the MVP (real enforcement for `default-deny`/`deny-all` policies);
treat step 7 (DNS hardening) as optional, and step 6 (`net status`/`reload`) as
convenience tooling that can follow once enforcement itself is verified working.
