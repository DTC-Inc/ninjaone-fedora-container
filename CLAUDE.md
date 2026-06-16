# CLAUDE.md

## Project

Containerized NinjaOne Linux agent for hosts where the vendor RPM can't install directly — immutable distributions (rpm-ostree) and storage appliances (TrueNAS SCALE). The container runs **systemd as PID 1**, so the agent installs and supervises its own services (agent, patcher timer, and the **Lockhart backup daemon**) exactly as on a normal host. Running backups (Lockhart) is the reason for the systemd-init design — a leaner "agent-as-PID-1" container can't supervise it.

Owner: Nate Smith (`nate.smith@dtctoday.com`). Reviewers: TBD.

## Repo links

- Production deployment guide → [README.md](./README.md)
- Contributor workflow → [DEVELOPMENT.md](./DEVELOPMENT.md)
- Cross-cutting DTC standards → [Developer Operations book](https://kb.dtctoday.com/books/developer-operations-devops)

## Stack

- Container runtime: Podman (rootful, system quadlet, `--systemd=always`) or Docker Compose (incl. TrueNAS Custom App)
- Base image: `registry.fedoraproject.org/fedora:41`, **systemd as PID 1**
- Language: Bash for the bootstrap + helper scripts; systemd units; YAML for quadlet/compose/CI
- CI: GitHub Actions → GHCR (`ghcr.io/dtc-inc/ninjaone-fedora-container`)
- Vendor artifact: NinjaOne Linux agent RPM (token-stamped, per-deployment, never committed). Acquired at runtime via `NINJA_AGENT_URL` (the bootstrap unit installs it on first boot) or baked in at build time.

## Critical invariants

These are easy to break and hard to debug — call them out in any review:

1. **systemd is PID 1; the container is NOT `--pid=host`.** systemd refuses to boot unless it's PID 1, which is incompatible with `--pid=host`. The agent therefore runs in the *container's* namespace. This is the whole point — it lets the agent supervise `com.ninjarmm.lockhartd.service` (backups). Don't reintroduce `--pid=host`.

2. **The agent install lives in a plain volume at `/opt/NinjaRMMAgent`.** No bind/nsenter for the agent itself. The `ninjarmm-agent` volume persists the install, identity, and self-updates across restarts.

3. **Host-only facts go through `docker/in-host`.** It `nsenter`s into the host namespaces via the bind-mounted host `/proc` (`/host/proc/1/ns/*`) — which works *without* `--pid=host`. `zpool`/`zfs` are symlinks to it (version-matched ZFS against the host kernel module). Don't install the zfs userland in the image — its ioctl ABI won't match the host.

4. **Runtime env vars don't reach systemd's child services.** `NINJA_AGENT_URL` set via compose `environment:` reaches PID 1 (systemd) but not the units it spawns. `ninjarmm-bootstrap.sh` reads it from `/proc/1/environ` as a fallback (quadlet uses `EnvironmentFile` instead). Preserve that bridge.

5. **Container name and hostname are both the host's hostname.** Quadlet uses `%H` for `ContainerName` and `HostName`; compose/Custom-App use `NINJA_HOSTNAME`. This is what makes the agent register as the box, not "ninjarmm-agent".

6. **systemd-in-container needs cgroup + tmpfs.** Podman `--systemd=always` handles it; the compose/Custom-App path mounts `/sys/fs/cgroup` and tmpfs `/run`+`/tmp` explicitly. Privileged is required (cgroup, SMART via `/dev`, namespace handoff).

7. **Reporting trade-offs are known and documented.** OS reports Fedora (the container), installed-packages is the container's RPM db, filesystem capacity comes from the `/mnt` bind-through. SMART and `in-host` commands are host-accurate. See [README.md § Reporting trade-offs](./README.md#reporting-trade-offs). Don't "fix" these by reintroducing the nsenter-the-agent design — it can't run backups.

## Where things live

| What | Where |
|---|---|
| Image build (systemd PID 1) | `docker/Containerfile` |
| First-boot agent install | `docker/ninjarmm-bootstrap.{service,sh}` |
| Host-namespace handoff | `docker/in-host` (`zpool`/`zfs` symlink to it) |
| Podman quadlet | `quadlet/ninjarmm-agent.container` (deployed to `/etc/containers/systemd/` by `install.sh`) |
| Docker compose / TrueNAS | `compose/docker-compose.yml` |
| Volume backing | named volume `ninjarmm-agent`, mounted at `/opt/NinjaRMMAgent` |
| Agent download URL (deploy-local) | quadlet: `/etc/ninjarmm-agent.env` (written by `install.sh`); compose: `.env` / app env |

## Branch model

Per DTC standard: `development` is default, `release` is the protected promotion branch. Branch prefixes communicate version impact (see [Semantic Versioning](https://kb.dtctoday.com/books/developer-operations-devops/page/semantic-versioning)):

- `enhancement/...`, `improvement/...`, `feature/...` → minor bump
- `problem/...`, `bug/...`, `refactor/...` → patch bump (refactor → minor if external behavior changes)

`VERSION` at repo root is bumped in the same commit/PR that makes the change. The version represents the *next release target*.

## Common tasks

```bash
# Build the image locally (requires ./agent.rpm)
./scripts/build.sh

# Deploy the public image with no local build — agent installs on first boot
sudo NINJA_AGENT_URL='https://<console>/...agent.rpm' \
     IMAGE=ghcr.io/dtc-inc/ninjaone-fedora-container:latest ./scripts/install.sh

# Tail logs (container name == host hostname)
sudo journalctl -u ninjarmm-agent.service -f               # quadlet service, host side
sudo podman exec -it "$(hostname)" journalctl -f           # systemd inside the container
sudo podman exec -it "$(hostname)" systemctl status com.ninjarmm.lockhartd.service

# Host introspection from inside
sudo podman exec -it "$(hostname)" zpool status

# Force a clean first boot (re-install agent from scratch)
sudo systemctl stop ninjarmm-agent.service
sudo podman volume rm ninjarmm-agent
sudo systemctl start ninjarmm-agent.service
```

## Working with this code

- Containerfile is grouped/readable under `dnf install`. Keep it tidy when adding packages. Don't add `zfs` (version mismatch — use the `in-host` handoff).
- Quadlet and compose must stay structurally aligned — same volumes, same env, same privileged/systemd setup. Change one, change the other.
- The Containerfile's `dnf -y install agent.rpm || true` tolerates a placeholder RPM, so the published image is intentionally agent-free. CI (`build-pr.yml`, `release.yml`) stages a zero-byte `agent.rpm` and the whole `docker/` dir as build context.
- **CI only builds the image — it cannot boot systemd or reach a host.** The boot path (systemd setup, bootstrap unit, `in-host`) must be validated on a real box; backups specifically must be validated on TrueNAS. State tested targets in the PR.
