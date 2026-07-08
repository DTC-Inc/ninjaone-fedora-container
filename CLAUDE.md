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

2. **The agent's state lives in the `/opt/NinjaRMMAgent` volume; its systemd units do NOT — they're re-laid every boot.** The volume persists the agent files, identity, and self-updates. But the RPM installs systemd units (`ninjarmm-agent.service`, the patcher, and — at runtime — `com.ninjarmm.lockhartd.service`) into the container's **ephemeral** rootfs (`/usr/lib/systemd/system`), which quadlet recreates on every start (`--rm`). So `ninjarmm-bootstrap` **caches the RPM in the volume** (`/opt/NinjaRMMAgent/.bootstrap/agent.rpm`) and **re-installs it on every boot where the agent unit is absent**, re-laying the units without re-downloading; the agent then re-reads its identity from the volume (same device) and re-creates lockhart itself. Don't assume the volume alone makes the agent persist — the boot-time re-lay is load-bearing.

3. **Host-only facts go through `docker/in-host`.** It `nsenter`s into the host's **mount/uts/ipc/net** namespaces via the bind-mounted host `/proc` (`/host/proc/1/ns/*`) — deliberately **not** the pid namespace: the container runs its own systemd (its own pid ns) and the host's is an *ancestor*, which `setns()` cannot join (`--pid` → EINVAL, `reassociate to namespace 'ns/pid' failed`). It also injects **`SYSTEMCTL_FORCE_BUS=1`** so host `systemctl` talks over the D-Bus message bus — systemctl-as-root otherwise prefers systemd's private socket (`/run/systemd/private`), whose handshake needs the host pid-ns alignment we lack. Don't re-add `--pid`, and keep `SYSTEMCTL_FORCE_BUS=1`. `zpool`/`zfs`/`nmcli` are symlinks to it (version-matched ZFS against the host kernel module; `nmcli` drives the host's NetworkManager). The container ships the `NetworkManager` package but **masks its daemon** — a second NM under host networking would fight the host's over the shared interfaces and could drop the host off the network. Don't install the zfs userland in the image — its ioctl ABI won't match the host. **Mount split:** host `/` is bind-mounted **read-write** at `/host` (full host access — this is what makes the file browser + Lockhart backups see the whole host), but `/host/proc` is pinned **read-only** for the handoff. Keep that split — don't make `/host` read-only again or `/host/proc` writable.

4. **Runtime env vars don't reach systemd's child services.** `NINJA_AGENT_URL` set via compose `environment:` reaches PID 1 (systemd) but not the units it spawns. `ninjarmm-bootstrap.sh` reads it from `/proc/1/environ` as a fallback (quadlet uses `EnvironmentFile` instead). Preserve that bridge.

5. **The agent auto-reports the box's real hostname.** A baked oneshot (`ninjarmm-hostname.service`, built inline in the Containerfile) mirrors the host's hostname (`/host/etc/hostname`, kernel fallback) into the container's own UTS namespace at boot, before the agent — so **no `NINJA_HOSTNAME`/`%H` is required, on any host**. The container's UTS ns is separate from the host's, so this can't rename the host. (The quadlet still passes `%H` and the compose still accepts `NINJA_HOSTNAME`; those just seed the container name / an initial value — the service is authoritative.) Don't remove the hostname service.

6. **systemd-in-container needs cgroup + tmpfs.** Podman `--systemd=always` handles it; the compose/Custom-App path mounts `/sys/fs/cgroup` and tmpfs `/run`+`/tmp` explicitly. Privileged is required (cgroup, SMART via `/dev`, namespace handoff).

7. **Reporting is mostly host-accurate; only installed-packages stays container-flavored.** OS now reports the **host** (the deploy binds host `/etc/os-release` over the container's; dnf's `releasever` is pinned in the Containerfile so that doesn't break the agent install). Kernel, CPU/RAM, SMART, hostname, and — with host networking — NICs are the host's; filesystem capacity comes from the host `/` bind-through at `/host` (back up pools as `/host/mnt/<pool>/...`). **Installed-packages remains the container's RPM db (Fedora)** — the only way to fix that is to nsenter the agent into the host, which can't run backups *and* is impossible on TrueNAS (read-only `/opt`). Don't reintroduce the nsenter-the-agent design. See [README.md § Reporting trade-offs](./README.md#reporting-trade-offs).

8. **`ninjarmm-bootstrap` must NOT be ordered `Before=ninjarmm-agent.service`, and it must use podman `--env-file` with a file that always exists.** Two deadlock/startup traps, both learned the hard way:
   - The vendor RPM's `%post` starts the agent with a **blocking** `systemctl start`. If bootstrap is ordered before the agent, `%post` deadlocks (it waits on the agent's start job, which systemd holds until bootstrap finishes). No `Before=`.
   - Quadlet's `EnvironmentFile=` maps to podman `--env-file`, which does **not** honor systemd's `-` optional prefix and **requires the file to exist**. `install.sh` always creates `/etc/ninjarmm-agent.env` (empty if no URL). No leading `-`.
   - Bootstrap's `ConditionPathExists=!/usr/lib/systemd/system/ninjarmm-agent.service` (the unit, not the binary) is what makes it re-run on each fresh container and skip once wired.

9. **Lockhart (backups) needs `OPENSSL_CONF=/dev/null`.** The LTDR backup daemon's bundled OpenSSL (`nssl`) can't parse Fedora's system `openssl.cnf` (crypto-policies directives like `rh-allow-sha1-signatures`) and dies on startup → it never binds `:50052` → the agent loops "Failed to configure backup agent … Connection refused" and **backups never run**. A drop-in baked into the image (`/etc/systemd/system/com.ninjarmm.lockhartd.service.d/10-openssl-conf.conf`) sets it. Don't remove it — this is the whole reason backups work in the Fedora container.

## Where things live

| What | Where |
|---|---|
| Image build (systemd PID 1) | `docker/Containerfile` |
| First-boot agent install | `docker/ninjarmm-bootstrap.{service,sh}` |
| Host-namespace handoff | `docker/in-host` (`zpool`/`zfs` symlink to it) |
| Full host access (RW) | host `/` → `/host:rw,rslave` in `bazzite/` + `truenas/` (keep the two aligned) |
| Host-OS reporting | host `/etc/os-release` bound over the container's (`bazzite/` + `truenas/`); dnf `releasever` pinned in `docker/Containerfile` so the install still works |
| Bazzite deploy (podman quadlet) | `bazzite/ninjarmm-agent.container` (deployed to `/etc/containers/systemd/` by `bazzite/install.sh`) |
| TrueNAS deploy (docker compose) | `truenas/docker-compose.yml` |
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
     IMAGE=ghcr.io/dtc-inc/ninjaone-fedora-container:latest ./bazzite/install.sh

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
