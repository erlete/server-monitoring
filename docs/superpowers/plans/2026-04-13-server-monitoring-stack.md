# Server Monitoring Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Docker-deployable server monitoring stack that auto-discovers every container on every host — with zero labels or other modifications to monitored services — reporting uptime, resource usage, and logs in a single Grafana UI.

**Architecture:** Two compose bundles shipped from one repo. A **central bundle** (Prometheus, Loki, Alertmanager, Grafana, Caddy) runs on exactly one host. An **agent bundle** (Grafana Alloy, cAdvisor, docker-state-exporter, Blackbox exporter, docker-socket-proxy) runs on every host — including the central host — discovers containers via the Docker socket, probes them with TCP blackbox, and `remote_write`s metrics + pushes logs to central over a private network. Design spec: [2026-04-13-server-monitoring-stack-design.md](../specs/2026-04-13-server-monitoring-stack-design.md).

**Tech Stack:** Docker Compose, Grafana Alloy, Prometheus, Blackbox exporter, cAdvisor, docker-state-exporter, Tecnativa docker-socket-proxy, Loki, Alertmanager, Grafana, Caddy.

---

## File structure

Files this plan creates, grouped by role:

**Top-level deployment:**
- `compose.central.yml` — central bundle services
- `compose.agent.yml` — agent bundle services (runs on every host)
- `compose.test.yml` — test override with MailHog + dummy containers
- `.env.central.example` — template for central host env
- `.env.agent.example` — template for remote host env
- `.gitignore` — excludes `.env.central`, `.env.agent`
- `README.md` — deployment instructions (replaces stub)

**Agent bundle configs:**
- `agent/alloy/config.alloy` — Alloy pipeline: discovery → relabel → blackbox scrape → cAdvisor scrape → state-exporter scrape → remote_write; Docker log tailing → loki.write

**Central bundle configs:**
- `central/prometheus/prometheus.yml` — receives remote_write, loads alert rules, points at Alertmanager
- `central/prometheus/rules/container-health.yml` — ContainerDown, ProbeFailing
- `central/prometheus/rules/host-health.yml` — HostDiskFull, HostMemoryHigh
- `central/loki/loki-config.yml` — single-binary Loki with filesystem storage + retention
- `central/alertmanager/alertmanager.yml.tmpl` — SMTP routing template (rendered via envsubst entrypoint)
- `central/alertmanager/entrypoint.sh` — renders template and execs alertmanager
- `central/grafana/provisioning/datasources/datasources.yml` — Prometheus + Loki datasources
- `central/grafana/provisioning/dashboards/dashboards.yml` — file provider pointer
- `central/grafana/provisioning/dashboards/containers-overview.json` — main uptime + per-container table
- `central/grafana/provisioning/dashboards/host-overview.json` — per-host CPU/mem/disk
- `central/grafana/provisioning/dashboards/logs-explorer.json` — Loki log explorer with host/container filters
- `central/caddy/Caddyfile` — auto-HTTPS reverse proxy to Grafana

**Docs:**
- Plan and spec live in `docs/superpowers/{plans,specs}/`.

Each file has a single responsibility. Alloy config is the one file with meaningful complexity — it contains the full discovery + probing + log pipeline as one pipeline graph, and splitting it would scatter related logic.

---

## Conventions used throughout this plan

- **Working directory:** `c:/Users/szblz/Desktop/server-monitoring`. All `docker compose` commands run from there.
- **Environment file for dev:** during implementation, use `.env.central` (copied from the example) with local placeholder values — `DOMAIN=monitoring.localhost`, a non-routable `SMTP_HOST`, etc. Real values are filled in at deploy time.
- **RTK prefix:** commands use `rtk` per repo/user conventions. Engineers without rtk can drop the prefix — behavior is identical.
- **Validation pattern:** after writing a config file, run `rtk docker compose -f <file> config` for syntactic validation, then bring up the minimum set of services needed to verify the change, then curl a relevant endpoint.
- **Commit cadence:** commit after each task. Each task leaves the repo in a working state (compose files validate; services already brought up still run).
- **Cleanup between tasks:** `rtk docker compose -f compose.central.yml -f compose.agent.yml down` when you want a clean slate. Named volumes persist state between runs, which is fine.

---

## Task 1: Repo skeleton, gitignore, env examples

**Files:**
- Create: `.gitignore`
- Create: `.env.central.example`
- Create: `.env.agent.example`
- Create empty directory markers (via placeholder files that will be replaced): not needed — directories are created by later file writes.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# Env files with real secrets — only examples are committed
.env.central
.env.agent

# Local state that should never be committed
data/
*.log

# Editor / OS noise
.vscode/
.idea/
.DS_Store
Thumbs.db
```

- [ ] **Step 2: Create `.env.central.example`**

```dotenv
# --- Central bundle configuration ---

# Fully-qualified domain name Caddy will serve Grafana on.
# Caddy obtains a Let's Encrypt cert for this name automatically.
DOMAIN=monitoring.example.com

# Initial Grafana admin password. Change on first login.
GRAFANA_ADMIN_PASSWORD=changeme

# --- SMTP for Alertmanager email notifications ---
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=alerts@example.com
SMTP_PASSWORD=changeme
SMTP_FROM=alerts@example.com
ALERT_TO=oncall@example.com

# --- Retention ---
PROMETHEUS_RETENTION=30d
# Loki accepts Go duration; 336h = 14d
LOKI_RETENTION=336h

# --- Agent bundle values (central host runs agent too) ---
HOSTNAME_LABEL=central
REMOTE_WRITE_URL=http://prometheus:9090/api/v1/write
LOKI_URL=http://loki:3100/loki/api/v1/push
# Regex of container names to exclude from discovery. Default: the stack itself.
EXCLUDE_NAMES=^(alloy|cadvisor|docker-socket-proxy|docker-state-exporter|blackbox|prometheus|loki|grafana|alertmanager|caddy)$
```

- [ ] **Step 3: Create `.env.agent.example`**

```dotenv
# --- Agent bundle configuration (remote hosts) ---

# Label attached to every metric and log line from this host.
# Must be unique across all hosts in the deployment.
HOSTNAME_LABEL=remote-host-1

# Central Prometheus remote_write endpoint, reachable on the private network.
REMOTE_WRITE_URL=http://10.0.0.1:9090/api/v1/write

# Central Loki push endpoint, reachable on the private network.
LOKI_URL=http://10.0.0.1:3100/loki/api/v1/push

# Regex of container names to exclude from discovery.
EXCLUDE_NAMES=^(alloy|cadvisor|docker-socket-proxy|docker-state-exporter|blackbox)$
```

- [ ] **Step 4: Stage and commit**

```bash
rtk git add .gitignore .env.central.example .env.agent.example
rtk git commit -m "chore: add gitignore and env example files"
```

Expected: commit succeeds, three files added.

---

## Task 2: Agent bundle skeleton with docker-socket-proxy

**Files:**
- Create: `compose.agent.yml`

- [ ] **Step 1: Create `compose.agent.yml` with socket-proxy only**

```yaml
name: monitoring

networks:
  monitoring:
    driver: bridge

services:
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:0.3.0
    container_name: docker-socket-proxy
    restart: unless-stopped
    environment:
      # Read-only Docker API subset needed by Alloy + docker-state-exporter.
      # POST is off (no container control), which blocks create/start/stop/exec.
      CONTAINERS: 1
      IMAGES: 1
      NETWORKS: 1
      INFO: 1
      VERSION: 1
      EVENTS: 1
      POST: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - monitoring
```

- [ ] **Step 2: Validate syntax**

Run: `rtk docker compose -f compose.agent.yml config`
Expected: no errors; config echoes back with the interpolated values.

- [ ] **Step 3: Bring up the proxy and verify it responds**

```bash
rtk docker compose -f compose.agent.yml up -d docker-socket-proxy
rtk docker compose -f compose.agent.yml exec docker-socket-proxy wget -qO- http://localhost:2375/version
```

Expected: JSON response containing `ApiVersion` and `Version`.

- [ ] **Step 4: Verify POST is blocked (security check)**

```bash
rtk docker compose -f compose.agent.yml exec docker-socket-proxy \
  wget -qO- --method=POST http://localhost:2375/containers/create
