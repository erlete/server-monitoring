# Server Monitoring Stack — Design

**Date:** 2026-04-13
**Status:** Draft for review

## Goal

A fully self-contained, Docker-deployable server monitoring stack that
auto-discovers every container on every host and reports uptime, resource
usage, and logs — **without touching the containers being monitored**. No
labels, no sidecars, no config changes on existing services.

Replaces the combined roles of Uptime Kuma (uptime) and Dozzle (logs) with
a single integrated stack that has first-class auto-discovery.

## Non-goals

- Application performance monitoring (APM), tracing, profiling
- Synthetic monitoring of external URLs (only internal containers)
- Configuration management of monitored hosts beyond deploying the agent
- Long-term (>months) metric/log retention or cold storage
- Public-internet agent-to-central transport (private network is assumed)

## Constraints

- **Zero interaction with existing services.** Monitored containers must
  not need labels, environment variables, network changes, or any other
  modification.
- **Auto-discovery must be first-class**, not hand-rolled glue against an
  undocumented API. Ruling out Uptime Kuma + AutoKuma (Socket.IO) and any
  similar reverse-engineered approaches.
- **Docker-native deployment** via `docker compose`. No Kubernetes, no
  Ansible, no Nix.
- **Multi-host from day 1.** One central host plus zero or more remote
  hosts. Remote hosts reachable on a private network (VPN / Tailscale /
  LAN); no TLS gymnastics required for agent-to-central traffic.

## Architecture

Two bundles, both shipped from this repo as separate compose files:

### Central bundle — runs on exactly one host

| Component      | Role                                                       |
| -------------- | ---------------------------------------------------------- |
| Prometheus     | Receives `remote_write` from all agents, stores metrics, evaluates alert rules |
| Loki           | Receives log pushes from all agents, filesystem storage    |
| Alertmanager   | Routes firing alerts to SMTP                               |
| Grafana        | UI for dashboards, logs, alerts; provisioned from repo     |
| Caddy          | Reverse proxy with automatic HTTPS, fronts Grafana         |

### Agent bundle — runs on the central host **and** every remote host

| Component             | Role                                                                |
| --------------------- | ------------------------------------------------------------------- |
| Grafana Alloy         | Docker SD + TCP blackbox probing + metric scraping + log collection + remote_write to central |
| cAdvisor              | Per-container CPU / memory / disk / network metrics                 |
| docker-state-exporter | `container_up{name="..."}` for every container, including stopped   |
| docker-socket-proxy   | Read-only Docker socket proxy (Tecnativa) in front of the above     |

The central host runs **both** bundles. The agent bundle is identical on
every host. Adding a host = deploy the agent bundle with a `.env` file
pointing at the central host. No central-side registration.

### Data flow

```
[remote host N]   Alloy ──remote_write──▶
[remote host 1]   Alloy ──remote_write──▶  [central] Prometheus ──▶ Grafana
                  Alloy ──loki push────▶             Loki        ──▶
                                                     Alertmanager ──▶ SMTP ──▶ email
[central host]    Alloy ──remote_write──▶  (same Prometheus/Loki instances)
                  Alloy ──loki push────▶
```

## Auto-discovery strategy

All discovery happens inside Alloy on each host, driven by
`discovery.docker` against the socket-proxy. No labels are required on
monitored containers.

1. **`discovery.docker`** enumerates every container, including all port
   metadata (`__meta_docker_port_private`, `__meta_docker_network_ip`,
   `__meta_docker_container_name`, `__meta_docker_container_label_*`).
2. **Relabel pipeline**:
   - Drop containers whose name matches a configurable `EXCLUDE_NAMES`
     regex (env var). Default excludes the monitoring stack's own
     containers to avoid self-noise.
   - For each exposed port, emit a TCP blackbox probe target
     `container_ip:port`.
   - Attach labels derived only from Docker metadata: `host`,
     `container_name`, `image`, `compose_project`, `compose_service`.
     No user labels are read.
3. **`prometheus.exporter.blackbox`** runs TCP probes locally against the
   generated targets. TCP-only keeps the probe universal across HTTP,
   database, gRPC, and custom protocols.
4. **`docker-state-exporter`** reports `container_up` for every container
   known to Docker — running or stopped. This closes the "crashed worker
   with no exposed ports" gap that pure `discovery.docker` cannot see
   (it only lists running containers).
5. **`loki.source.docker`** tails stdout/stderr of every discovered
   container and pushes to central Loki with the same label set.

Containers excluded by `EXCLUDE_NAMES` are dropped from both metrics and
logs pipelines.

## Alerting

- Alertmanager receives alerts from Prometheus, deduplicates, and sends
  email via SMTP.
- SMTP host, port, credentials, from-address, and to-address are all
  provided via `.env.central` and templated into `alertmanager.yml`
  at container start (entrypoint script or `envsubst`).
- Initial rules (committed in `central/prometheus/rules/`):
  - `ContainerDown` — `container_up == 0` for 2m
  - `ProbeFailing` — `probe_success == 0` for 2m
  - `HostDiskFull` — cAdvisor filesystem > 90% for 10m
  - `HostMemoryHigh` — cAdvisor memory > 90% for 10m
- Rules are grouped by host via the `host` label so Alertmanager
  notifications include which server is affected.

## Access / exposure

- Caddy binds `:80` and `:443` on the central host.
- Domain supplied via `DOMAIN` env var. Caddy automatically obtains a
  Let's Encrypt certificate on first start.
