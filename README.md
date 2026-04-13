# server-monitoring

Self-contained, Docker-deployable server monitoring stack. Auto-discovers
every container on every host via the Docker socket — **with zero labels,
sidecars, or config changes on the monitored services** — and surfaces
uptime, resource usage, and logs in a single Grafana UI.

## What it replaces

- **Uptime Kuma** — per-container uptime with first-class auto-discovery,
  no reverse-engineered Socket.IO glue.
- **Dozzle** — per-container log streaming via Grafana + Loki.
- Plus: historical metrics, email alerting, and a clean multi-host story
  none of the above offer out of the box.

## Architecture

Two compose bundles shipped from this repo:

| Bundle      | File                  | Runs on      | Components                                                                               |
| ----------- | --------------------- | ------------ | ---------------------------------------------------------------------------------------- |
| **Central** | `compose.central.yml` | One host     | Prometheus, Loki, Alertmanager, Grafana, Caddy                                           |
| **Agent**   | `compose.agent.yml`   | Every host   | Grafana Alloy, cAdvisor, docker-state-exporter, Blackbox exporter, docker-socket-proxy   |

The central host runs **both** bundles; remote hosts run only the agent
bundle and push metrics + logs to the central host over a private network.

Both compose files share `name: monitoring` and a `monitoring` network
definition, so deploying them together with multiple `-f` flags merges
them into a single Compose project with a shared network.

## Deploying the central host

```bash
git clone <this repo> server-monitoring
cd server-monitoring

cp .env.central.example .env.central
# Edit DOMAIN, GRAFANA_ADMIN_PASSWORD, SMTP_*, ALERT_TO, HOSTNAME_LABEL, etc.

docker compose -f compose.central.yml -f compose.agent.yml \
  --env-file .env.central up -d
```

Grafana is reachable at `https://<DOMAIN>/` once Caddy obtains a cert.

### Production Caddy configuration

The committed `central/caddy/Caddyfile` contains `tls internal`, which makes
Caddy issue a self-signed cert immediately. This is convenient for local
dev on non-routable domains but is **not what you want in production**.

For a real deployment:

1. Set `DOMAIN` to a real domain whose A/AAAA record points at the central
   host.
2. Set `CADDY_ACME_EMAIL` to a real email for Let's Encrypt account
   notifications.
3. Remove the `tls internal` line from `central/caddy/Caddyfile`.
4. Ensure ports 80 and 443 are open to the public internet on the central
   host (Caddy needs 80 for the HTTP-01 ACME challenge).

Caddy will then obtain a real Let's Encrypt certificate on first start and
renew it automatically.

## Adding a remote host

On each host you want to monitor:

```bash
git clone <this repo> server-monitoring
cd server-monitoring

cp .env.agent.example .env.agent
# Set HOSTNAME_LABEL (unique per host), REMOTE_WRITE_URL, and LOKI_URL
# to the central host's private-network address.

docker compose -f compose.agent.yml --env-file .env.agent up -d
```

The new host starts pushing immediately. Grafana dashboards populate it
automatically — no central-side configuration change is needed.

## Customizing what gets monitored

The `EXCLUDE_NAMES` env variable is an unanchored regex of container names
to skip. By default it excludes the monitoring stack's own containers so
the stack doesn't drown itself in self-metrics. To also skip, say, all
containers named `test-*`:

```dotenv
EXCLUDE_NAMES=(alloy|cadvisor|docker-socket-proxy|docker-state-exporter|blackbox|test-.*)
```

No changes are needed on the monitored containers themselves — discovery
is entirely label-free.

## Dashboards

Three dashboards are provisioned from
`central/grafana/provisioning/dashboards/`:

- **Containers Overview** — per-container up/down status, TCP probe
  results, CPU usage, and memory usage. Filter by host.
- **Host Overview** — per-host CPU, memory, filesystem usage, and network
  throughput. Filter by host.
- **Logs Explorer** — Loki-backed log search with host and container
  filters, log volume chart, and a streaming log panel.

All three reload automatically when you edit the JSON files on disk.

## Alert rules

Defined in `central/prometheus/rules/`:

| Alert           | Fires when                                               | For  |
| --------------- | -------------------------------------------------------- | ---- |
| `ContainerDown` | `container_state_status{status="running"} == 0`         | 2m   |
| `ProbeFailing`  | `probe_success == 0`                                     | 2m   |
| `HostDiskFull`  | root-fs usage > 90%                                      | 10m  |
| `HostMemoryHigh`| host memory usage > 90%                                  | 10m  |

All alerts route to `Alertmanager` which sends email via SMTP to
`ALERT_TO`. Configure SMTP credentials in `.env.central`.

## Retention

- **Metrics:** 30 days (`PROMETHEUS_RETENTION`)
- **Logs:** 14 days (`LOKI_RETENTION=336h`)

Both are stored in named Docker volumes on the central host. Adjust in
`.env.central`.

## Label conventions

The stack uses a consistent set of labels across metrics and logs:

- `host` — `HOSTNAME_LABEL` from the per-host env file
- `name` — container name (used by cAdvisor, docker-state-exporter metrics)
- `container_name` — container name (used by blackbox probe metrics
  and Loki log streams, added by Alloy relabel)
- `compose_project`, `compose_service`, `image` — populated when the
  container is Compose-managed

The two label names for container name (`name` vs `container_name`) are
an artifact of different upstreams; both refer to the same thing.

## Blackbox networking

The Blackbox exporter runs in `network_mode: host` so it can reach
container IPs on every Docker bridge network (Docker isolates named
bridges from each other by default). Alloy addresses it as
`vm.docker.internal:9115`, which works on Docker Desktop natively and
on Linux via the `vm.docker.internal:host-gateway` alias in Alloy's
`extra_hosts`. No further configuration is needed.

## Local testing

`compose.test.yml` adds MailHog (SMTP catcher) and three dummy containers
that exercise the full discovery and alerting flow:

```bash
docker compose \
  -f compose.central.yml \
  -f compose.agent.yml \
  -f compose.test.yml \
  --env-file .env.central up -d

# MailHog web UI (captured alert emails)
open http://127.0.0.1:8025
```

The dummies exercise:
- `dummy-http` — HTTP exposed port, reached by Blackbox TCP probe
- `dummy-redis` — TCP exposed port, reached by Blackbox TCP probe
- `dummy-worker` — no exposed ports, only visible via
  `container_state_status`

Stopping `dummy-worker` fires a `ContainerDown` alert after 2 minutes, and
the alert email shows up in MailHog at `http://127.0.0.1:8025`. Restarting
it resolves the alert.

## Design

See
[`docs/superpowers/specs/2026-04-13-server-monitoring-stack-design.md`](docs/superpowers/specs/2026-04-13-server-monitoring-stack-design.md)
for the full design rationale and tradeoffs.

See
[`docs/superpowers/plans/2026-04-13-server-monitoring-stack.md`](docs/superpowers/plans/2026-04-13-server-monitoring-stack.md)
for the step-by-step implementation plan.