```

Expected: HTTP 403 Forbidden.

- [ ] **Step 5: Commit**

```bash
rtk git add compose.agent.yml
rtk git commit -m "feat(agent): add docker-socket-proxy for read-only Docker API"
```

---

## Task 3: Add cAdvisor, docker-state-exporter, and Blackbox exporter

**Files:**
- Modify: `compose.agent.yml` (append services)

- [ ] **Step 1: Append services to `compose.agent.yml`**

Append inside the existing `services:` block (after `docker-socket-proxy`):

```yaml
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    restart: unless-stopped
    command:
      - --housekeeping_interval=30s
      - --docker_only=true
      - --store_container_labels=false
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    devices:
      - /dev/kmsg
    privileged: true
    networks:
      - monitoring

  docker-state-exporter:
    image: karugaru/docker_state_exporter:latest
    container_name: docker-state-exporter
    restart: unless-stopped
    environment:
      DOCKER_HOST: tcp://docker-socket-proxy:2375
    depends_on:
      - docker-socket-proxy
    networks:
      - monitoring

  blackbox:
    image: prom/blackbox-exporter:v0.25.0
    container_name: blackbox
    restart: unless-stopped
    networks:
      - monitoring
```

- [ ] **Step 2: Validate**

Run: `rtk docker compose -f compose.agent.yml config`
Expected: valid config echo.

- [ ] **Step 3: Bring up new services**

```bash
rtk docker compose -f compose.agent.yml up -d cadvisor docker-state-exporter blackbox
```

- [ ] **Step 4: Verify each `/metrics` endpoint**

```bash
rtk docker compose -f compose.agent.yml exec docker-socket-proxy wget -qO- http://cadvisor:8080/metrics | head -n 5
rtk docker compose -f compose.agent.yml exec docker-socket-proxy wget -qO- http://docker-state-exporter:8080/metrics | head -n 5
rtk docker compose -f compose.agent.yml exec docker-socket-proxy wget -qO- http://blackbox:9115/metrics | head -n 5
```

Expected output (each):
- cAdvisor: lines starting with `# HELP container_...`
- docker-state-exporter: lines starting with `# HELP docker_container_state`
- blackbox: lines starting with `# HELP blackbox_...`

If `docker-state-exporter` fails to return container state lines, note the failure and see the contingency at the end of this task.

- [ ] **Step 5: Commit**

```bash
rtk git add compose.agent.yml
rtk git commit -m "feat(agent): add cAdvisor, docker-state-exporter, and blackbox"
```

**Contingency — docker-state-exporter image verification:** if `karugaru/docker_state_exporter:latest` does not emit a `docker_container_state` or `container_state` metric (image has shifted or been removed), replace the image with `prometheusnet/docker_state_exporter:latest` or `laurmichel/docker-state-exporter:latest` — each emits an equivalent metric. Confirm by running the `/metrics` curl above and searching for `container_state`. Whatever image is chosen, update the `container_up` expression in Task 10 to match its metric name.

---

## Task 4: Alloy config — discovery and relabel pipeline

**Files:**
- Create: `agent/alloy/config.alloy`
- Modify: `compose.agent.yml` (append `alloy` service)

This task gets Alloy running with discovery + relabeling only. Remote_write and blackbox scrape are wired in later tasks so each piece can be verified in isolation.

- [ ] **Step 1: Create `agent/alloy/config.alloy` with the discovery pipeline**

```hcl
logging {
  level  = "info"
  format = "logfmt"
}

// ============================================================
// Docker service discovery
// ============================================================
// Enumerates every running container on this host via the
// read-only socket proxy. Zero labels required on monitored
// containers.

discovery.docker "containers" {
  host             = "tcp://docker-socket-proxy:2375"
  refresh_interval = "15s"
}

// ============================================================
// Standard label pipeline
// ============================================================
// Drops excluded containers and attaches the canonical label
// set used across all metrics and logs: host, container_name,
// image, compose_project, compose_service.

discovery.relabel "containers" {
  targets = discovery.docker.containers.targets

  // Drop containers matching the EXCLUDE_NAMES regex.
  // Docker reports container names with a leading slash.
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/" + sys.env("EXCLUDE_NAMES")
    action        = "drop"
  }

  // Strip the leading slash for the container_name label.
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container_name"
  }

  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project"]
    target_label  = "compose_project"
  }

  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_service"]
    target_label  = "compose_service"
  }

  rule {
    source_labels = ["__meta_docker_container_label_org_opencontainers_image_title"]
    target_label  = "image"
  }
}
```

- [ ] **Step 2: Append the `alloy` service to `compose.agent.yml`**

Append inside the `services:` block:

```yaml
  alloy:
    image: grafana/alloy:v1.5.0
    container_name: alloy
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    environment:
      HOSTNAME_LABEL: ${HOSTNAME_LABEL:?HOSTNAME_LABEL required}
      REMOTE_WRITE_URL: ${REMOTE_WRITE_URL:?REMOTE_WRITE_URL required}
      LOKI_URL: ${LOKI_URL:?LOKI_URL required}
      EXCLUDE_NAMES: ${EXCLUDE_NAMES:-^(alloy|cadvisor|docker-socket-proxy|docker-state-exporter|blackbox|prometheus|loki|grafana|alertmanager|caddy)$$}
    volumes:
      - ./agent/alloy/config.alloy:/etc/alloy/config.alloy:ro
      - alloy-data:/var/lib/alloy/data
    ports:
      - "127.0.0.1:12345:12345"
    depends_on:
      - docker-socket-proxy
      - cadvisor
      - docker-state-exporter
      - blackbox
    networks:
      - monitoring
```