- Grafana is **not** exposed directly; only Caddy is.
- Grafana uses its built-in auth. Admin password is set on first start
  via `GF_SECURITY_ADMIN_PASSWORD` from `.env.central`.
- Agent `remote_write` and Loki push traffic uses the private network
  only and is unauthenticated by design (trust model: private network).

## Retention (defaults, overridable via env)

- Prometheus: 30 days
- Loki: 14 days
- Both stored in named Docker volumes on the central host

## Deployment

### Central host

```
cp .env.central.example .env.central
# edit DOMAIN, SMTP_*, GRAFANA_ADMIN_PASSWORD, HOSTNAME_LABEL, etc.
docker compose -f compose.central.yml -f compose.agent.yml --env-file .env.central up -d
```

### Remote host

```
# copy the repo (or just compose.agent.yml + agent/ + .env.agent.example)
cp .env.agent.example .env.agent
# edit HOSTNAME_LABEL, REMOTE_WRITE_URL, LOKI_URL (pointing at central's private IP)
docker compose -f compose.agent.yml --env-file .env.agent up -d
```

Grafana picks up the new host automatically because dashboards use a
`$host` template variable populated from the `host` label on metrics.

## Repo layout

```
server-monitoring/
├── README.md
├── compose.central.yml
├── compose.agent.yml
├── .env.central.example
├── .env.agent.example
├── central/
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── rules/
│   │       ├── container-health.yml
│   │       └── host-health.yml
│   ├── alertmanager/
│   │   └── alertmanager.yml.tmpl
│   ├── loki/
│   │   └── loki-config.yml
│   ├── grafana/
│   │   └── provisioning/
│   │       ├── datasources/datasources.yml
│   │       └── dashboards/
│   │           ├── dashboards.yml
│   │           ├── containers-overview.json
│   │           ├── host-overview.json
│   │           └── logs-explorer.json
│   └── caddy/
│       └── Caddyfile
├── agent/
│   └── alloy/
│       └── config.alloy
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-04-13-server-monitoring-stack-design.md
```

## Environment variables

### `.env.central`

| Variable                  | Purpose                                        |
| ------------------------- | ---------------------------------------------- |
| `DOMAIN`                  | FQDN Caddy serves Grafana on                   |
| `GRAFANA_ADMIN_PASSWORD`  | Initial Grafana admin password                 |
| `SMTP_HOST`               | SMTP server                                    |
| `SMTP_PORT`               | SMTP port                                      |
| `SMTP_USERNAME`           | SMTP username                                  |
| `SMTP_PASSWORD`           | SMTP password                                  |
| `SMTP_FROM`               | From address for alert emails                  |
| `ALERT_TO`                | Destination email for alerts                   |
| `PROMETHEUS_RETENTION`    | e.g. `30d` (default `30d`)                     |
| `LOKI_RETENTION`          | e.g. `336h` (default `336h` = 14d)             |

### `.env.agent` (also sourced by the central host's agent bundle)

| Variable            | Purpose                                                           |
| ------------------- | ----------------------------------------------------------------- |
| `HOSTNAME_LABEL`    | Label attached to all metrics/logs from this host                 |
| `REMOTE_WRITE_URL`  | Central Prometheus remote_write endpoint (e.g. `http://10.0.0.1:9090/api/v1/write`) |
| `LOKI_URL`          | Central Loki push endpoint (e.g. `http://10.0.0.1:3100/loki/api/v1/push`) |
| `EXCLUDE_NAMES`     | Regex of container names to skip (default excludes stack self)    |

## Security notes

- Docker socket is exposed **only** through Tecnativa's read-only proxy,
  with the minimum permissions each container needs (Alloy, cAdvisor,
  state-exporter each get their own scoped proxy or a shared one with
  the union of needed endpoints — to be decided during implementation,
  defaulting to shared for simplicity unless it complicates things).
- No agent component writes to the Docker socket.
- Central host publishes only `:80` and `:443` (Caddy). Prometheus, Loki,
  Alertmanager, Grafana are on an internal Docker network and reached
  from remote agents only via the private network interface binding.
- Remote agents trust the private network. If the deployment later needs
  public-internet agents, add Caddy in front of Prometheus/Loki on the
  central host and turn on basic auth — out of scope for v1.

## Testing

- Unit-testable pieces are minimal (this is a config-heavy project). The
  primary validation is end-to-end:
  1. `docker compose config` on both compose files — syntax check.
  2. Bring up the stack on a single host, deploy a throwaway test
     container with an exposed HTTP port, confirm it appears in Grafana
     within ~30s.
  3. Stop the test container, confirm `container_up` drops and a
     `ContainerDown` alert fires to a test SMTP catcher (e.g. MailHog
     in a dev compose override).
  4. Tail the test container's logs in Grafana's Loki explorer.
- A small `compose.test.yml` override adds MailHog and a handful of
  dummy containers (nginx, redis, a worker with no exposed ports) so
  the whole discovery matrix can be exercised locally.

## Open questions — resolved

All resolved during brainstorming:

- Stack choice: Prometheus + Blackbox (via Alloy) + cAdvisor + Loki + Grafana + Alertmanager + Caddy
- Host scope: multi-host, central + 0..N remotes
- Trust: private network, no TLS on internal links
- Alerting: Alertmanager → SMTP (email)
- Access: Caddy reverse proxy with automatic HTTPS
- Logs: in scope (replaces Dozzle role)
