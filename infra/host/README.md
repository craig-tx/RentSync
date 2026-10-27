# Host files

Everything an EC2 host runs besides its AMI comes from this directory. Terraform reads each file
and passes it to cloud-init in the host's user data (feature 002 research R6), so a host is
rebuilt from these files every time it is replaced.

**Changing a file here replaces hosts.** User data changes force replacement
(`user_data_replace_on_change`). The data volume, Elastic IP and certificates are kept
(runbook §Host replacement), but each affected host is down for a few minutes. A merge that
touches this directory queues runs in all three HCP Terraform workspaces:
`rentsync-dev-staging` applies on its own; `rentsync-shared-us` and `rentsync-prod-us` wait
for confirmation. This README and `test/` are not passed to hosts, so editing them queues runs
that plan only changes already waiting to be applied.

| File | On the host | Hosts | Purpose |
|---|---|---|---|
| `bin/rentsync-boot` | `/usr/local/bin/` | all | mounts the data volume at `/srv/data`; formats it only if it has no filesystem |
| `bin/rentsync-swap` | `/usr/local/bin/` | all | creates the 1 GiB swap file at first boot (`swap_mib`) |
| `bin/rentsync-render-env` | `/usr/local/bin/` | all | renders `/run/rentsync/env` (tmpfs, 0600) from SSM Parameter Store |
| `bin/rentsync-start` | `/usr/local/bin/` | all | starts the host's Compose stack on every boot |
| `bin/rentsync-deploy` | `/usr/local/bin/` | environments | deploys an image and proves it healthy, or rolls back |
| `systemd/rentsync.service` | `/etc/systemd/system/` | all | runs `rentsync-boot`, then `rentsync-start`, on every boot, retrying on failure |
| `systemd/rentsync-prune.service`, `.timer` | `/etc/systemd/system/` | all | weekly prune of images unused for a week |
| `systemd/docker-rentsync.conf` | `/etc/systemd/system/docker.service.d/rentsync.conf` | all | Docker waits for `/srv/data` to be mounted |
| `daemon.json` | `/etc/docker/` | all | container log rotation (10 MB × 3) |
| `sysctl-rentsync.conf` | `/etc/sysctl.d/90-rentsync.conf` | all | `vm.swappiness = 10` |
| `compose.env.yaml` | `/opt/rentsync/compose.yaml` | environments | the stack: Caddy, mock PMS web and worker, Postgres, Redis, Collector |
| `Caddyfile.env` | `/opt/rentsync/Caddyfile` | environments | HTTPS for `<hostname>`, proxied to the mock PMS |
| `compose.telemetry.yaml` | `/opt/rentsync/compose.yaml` | telemetry | the stack: Caddy, OpenObserve, its Postgres |
| `Caddyfile.telemetry` | `/opt/rentsync/Caddyfile` | telemetry | HTTPS for `telemetry.<domain>`, proxied to OpenObserve |

The environment hosts also get `infra/otel/collector.yaml` as `/opt/rentsync/collector.yaml`.

**Where each is wired in:** files for every host in `infra/terraform/modules/host/main.tf`
(`base_files`); role-specific ones in `infra/terraform/environment/host.tf` and
`infra/terraform/shared/telemetry.tf`. A new file needs an entry there, and if it lives outside
this directory, the workspaces' trigger patterns in `infra/bootstrap/bootstrap-hcp.rb` must
cover it (a test checks this).

**Tests** (`test/`): `render_env_test.sh` and `deploy_test.sh` run in the infra test container
(`bash infra/test/run.sh`); `boot_volume_test.sh` and `swap_test.sh` need root on Linux and run
in CI; `rehearse/` runs the real host scripts against real containers in Docker
(`bash infra/host/test/rehearse/rehearse.sh`).