And add a volume at the top (inside the existing top-level `volumes:` stanza — create it if it doesn't exist yet, it should be placed above `services:`):

```yaml
volumes:
  alloy-data:
```

- [ ] **Step 3: Create a `.env.central` from the example for local dev**

```bash
cp .env.central.example .env.central
```

No changes needed — the example's `HOSTNAME_LABEL=central`, `REMOTE_WRITE_URL=http://prometheus:9090/api/v1/write`, `LOKI_URL=http://loki:3100/loki/api/v1/push` defaults are fine for local dev. Prometheus/Loki don't exist yet so remote_write will fail quietly — that's expected until Task 9.

- [ ] **Step 4: Bring up Alloy and check it parses the config**

```bash
rtk docker compose -f compose.agent.yml --env-file .env.central up -d alloy
rtk docker compose -f compose.agent.yml logs alloy | tail -n 30
```

Expected: log lines `config loaded successfully` and `starting component controller`; no `error` level lines about the config file.

- [ ] **Step 5: Verify discovery finds containers via the Alloy debug UI**

```bash
rtk curl -s http://127.0.0.1:12345/api/v0/web/components/discovery.docker.containers/json | head -n 50
```

Expected: JSON describing the component with a `"targets"` array containing entries for every running container on the host.

```bash
rtk curl -s http://127.0.0.1:12345/api/v0/web/components/discovery.relabel.containers/json | head -n 80
```

Expected: JSON with the same targets but with labels `container_name`, `compose_project`, `compose_service` attached.

- [ ] **Step 6: Commit**

```bash
rtk git add agent/alloy/config.alloy compose.agent.yml
rtk git commit -m "feat(agent): add Alloy with Docker discovery and relabel pipeline"
```

---

## Task 5: Alloy blackbox TCP probing

**Files:**
- Modify: `agent/alloy/config.alloy` (append blackbox target relabel + scrape)

- [ ] **Step 1: Append blackbox sections to `agent/alloy/config.alloy`**

```hcl
// ============================================================
// Blackbox TCP probe targets
// ============================================================
// One probe target per (container, exposed private port).
// TCP probes work universally — any protocol that opens a port
// counts as "up".

discovery.relabel "blackbox_targets" {
  targets = discovery.relabel.containers.output

  // Keep only targets that have a private port exposed.
  rule {
    source_labels = ["__meta_docker_port_private"]
    regex         = ".+"
    action        = "keep"
  }

  // Construct the probe target address: container IP + private port.
  rule {
    source_labels = ["__meta_docker_network_ip", "__meta_docker_port_private"]
    separator     = ":"
    target_label  = "__param_target"
  }

  // Surface the probed address as the `instance` label.
  rule {
    source_labels = ["__param_target"]
    target_label  = "instance"
  }

  // Prometheus scrape semantics: __address__ is the exporter,
  // __param_target is the URL the exporter probes.
  rule {
    target_label = "__address__"
    replacement  = "blackbox:9115"
  }
}

// ============================================================
// Blackbox scrape
// ============================================================
// forward_to is wired up to remote_write in Task 9; for now,
// send to a no-op receiver so the component validates.

prometheus.scrape "blackbox" {
  targets         = discovery.relabel.blackbox_targets.output
  forward_to      = [prometheus.relabel.add_host_label.receiver]
  scrape_interval = "30s"
  scrape_timeout  = "10s"
  metrics_path    = "/probe"
  params          = { module = ["tcp_connect"] }
}

// ============================================================
// Add host label to all metrics
// ============================================================
// Central entry point for all scrapes. Adds the hostname label
// from env and fans out to remote_write (wired in Task 9).

prometheus.relabel "add_host_label" {
  forward_to = []  // Will be wired to remote_write in Task 9

  rule {
    target_label = "host"
    replacement  = sys.env("HOSTNAME_LABEL")
  }
}
```

Note: `prometheus.relabel.add_host_label` has an empty `forward_to` on purpose. Alloy accepts this — scraped samples are dropped until Task 9 wires `remote_write`. This keeps each task independently verifiable.

- [ ] **Step 2: Configure Blackbox with the `tcp_connect` module**

The Blackbox exporter image ships with a sensible default config that already includes `tcp_connect`. Verify it is present:

```bash
rtk docker compose -f compose.agent.yml exec blackbox wget -qO- http://localhost:9115/config
```

Expected: YAML output containing a `tcp_connect:` module stanza with `prober: tcp`.

If the default does not include `tcp_connect` (it should for v0.25.0, but verify), create `agent/blackbox/blackbox.yml`:

```yaml
modules:
  tcp_connect:
    prober: tcp
    timeout: 5s
    tcp: {}
```

And mount it into the blackbox service in `compose.agent.yml`:

```yaml
  blackbox:
    image: prom/blackbox-exporter:v0.25.0
    container_name: blackbox
    restart: unless-stopped
    volumes:
      - ./agent/blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml:ro
    networks:
      - monitoring
```

- [ ] **Step 3: Restart Alloy and inspect discovered blackbox targets**

```bash
rtk docker compose -f compose.agent.yml --env-file .env.central restart alloy
rtk curl -s http://127.0.0.1:12345/api/v0/web/components/discovery.relabel.blackbox_targets/json | head -n 80
```

Expected: JSON with one target per (container, port) pair, each with `__address__=blackbox:9115` and `__param_target=<ip>:<port>`.

- [ ] **Step 4: Manually probe one target via blackbox to sanity-check**

Pick any `__param_target` from the previous step, then:

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- "http://blackbox:9115/probe?target=<target>&module=tcp_connect"
```

Expected: Prometheus exposition output with `probe_success 1` (if the target is up).

- [ ] **Step 5: Commit**

```bash
rtk git add agent/alloy/config.alloy compose.agent.yml agent/blackbox/blackbox.yml
rtk git commit -m "feat(agent): add Alloy blackbox TCP probe pipeline"
```

Note: `agent/blackbox/blackbox.yml` is only added if Step 2's contingency branch was taken.

---

## Task 6: Alloy cAdvisor and docker-state-exporter scrapes

**Files:**
- Modify: `agent/alloy/config.alloy` (append static scrapes)

- [ ] **Step 1: Append cAdvisor and state-exporter scrapes to `agent/alloy/config.alloy`**

```hcl
// ============================================================
// cAdvisor scrape — per-container resource metrics
// ============================================================

prometheus.scrape "cadvisor" {
  targets = [
    { __address__ = "cadvisor:8080", job = "cadvisor" },
  ]
  forward_to      = [prometheus.relabel.add_host_label.receiver]
  scrape_interval = "30s"
}

// ============================================================
// docker-state-exporter scrape — container_up for every
// container including stopped ones (closes the "crashed
// worker with no exposed ports" gap)
// ============================================================

prometheus.scrape "docker_state" {
  targets = [
    { __address__ = "docker-state-exporter:8080", job = "docker_state" },
  ]
  forward_to      = [prometheus.relabel.add_host_label.receiver]
  scrape_interval = "30s"
}
```

- [ ] **Step 2: Restart Alloy**

```bash
rtk docker compose -f compose.agent.yml --env-file .env.central restart alloy
rtk docker compose -f compose.agent.yml logs alloy | tail -n 20
```

Expected: no errors; log line about new components starting.

- [ ] **Step 3: Verify scrape status via Alloy UI**

```bash
rtk curl -s http://127.0.0.1:12345/api/v0/web/components/prometheus.scrape.cadvisor/json | grep -i 'state\|health\|error' | head
rtk curl -s http://127.0.0.1:12345/api/v0/web/components/prometheus.scrape.docker_state/json | grep -i 'state\|health\|error' | head
```

Expected: `"health": "healthy"` for both components.

- [ ] **Step 4: Commit**

```bash
rtk git add agent/alloy/config.alloy
rtk git commit -m "feat(agent): scrape cAdvisor and docker-state-exporter"
```

---

## Task 7: Alloy Docker log collection

**Files:**
- Modify: `agent/alloy/config.alloy` (append `loki.source.docker` + stub `loki.write`)

- [ ] **Step 1: Append log-collection sections to `agent/alloy/config.alloy`**

```hcl
// ============================================================
// Docker log collection
// ============================================================
// Tails stdout/stderr of every discovered container and
// pushes to central Loki with the same canonical label set.

loki.source.docker "containers" {
  host             = "tcp://docker-socket-proxy:2375"
  targets          = discovery.relabel.containers.output
  forward_to       = [loki.relabel.add_host_label.receiver]
  refresh_interval = "15s"
}

// Add host label and fan out to loki.write.
loki.relabel "add_host_label" {
  forward_to = [loki.write.central.receiver]

  rule {
    target_label = "host"
    replacement  = sys.env("HOSTNAME_LABEL")
  }
}

// ============================================================
// Central Loki push
// ============================================================

loki.write "central" {
  endpoint {
    url = sys.env("LOKI_URL")
  }
}
```

- [ ] **Step 2: Restart Alloy**

```bash
rtk docker compose -f compose.agent.yml --env-file .env.central restart alloy
rtk docker compose -f compose.agent.yml logs alloy 2>&1 | tail -n 30
```

Expected: config reloads without errors. Log-shipping errors like `connection refused` against the Loki URL are expected — Loki doesn't exist yet (created in Task 11). Alloy will buffer and retry.

- [ ] **Step 3: Verify the log source component is healthy**

```bash
rtk curl -s http://127.0.0.1:12345/api/v0/web/components/loki.source.docker.containers/json | grep -i 'health' | head
```

Expected: `"health": "healthy"`. (The `loki.write.central` component will report degraded/unhealthy due to connection failures, which is expected.)

- [ ] **Step 4: Commit**

```bash
rtk git add agent/alloy/config.alloy
rtk git commit -m "feat(agent): collect Docker container logs and push to Loki"
```

---

## Task 8: Central bundle skeleton with Prometheus

**Files:**
- Create: `compose.central.yml`
- Create: `central/prometheus/prometheus.yml`

- [ ] **Step 1: Create `central/prometheus/prometheus.yml`**

```yaml
global:
  scrape_interval:     30s
  evaluation_interval: 30s

# Alert rules loaded in Task 10
rule_files:
  - /etc/prometheus/rules/*.yml

# Alertmanager wired in Task 12
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

# Prometheus receives via remote_write from Alloy agents and
# does no scraping of its own. No scrape_configs needed.
```

- [ ] **Step 2: Create `compose.central.yml`**

```yaml
name: monitoring

networks:
  monitoring:
    driver: bridge

volumes:
  prometheus-data:

services:
  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-30d}
      - --web.enable-remote-write-receiver
      - --web.enable-lifecycle
    volumes:
      - ./central/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./central/prometheus/rules:/etc/prometheus/rules:ro
      - prometheus-data:/prometheus
    networks:
      - monitoring
```

Both compose files share `name: monitoring` and a network called `monitoring`. When you pass multiple `-f` flags, Compose merges them into one project and the two network definitions reconcile to a single network — so every service on every bundle can reach every other service by name. When the agent bundle is deployed alone on a remote host, it creates its own `monitoring` network in isolation, which is exactly what we want.

- [ ] **Step 3: Create an empty rules directory so the volume mount succeeds**

```bash
mkdir -p central/prometheus/rules
touch central/prometheus/rules/.gitkeep
```

- [ ] **Step 4: Validate and bring up Prometheus**

```bash
rtk docker compose -f compose.central.yml --env-file .env.central config
rtk docker compose -f compose.central.yml --env-file .env.central up -d prometheus
rtk docker compose -f compose.central.yml logs prometheus | tail -n 20
```

Expected: log lines `Server is ready to receive web requests`; no `error` entries.

- [ ] **Step 5: Verify the remote_write receiver is accepting writes (empty query)**

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- http://prometheus:9090/api/v1/query?query=up
```

Expected: JSON `{"status":"success","data":{"resultType":"vector","result":[]}}` — no samples yet because Alloy isn't wired to push.

- [ ] **Step 6: Commit**

```bash
rtk git add compose.central.yml central/prometheus/prometheus.yml central/prometheus/rules/.gitkeep
rtk git commit -m "feat(central): add Prometheus with remote_write receiver"
```

---

## Task 9: Wire Alloy remote_write to Prometheus and verify end-to-end

**Files:**
- Modify: `agent/alloy/config.alloy` (finalize `prometheus.relabel.add_host_label` + add `prometheus.remote_write`)

- [ ] **Step 1: Update `prometheus.relabel.add_host_label` and append `prometheus.remote_write`**

Find the existing `prometheus.relabel "add_host_label"` block from Task 5 and replace its `forward_to = []` with `forward_to = [prometheus.remote_write.central.receiver]`. The updated block:

```hcl
prometheus.relabel "add_host_label" {
  forward_to = [prometheus.remote_write.central.receiver]

  rule {
    target_label = "host"
    replacement  = sys.env("HOSTNAME_LABEL")
  }
}
```

Then append a new remote_write block at the end of the file:

```hcl
// ============================================================
// Central Prometheus remote_write
// ============================================================

prometheus.remote_write "central" {
  endpoint {
    url = sys.env("REMOTE_WRITE_URL")
  }
}
```

- [ ] **Step 2: Restart Alloy**

```bash
rtk docker compose -f compose.agent.yml --env-file .env.central restart alloy
rtk docker compose -f compose.agent.yml logs alloy 2>&1 | tail -n 20
```

Expected: config reloads successfully; no remote_write errors.

- [ ] **Step 3: Query Prometheus for metrics that should now be arriving**

Wait 45s for at least one scrape cycle, then:

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- 'http://prometheus:9090/api/v1/query?query=up'
```

Expected: `{"status":"success","data":{"resultType":"vector","result":[...]}}` with at least one entry for `job="cadvisor"` and one for `job="docker_state"`, each tagged `host="central"`.

- [ ] **Step 4: Query a cAdvisor metric**

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- 'http://prometheus:9090/api/v1/query?query=container_memory_usage_bytes' | head -c 500
```

Expected: non-empty `result` array.

- [ ] **Step 5: Query a blackbox probe result**

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- 'http://prometheus:9090/api/v1/query?query=probe_success' | head -c 500
```

Expected: non-empty `result` array with `host="central"` on each series.

- [ ] **Step 6: Commit**

```bash
rtk git add agent/alloy/config.alloy
rtk git commit -m "feat(agent): wire remote_write to central Prometheus"
```

---

## Task 10: Prometheus alert rules

**Files:**
- Create: `central/prometheus/rules/container-health.yml`
- Create: `central/prometheus/rules/host-health.yml`
- Delete: `central/prometheus/rules/.gitkeep`

- [ ] **Step 1: Create `central/prometheus/rules/container-health.yml`**

```yaml
groups:
  - name: container-health
    interval: 30s
    rules:
      - alert: ContainerDown
        # docker-state-exporter emits container_state with state label.
        # "running" == 1 means up; anything else counts as down.
        # Metric name may be docker_container_state or container_state
        # depending on exporter version — adjust if Task 3 fell back.
        expr: |
          max by (host, container_name) (
            docker_container_state{state="running"}
          ) == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Container {{ $labels.container_name }} on {{ $labels.host }} is down"
          description: "Container has been in a non-running state for more than 2 minutes."

      - alert: ProbeFailing
        expr: probe_success == 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "TCP probe failing for {{ $labels.instance }} on {{ $labels.host }}"
          description: "{{ $labels.container_name }} ({{ $labels.instance }}) has not responded to a TCP probe for 2 minutes."
```

- [ ] **Step 2: Create `central/prometheus/rules/host-health.yml`**

```yaml
groups:
  - name: host-health
    interval: 30s
    rules:
      - alert: HostDiskFull
        expr: |
          (
            sum by (host, device) (container_fs_usage_bytes{id="/"})
            /
            sum by (host, device) (container_fs_limit_bytes{id="/"})
          ) > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Disk > 90% full on {{ $labels.host }} ({{ $labels.device }})"
          description: "Root filesystem device {{ $labels.device }} has been over 90% for 10 minutes."

      - alert: HostMemoryHigh
        expr: |
          (
            sum by (host) (container_memory_working_set_bytes{id="/"})
            /
            sum by (host) (machine_memory_bytes)
          ) > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Memory > 90% used on {{ $labels.host }}"
          description: "Host memory usage has been over 90% for 10 minutes."
```

- [ ] **Step 3: Remove the placeholder and validate rules with promtool**

```bash
rm central/prometheus/rules/.gitkeep
rtk docker compose -f compose.central.yml exec prometheus promtool check rules /etc/prometheus/rules/container-health.yml /etc/prometheus/rules/host-health.yml
```

Expected: `SUCCESS: 2 rule files found` / `4 rules found`.

- [ ] **Step 4: Reload Prometheus to pick up rules**

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -q --method=POST http://prometheus:9090/-/reload
```

Then verify rules are loaded:

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- http://prometheus:9090/api/v1/rules | head -c 800
```

Expected: JSON listing `ContainerDown`, `ProbeFailing`, `HostDiskFull`, `HostMemoryHigh`.

- [ ] **Step 5: Commit**

```bash
rtk git add central/prometheus/rules/container-health.yml central/prometheus/rules/host-health.yml
rtk git rm central/prometheus/rules/.gitkeep
rtk git commit -m "feat(central): add container and host health alert rules"
```

---

## Task 11: Loki in the central bundle

**Files:**
- Create: `central/loki/loki-config.yml`
- Modify: `compose.central.yml` (append `loki` service + volume)

- [ ] **Step 1: Create `central/loki/loki-config.yml`**

```yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: ${LOKI_RETENTION}
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  allow_structured_metadata: true

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: filesystem

ruler:
  storage:
    type: local
    local:
      directory: /loki/rules-local
  rule_path: /loki/rules-temp
  alertmanager_url: http://alertmanager:9093
  ring:
    kvstore:
      store: inmemory
```

Note: `${LOKI_RETENTION}` is substituted by Loki itself via its `-config.expand-env=true` flag, set in the compose command below.

- [ ] **Step 2: Append Loki to `compose.central.yml`**

Add a new volume to the top-level `volumes:` block:

```yaml
  loki-data:
```

Append a `loki` service:

```yaml
  loki:
    image: grafana/loki:3.2.1
    container_name: loki
    restart: unless-stopped
    command:
      - -config.file=/etc/loki/config.yml
      - -config.expand-env=true
    environment:
      LOKI_RETENTION: ${LOKI_RETENTION:-336h}
    volumes:
      - ./central/loki/loki-config.yml:/etc/loki/config.yml:ro
      - loki-data:/loki
    networks:
      - monitoring
```

- [ ] **Step 3: Validate and bring up Loki**

```bash
rtk docker compose -f compose.central.yml --env-file .env.central config
rtk docker compose -f compose.central.yml --env-file .env.central up -d loki
rtk docker compose -f compose.central.yml logs loki 2>&1 | tail -n 30
```

Expected: `Loki started` / `msg="Loki started"` log line; no fatal errors.

- [ ] **Step 4: Verify Loki readiness**

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- http://loki:3100/ready
```

Expected: `ready`.

- [ ] **Step 5: Verify Alloy is now successfully pushing logs**

```bash
rtk docker compose -f compose.agent.yml logs alloy 2>&1 | grep -i 'loki.write' | tail -n 10
```

Expected: no `connection refused` errors (Alloy was retrying since Task 7; should now succeed).

Query Loki for recent labels:

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- 'http://loki:3100/loki/api/v1/labels' | head -c 500
```

Expected: JSON including `host`, `container_name`, `compose_project`, `compose_service`.

- [ ] **Step 6: Commit**

```bash
rtk git add central/loki/loki-config.yml compose.central.yml
rtk git commit -m "feat(central): add Loki for log storage"
```

---

## Task 12: Alertmanager with SMTP template

**Files:**
- Create: `central/alertmanager/alertmanager.yml.tmpl`
- Create: `central/alertmanager/entrypoint.sh`
- Modify: `compose.central.yml` (append `alertmanager` service + volume)

Alertmanager itself does not expand environment variables in its config. We use a tiny entrypoint that renders the template with `envsubst` and execs alertmanager. This keeps SMTP credentials out of the committed config.

- [ ] **Step 1: Create `central/alertmanager/alertmanager.yml.tmpl`**

```yaml
route:
  group_by: ['alertname', 'host']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: email

receivers:
  - name: email
    email_configs:
      - to: '${ALERT_TO}'
        from: '${SMTP_FROM}'
        smarthost: '${SMTP_HOST}:${SMTP_PORT}'
        auth_username: '${SMTP_USERNAME}'
        auth_password: '${SMTP_PASSWORD}'
        require_tls: true
        send_resolved: true
```

- [ ] **Step 2: Create `central/alertmanager/entrypoint.sh`**

```sh
#!/bin/sh
set -eu

# Render the SMTP template with values from the container env.
envsubst < /etc/alertmanager/alertmanager.yml.tmpl > /etc/alertmanager/alertmanager.yml

# Exec the real alertmanager binary with forwarded args.
exec /bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/alertmanager \
  "$@"
```

Make it executable:

```bash
chmod +x central/alertmanager/entrypoint.sh
```

- [ ] **Step 3: Append Alertmanager service to `compose.central.yml`**

Add to top-level volumes:

```yaml
  alertmanager-data:
```

Append service:

```yaml
  alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: alertmanager
    restart: unless-stopped
    entrypoint: ["/bin/sh", "/entrypoint.sh"]
    environment:
      ALERT_TO: ${ALERT_TO}
      SMTP_FROM: ${SMTP_FROM}
      SMTP_HOST: ${SMTP_HOST}
      SMTP_PORT: ${SMTP_PORT}
      SMTP_USERNAME: ${SMTP_USERNAME}
      SMTP_PASSWORD: ${SMTP_PASSWORD}
    volumes:
      - ./central/alertmanager/alertmanager.yml.tmpl:/etc/alertmanager/alertmanager.yml.tmpl:ro
      - ./central/alertmanager/entrypoint.sh:/entrypoint.sh:ro
      - alertmanager-data:/alertmanager
    networks:
      - monitoring
```

The Alertmanager base image is `alpine`-based and has `envsubst` available via the `gettext` package — but not guaranteed. Safer: use `busybox sh` with a manual substitution, OR pre-install. The cleanest workaround is to use `prom/alertmanager` which is based on a scratch-ish distroless image without `envsubst`. Use the `prom/alertmanager` image with a sidecar-style init, OR use the image `alpine:3.20` with alertmanager binary copied in.

**Simpler approach:** override the image entirely. Use `alpine:3.20` with a small install step, OR use `linuxserver/alertmanager` which has a shell. Since installing busybox breaks reproducibility, use a two-stage approach — a `sh -c` that uses POSIX parameter expansion instead of `envsubst`:

Replace the entrypoint.sh with:

```sh
#!/bin/sh
set -eu

# POSIX-only template rendering — replace ${VAR} placeholders.
sed \
  -e "s|\${ALERT_TO}|$ALERT_TO|g" \
  -e "s|\${SMTP_FROM}|$SMTP_FROM|g" \
  -e "s|\${SMTP_HOST}|$SMTP_HOST|g" \
  -e "s|\${SMTP_PORT}|$SMTP_PORT|g" \
  -e "s|\${SMTP_USERNAME}|$SMTP_USERNAME|g" \
  -e "s|\${SMTP_PASSWORD}|$SMTP_PASSWORD|g" \
  /etc/alertmanager/alertmanager.yml.tmpl \
  > /tmp/alertmanager.yml

exec /bin/alertmanager \
  --config.file=/tmp/alertmanager.yml \
  --storage.path=/alertmanager \
  "$@"
```

`prom/alertmanager` is based on busybox and includes `sh` and `sed`. This runs without extra installs.

- [ ] **Step 4: Validate and bring up**

```bash
rtk docker compose -f compose.central.yml --env-file .env.central config
rtk docker compose -f compose.central.yml --env-file .env.central up -d alertmanager
rtk docker compose -f compose.central.yml logs alertmanager 2>&1 | tail -n 30
```

Expected: `Listening address=:9093`. No template parsing errors (even with placeholder SMTP values from `.env.central.example`).

- [ ] **Step 5: Verify Prometheus sees the Alertmanager**

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- http://prometheus:9090/api/v1/alertmanagers
```

Expected: JSON with one entry whose `url` ends in `/api/v2/alerts` and `activeAlertmanagers[0].url` includes `alertmanager:9093`.

- [ ] **Step 6: Commit**

```bash
rtk git add central/alertmanager/alertmanager.yml.tmpl central/alertmanager/entrypoint.sh compose.central.yml
rtk git commit -m "feat(central): add Alertmanager with SMTP template rendering"
```

---

## Task 13: Grafana with provisioned datasources

**Files:**
- Create: `central/grafana/provisioning/datasources/datasources.yml`
- Create: `central/grafana/provisioning/dashboards/dashboards.yml`
- Modify: `compose.central.yml` (append `grafana` service + volume)

- [ ] **Step 1: Create `central/grafana/provisioning/datasources/datasources.yml`**

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 30s

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: false
    jsonData:
      maxLines: 5000
```

- [ ] **Step 2: Create `central/grafana/provisioning/dashboards/dashboards.yml`**

```yaml
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: true
    editable: false
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/provisioning/dashboards
      foldersFromFilesStructure: false
```

- [ ] **Step 3: Append Grafana service to `compose.central.yml`**

Add to top-level volumes:

```yaml
  grafana-data:
```

Append service:

```yaml
  grafana:
    image: grafana/grafana:11.3.0
    container_name: grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD required}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_AUTH_ANONYMOUS_ENABLED: "false"
      GF_SERVER_ROOT_URL: https://${DOMAIN}
      GF_INSTALL_PLUGINS: ""
    volumes:
      - ./central/grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana-data:/var/lib/grafana
    depends_on:
      - prometheus
      - loki
    networks:
      - monitoring
```

- [ ] **Step 4: Validate and bring up**

```bash
rtk docker compose -f compose.central.yml --env-file .env.central config
rtk docker compose -f compose.central.yml --env-file .env.central up -d grafana
rtk docker compose -f compose.central.yml logs grafana 2>&1 | tail -n 20
```

Expected: `HTTP Server Listen` log line; no provisioning errors.

- [ ] **Step 5: Verify datasources via Grafana API**

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- --user=admin --password=changeme http://grafana:3000/api/datasources
```

Use whatever password is in your `.env.central`. Expected: JSON array with two entries, one `Prometheus` and one `Loki`, each with `readOnly: true`.

- [ ] **Step 6: Commit**

```bash
rtk git add central/grafana/provisioning/datasources/datasources.yml central/grafana/provisioning/dashboards/dashboards.yml compose.central.yml
rtk git commit -m "feat(central): add Grafana with provisioned datasources"
```

---

## Task 14: Containers overview dashboard

**Files:**
- Create: `central/grafana/provisioning/dashboards/containers-overview.json`

This dashboard shows a per-(host, container) table with status, uptime, and resource usage — the primary "is my stuff up?" view.

- [ ] **Step 1: Create `central/grafana/provisioning/dashboards/containers-overview.json`**

```json
{
  "annotations": { "list": [] },
  "editable": false,
  "graphTooltip": 0,
  "schemaVersion": 39,
  "title": "Containers Overview",
  "uid": "containers-overview",
  "tags": ["monitoring", "containers"],
  "timezone": "",
  "time": { "from": "now-1h", "to": "now" },
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "name": "host",
        "label": "Host",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": { "query": "label_values(up, host)", "refId": "host" },
        "includeAll": true,
        "multi": true,
        "refresh": 2,
        "sort": 1
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "Container status",
      "type": "table",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "max by (host, container_name) (docker_container_state{state=\"running\", host=~\"$host\"})",
          "format": "table",
          "instant": true
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            { "type": "value", "options": { "0": { "text": "DOWN", "color": "red" }, "1": { "text": "UP", "color": "green" } } }
          ],
          "custom": { "align": "left", "displayMode": "color-background" }
        },
        "overrides": []
      },
      "gridPos": { "h": 10, "w": 12, "x": 0, "y": 0 }
    },
    {
      "id": 2,
      "title": "Probe success",
      "type": "table",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "probe_success{host=~\"$host\"}",
          "format": "table",
          "instant": true
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            { "type": "value", "options": { "0": { "text": "FAIL", "color": "red" }, "1": { "text": "OK", "color": "green" } } },
            { "type": "value", "options": { "1": { "text": "OK", "color": "green" } } }
          ]
        },
        "overrides": []
      },
      "gridPos": { "h": 10, "w": 12, "x": 12, "y": 0 }
    },
    {
      "id": 3,
      "title": "CPU usage by container",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (host, name) (rate(container_cpu_usage_seconds_total{host=~\"$host\", name!=\"\"}[2m]))",
          "legendFormat": "{{host}} / {{name}}"
        }
      ],
      "gridPos": { "h": 10, "w": 12, "x": 0, "y": 10 }
    },
    {
      "id": 4,
      "title": "Memory usage by container",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (host, name) (container_memory_working_set_bytes{host=~\"$host\", name!=\"\"})",
          "legendFormat": "{{host}} / {{name}}"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] },
      "gridPos": { "h": 10, "w": 12, "x": 12, "y": 10 }
    }
  ]
}
```

Note: the datasource `uid` references assume Grafana will assign `uid=prometheus` to the provisioned Prometheus datasource. Grafana derives uids from datasource names by default but may also assign random uids. If the dashboard panels show "datasource not found" after provisioning, add explicit `uid` fields to `datasources.yml`:

```yaml
  - name: Prometheus
    uid: prometheus
    type: prometheus
    ...
  - name: Loki
    uid: loki
    type: loki
    ...
```

(Apply this fix if Step 3 reveals the issue.)

- [ ] **Step 2: Restart Grafana to pick up the new dashboard**

```bash
rtk docker compose -f compose.central.yml restart grafana
rtk docker compose -f compose.central.yml logs grafana 2>&1 | tail -n 20
```

Expected: log lines about dashboard provisioning; no `failed to load dashboard` errors.

- [ ] **Step 3: Verify the dashboard exists and panels return data**

```bash
rtk docker compose -f compose.agent.yml exec alloy wget -qO- --user=admin --password=changeme http://grafana:3000/api/search?query=Containers
```

Expected: JSON array containing the `Containers Overview` dashboard.

Open `http://127.0.0.1:3000` in a browser via SSH tunnel or `docker compose ... exec` with port publish (for local dev, temporarily add `ports: ["127.0.0.1:3000:3000"]` to the grafana service). Visually confirm:
- Host template variable populates with `central`.
- Container status table shows rows for discovered containers.
- CPU and memory panels show graphs.

- [ ] **Step 4: Commit**

```bash
rtk git add central/grafana/provisioning/dashboards/containers-overview.json
# If the datasource uid fix was needed:
# rtk git add central/grafana/provisioning/datasources/datasources.yml
rtk git commit -m "feat(central): add containers overview dashboard"
```

---

## Task 15: Host overview dashboard

**Files:**
- Create: `central/grafana/provisioning/dashboards/host-overview.json`

- [ ] **Step 1: Create `central/grafana/provisioning/dashboards/host-overview.json`**

```json
{
  "annotations": { "list": [] },
  "editable": false,
  "graphTooltip": 0,
  "schemaVersion": 39,
  "title": "Host Overview",
  "uid": "host-overview",
  "tags": ["monitoring", "hosts"],
  "timezone": "",
  "time": { "from": "now-6h", "to": "now" },
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "name": "host",
        "label": "Host",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": { "query": "label_values(machine_memory_bytes, host)", "refId": "host" },
        "includeAll": true,
        "multi": true,
        "refresh": 2,
        "sort": 1
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "CPU usage (whole host)",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (host) (rate(container_cpu_usage_seconds_total{host=~\"$host\", id=\"/\"}[2m]))",
          "legendFormat": "{{host}}"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "percentunit" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 }
    },
    {
      "id": 2,
      "title": "Memory used / total",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (host) (container_memory_working_set_bytes{host=~\"$host\", id=\"/\"})",
          "legendFormat": "{{host}} used"
        },
        {
          "refId": "B",
          "expr": "sum by (host) (machine_memory_bytes{host=~\"$host\"})",
          "legendFormat": "{{host}} total"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 }
    },
    {
      "id": 3,
      "title": "Filesystem usage",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (host, device) (container_fs_usage_bytes{host=~\"$host\", id=\"/\"})",
          "legendFormat": "{{host}} {{device}}"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 }
    },
    {
      "id": 4,
      "title": "Network bytes/s",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (host) (rate(container_network_receive_bytes_total{host=~\"$host\", id=\"/\"}[2m]))",
          "legendFormat": "{{host}} rx"
        },
        {
          "refId": "B",
          "expr": "sum by (host) (rate(container_network_transmit_bytes_total{host=~\"$host\", id=\"/\"}[2m]))",
          "legendFormat": "{{host}} tx"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "Bps" }, "overrides": [] },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 }
    }
  ]
}
```

- [ ] **Step 2: Restart Grafana and verify**

```bash
rtk docker compose -f compose.central.yml restart grafana
rtk docker compose -f compose.agent.yml exec alloy wget -qO- --user=admin --password=changeme http://grafana:3000/api/search?query=Host
```

Expected: `Host Overview` in the result array.

Visually confirm in-browser: host variable populates, CPU/memory/fs/network panels all render.

- [ ] **Step 3: Commit**

```bash
rtk git add central/grafana/provisioning/dashboards/host-overview.json
rtk git commit -m "feat(central): add host overview dashboard"
```

---

## Task 16: Logs explorer dashboard

**Files:**
- Create: `central/grafana/provisioning/dashboards/logs-explorer.json`

- [ ] **Step 1: Create `central/grafana/provisioning/dashboards/logs-explorer.json`**

```json
{
  "annotations": { "list": [] },
  "editable": false,
  "graphTooltip": 0,
  "schemaVersion": 39,
  "title": "Logs Explorer",
  "uid": "logs-explorer",
  "tags": ["monitoring", "logs"],
  "timezone": "",
  "time": { "from": "now-1h", "to": "now" },
  "refresh": "10s",
  "templating": {
    "list": [
      {
        "name": "host",
        "label": "Host",
        "type": "query",
        "datasource": { "type": "loki", "uid": "loki" },
        "query": "label_values(host)",
        "includeAll": true,
        "multi": true,
        "refresh": 2
      },
      {
        "name": "container",
        "label": "Container",
        "type": "query",
        "datasource": { "type": "loki", "uid": "loki" },
        "query": "label_values({host=~\"$host\"}, container_name)",
        "includeAll": true,
        "multi": true,
        "refresh": 2
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "Log volume",
      "type": "timeseries",
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (host, container_name) (rate({host=~\"$host\", container_name=~\"$container\"}[1m]))",
          "legendFormat": "{{host}} / {{container_name}}"
        }
      ],
      "gridPos": { "h": 6, "w": 24, "x": 0, "y": 0 }
    },
    {
      "id": 2,
      "title": "Logs",
      "type": "logs",
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [
        {
          "refId": "A",
          "expr": "{host=~\"$host\", container_name=~\"$container\"}"
        }
      ],
      "options": {
        "showTime": true,
        "showLabels": false,
        "showCommonLabels": false,
        "wrapLogMessage": true,
        "prettifyLogMessage": false,
        "enableLogDetails": true,
        "dedupStrategy": "none",
        "sortOrder": "Descending"
      },
      "gridPos": { "h": 18, "w": 24, "x": 0, "y": 6 }
    }
  ]
}
```

- [ ] **Step 2: Restart Grafana and verify**

```bash
rtk docker compose -f compose.central.yml restart grafana
rtk docker compose -f compose.agent.yml exec alloy wget -qO- --user=admin --password=changeme http://grafana:3000/api/search?query=Logs
```

Expected: `Logs Explorer` in result.

Visually confirm: host + container variables populate, log volume panel shows rates, logs panel streams recent lines from selected containers.

- [ ] **Step 3: Commit**

```bash
rtk git add central/grafana/provisioning/dashboards/logs-explorer.json
rtk git commit -m "feat(central): add logs explorer dashboard"
```

---

## Task 17: Caddy reverse proxy with automatic HTTPS

**Files:**
- Create: `central/caddy/Caddyfile`
- Modify: `compose.central.yml` (append `caddy` service + volumes)

- [ ] **Step 1: Create `central/caddy/Caddyfile`**

```caddy
{
  # Set ACME email for Let's Encrypt account (optional but recommended).
  # Engineers can export CADDY_ACME_EMAIL in .env.central if desired.
  email {$CADDY_ACME_EMAIL}
}

{$DOMAIN} {
  encode gzip
  reverse_proxy grafana:3000
}
```

- [ ] **Step 2: Append Caddy to `compose.central.yml`**

Add to top-level volumes:

```yaml
  caddy-data:
  caddy-config:
```

Append service:

```yaml
  caddy:
    image: caddy:2.8-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    environment:
      DOMAIN: ${DOMAIN:?DOMAIN required}
      CADDY_ACME_EMAIL: ${CADDY_ACME_EMAIL:-}
    volumes:
      - ./central/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      - grafana
    networks:
      - monitoring
```

Optionally add `CADDY_ACME_EMAIL` to `.env.central.example` — add at the end:

```dotenv
# Optional: email for Let's Encrypt account notifications
CADDY_ACME_EMAIL=
```

- [ ] **Step 3: Validate and bring up**

```bash
rtk docker compose -f compose.central.yml --env-file .env.central config
rtk docker compose -f compose.central.yml --env-file .env.central up -d caddy
rtk docker compose -f compose.central.yml logs caddy 2>&1 | tail -n 20
```

Expected for local dev (`DOMAIN=monitoring.localhost`): Caddy will try to obtain a cert and fail (Let's Encrypt cannot validate `localhost`). This is fine — Caddy falls back to a self-signed internal cert. Verify the reverse proxy works over plain HTTP on port 80:

```bash
rtk curl -s -o /dev/null -w "%{http_code}\n" -H "Host: monitoring.localhost" http://127.0.0.1:80/
```

Expected: `200` or a `30x` redirect to HTTPS. If it's a redirect, follow it with `-L -k`:

```bash
rtk curl -sL -k -o /dev/null -w "%{http_code}\n" -H "Host: monitoring.localhost" https://127.0.0.1:443/
```

Expected: `200`.

- [ ] **Step 4: Commit**

```bash
rtk git add central/caddy/Caddyfile compose.central.yml .env.central.example
rtk git commit -m "feat(central): add Caddy reverse proxy with auto-HTTPS"
```

---

## Task 18: Test override with MailHog and dummy containers

**Files:**
- Create: `compose.test.yml`

This override adds a MailHog SMTP catcher (so alert emails can be inspected locally without a real SMTP server) and a handful of dummy containers exercising the discovery matrix: HTTP exposed port, no exposed ports, and a container that will be stopped to trigger alerts.

- [ ] **Step 1: Create `compose.test.yml`**

```yaml
# Test override: run alongside the main compose files to validate
# the full pipeline locally.
#
# Usage:
#   docker compose -f compose.central.yml -f compose.agent.yml -f compose.test.yml \
#     --env-file .env.central up -d

name: monitoring-central

services:
  # MailHog catches alertmanager SMTP traffic locally.
  # UI at http://127.0.0.1:8025
  mailhog:
    image: mailhog/mailhog:v1.0.1
    container_name: mailhog
    restart: unless-stopped
    ports:
      - "127.0.0.1:8025:8025"  # web UI
    networks:
      - monitoring

  # Dummy HTTP service — discovered, probed on port 80.
  dummy-http:
    image: nginxdemos/hello:plain-text
    container_name: dummy-http
    restart: unless-stopped
    networks:
      - monitoring

  # Dummy TCP service — discovered, probed on port 6379.
  dummy-redis:
    image: redis:7-alpine
    container_name: dummy-redis
    restart: unless-stopped
    networks:
      - monitoring

  # Dummy worker — no exposed ports. Only visible via
  # docker-state-exporter's container_up metric.
  dummy-worker:
    image: busybox:1.36
    container_name: dummy-worker
    restart: unless-stopped
    command: ["sh", "-c", "while true; do echo heartbeat; sleep 30; done"]
    networks:
      - monitoring

  # Override alertmanager SMTP to point at MailHog.
  alertmanager:
    environment:
      SMTP_HOST: mailhog
      SMTP_PORT: "1025"
      SMTP_USERNAME: ""
      SMTP_PASSWORD: ""
      SMTP_FROM: alerts@monitoring.local
      ALERT_TO: oncall@monitoring.local
```

The alertmanager override also needs to skip `require_tls` since MailHog doesn't support TLS. Update `central/alertmanager/alertmanager.yml.tmpl` to make `require_tls` driven by an env var, OR add a second template for test use. Simpler: make the SMTP block tolerant. Replace the `require_tls: true` line in `alertmanager.yml.tmpl` with:

```yaml
        require_tls: ${SMTP_REQUIRE_TLS}
```

And add to the sed script in `entrypoint.sh`:

```sh
  -e "s|\${SMTP_REQUIRE_TLS}|${SMTP_REQUIRE_TLS:-true}|g" \
```

And add `SMTP_REQUIRE_TLS` to the alertmanager service environment in `compose.central.yml`:

```yaml
      SMTP_REQUIRE_TLS: ${SMTP_REQUIRE_TLS:-true}
```

And in `compose.test.yml`'s alertmanager override add:

```yaml
      SMTP_REQUIRE_TLS: "false"
```

- [ ] **Step 2: Bring up the full stack with the test override**

```bash
rtk docker compose -f compose.central.yml -f compose.agent.yml -f compose.test.yml --env-file .env.central up -d
```

Wait ~60 seconds for everything to stabilize.

- [ ] **Step 3: Verify dummy containers are discovered and probed**

```bash
rtk docker compose exec alloy wget -qO- 'http://prometheus:9090/api/v1/query?query=probe_success{container_name=~"dummy-.*"}' | head -c 500
```

Expected: two entries, one for `dummy-http` and one for `dummy-redis`, both with `value` = 1.

```bash
rtk docker compose exec alloy wget -qO- 'http://prometheus:9090/api/v1/query?query=docker_container_state{container_name="dummy-worker",state="running"}' | head -c 500
```

Expected: one entry with value 1.

- [ ] **Step 4: Trigger a ContainerDown alert**

```bash
rtk docker compose -f compose.central.yml -f compose.agent.yml -f compose.test.yml stop dummy-worker
```

Wait 3 minutes (2m alert threshold + some buffer). Then check that an alert fired and MailHog caught it:

```bash
rtk docker compose exec alloy wget -qO- 'http://prometheus:9090/api/v1/alerts' | head -c 800
```

Expected: `ContainerDown` appears in the active alerts, state `firing`.

```bash
rtk curl -s http://127.0.0.1:8025/api/v2/messages | head -c 800
```

Expected: JSON with at least one message addressed to `oncall@monitoring.local` with subject containing `[FIRING]`.

- [ ] **Step 5: Restart `dummy-worker` and confirm the alert resolves**

```bash
rtk docker compose -f compose.central.yml -f compose.agent.yml -f compose.test.yml start dummy-worker
```

Wait ~90 seconds, then:

```bash
rtk docker compose exec alloy wget -qO- 'http://prometheus:9090/api/v1/alerts' | head -c 800
```

Expected: the `ContainerDown` alert is gone (or in state `resolved`).

MailHog should have received a `[RESOLVED]` email.

- [ ] **Step 6: Commit**

```bash
rtk git add compose.test.yml central/alertmanager/alertmanager.yml.tmpl central/alertmanager/entrypoint.sh compose.central.yml
rtk git commit -m "test: add MailHog + dummy containers compose override"
```

---

## Task 19: README with deployment instructions

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace `README.md`**

```markdown
# server-monitoring

Self-contained, Docker-deployable server monitoring stack. Auto-discovers
every container on every host via the Docker socket — **with zero labels,
sidecars, or config changes on the monitored services** — and reports
uptime, resource usage, and logs in a single Grafana UI.

## What it replaces

- **Uptime Kuma** — per-container uptime with first-class auto-discovery,
  no hand-rolled Socket.IO glue.
- **Dozzle** — per-container log streaming via Grafana + Loki.
- Plus: historical metrics, alerting via email, and a clean multi-host
  story none of the above offer out of the box.

## Architecture

Two compose bundles shipped from this repo:

| Bundle            | File                  | Runs on           | Components                                                                                  |
| ----------------- | --------------------- | ----------------- | ------------------------------------------------------------------------------------------- |
| **Central**       | `compose.central.yml` | One host          | Prometheus, Loki, Alertmanager, Grafana, Caddy                                              |
| **Agent**         | `compose.agent.yml`   | Every host        | Grafana Alloy, cAdvisor, docker-state-exporter, Blackbox exporter, docker-socket-proxy     |

The central host runs **both** bundles. Remote hosts run only the agent
bundle and push metrics and logs to the central host over a private
network.

## Deploying the central host

```bash
git clone <this repo> server-monitoring
cd server-monitoring

cp .env.central.example .env.central
# Edit DOMAIN, GRAFANA_ADMIN_PASSWORD, SMTP_*, ALERT_TO, HOSTNAME_LABEL.

docker compose -f compose.central.yml -f compose.agent.yml --env-file .env.central up -d
```

Grafana is reachable at `https://<DOMAIN>/` once Caddy obtains a cert.

## Adding a remote host

On each host you want to monitor:

```bash
git clone <this repo> server-monitoring
cd server-monitoring

cp .env.agent.example .env.agent
# Set HOSTNAME_LABEL (unique per host), REMOTE_WRITE_URL, LOKI_URL
# to point at the central host's private-network address.

docker compose -f compose.agent.yml --env-file .env.agent up -d
```

The new host starts pushing immediately. Grafana dashboards populate it
automatically — no central-side configuration change is needed.

## Customizing what gets monitored

The `EXCLUDE_NAMES` regex in the env files controls which containers are
skipped. By default it excludes the monitoring stack's own containers.
To also skip, say, all containers named `test-*`:

```dotenv
EXCLUDE_NAMES=^(alloy|cadvisor|docker-socket-proxy|docker-state-exporter|blackbox|test-.*)$
```

No changes are needed on the monitored containers themselves — discovery
is entirely label-free.

## Local testing

`compose.test.yml` adds MailHog (SMTP catcher) and dummy containers that
exercise the full discovery and alerting flow:

```bash
docker compose -f compose.central.yml -f compose.agent.yml -f compose.test.yml \
  --env-file .env.central up -d

# MailHog UI (captured alert emails)
open http://127.0.0.1:8025
```

## Dashboards

- **Containers Overview** — per-container up/down, CPU, memory
- **Host Overview** — per-host CPU, memory, filesystem, network
- **Logs Explorer** — Loki log search with host and container filters

All three are provisioned from `central/grafana/provisioning/dashboards/`
and reload automatically when you edit the JSON files.

## Retention defaults

- Metrics: 30 days (`PROMETHEUS_RETENTION`)
- Logs: 14 days (`LOKI_RETENTION`)

Adjust in `.env.central`.

## Alert rules

Defined in `central/prometheus/rules/`:

- **ContainerDown** — fires after 2 minutes of `docker_container_state != running`
- **ProbeFailing** — fires after 2 minutes of `probe_success == 0`
- **HostDiskFull** — fires after 10 minutes of root fs > 90%
- **HostMemoryHigh** — fires after 10 minutes of memory > 90%

All alerts route to the email address in `ALERT_TO`.

## Design

See [docs/superpowers/specs/2026-04-13-server-monitoring-stack-design.md](docs/superpowers/specs/2026-04-13-server-monitoring-stack-design.md)
for the full design rationale and tradeoffs.
```

- [ ] **Step 2: Commit**

```bash
rtk git add README.md
rtk git commit -m "docs: replace README stub with full deployment guide"
```

---

## Post-implementation checklist

After the final task, verify the whole stack end-to-end one more time:

- [ ] `rtk docker compose -f compose.central.yml -f compose.agent.yml -f compose.test.yml --env-file .env.central down -v` (clean slate, **-v** drops volumes too)
- [ ] `rtk docker compose -f compose.central.yml -f compose.agent.yml -f compose.test.yml --env-file .env.central up -d`
- [ ] Wait 90 seconds
- [ ] All three dashboards render with data in Grafana
- [ ] Stopping `dummy-worker` fires `ContainerDown` within 2–3 minutes
- [ ] Email lands in MailHog
- [ ] Starting `dummy-worker` resolves the alert and sends a `[RESOLVED]` email
- [ ] `rtk docker compose -f compose.central.yml -f compose.agent.yml -f compose.test.yml --env-file .env.central down`

If any step fails, the failure is almost always:
1. A typo in a config file — re-run `docker compose ... config` and `promtool check rules`.
2. A network-name mismatch — `compose.central.yml` joins the network the agent bundle created; if project names were customized, update the `networks.monitoring.name` reference.
3. The `docker-state-exporter` metric name mismatch from Task 3's contingency — update the alert rule expression to match the exporter variant actually in use.
