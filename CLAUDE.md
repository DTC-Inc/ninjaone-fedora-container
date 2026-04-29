# CLAUDE.md

## Project

Containerized NinjaOne Linux agent for hosts where the vendor RPM can't install directly (rpm-ostree / immutable distributions). Agent runs in a Fedora container with the lifecycle benefits of containerization, but executes in the **host's mount namespace via `nsenter`** so disk, OS, and filesystem reporting in the NinjaOne dashboard reflect host reality.

Owner: Nate Smith (`nate.smith@dtctoday.com`). Reviewers: TBD.

## Repo links

- Production deployment guide → [README.md](./README.md)
- Contributor workflow → [DEVELOPMENT.md](./DEVELOPMENT.md)
- Cross-cutting DTC standards → [Developer Operations book](https://kb.dtctoday.com/books/developer-operations-devops)

## Stack

- Container runtime: Podman (rootful, system quadlet) or Docker Compose
- Base image: `registry.fedoraproject.org/fedora:41`
- Language: Bash for entrypoint and scripts; YAML for quadlet/compose/CI
- CI: GitHub Actions → GHCR (`ghcr.io/dtc-inc/ninjaone-fedora-container`)
- Vendor artifact: NinjaOne Linux agent RPM (token-stamped, per-deployment, never committed)

## Critical invariants

These are easy to break and hard to debug — call them out in any review:

1. **The agent must run in the host's mount namespace.** The `exec nsenter -t 1 -m -- ...` line in `docker/entrypoint.sh` is what makes filesystem reporting correct. Removing it (or accidentally putting the `exec` before the nsenter) silently regresses NinjaOne's disk reporting to the container's overlay storage.

2. **The host bind at `/opt/NinjaRMMAgent` must be set up *before* exec'ing the agent.** The agent in host-mount-namespace looks at `/opt/NinjaRMMAgent/programfiles/...` for its binaries and config. Without the bind, the agent crashes — the path doesn't exist on the host.

3. **`--pid=host` and `--init` are incompatible.** Podman won't add an init binary when sharing the host's PID namespace. Don't try to add `--init` to fix zombie reaping; rely on the host's PID 1 (systemd) to reap.

4. **The NinjaOne RPM places files under `/tmp/rpmbuild/...`.** This is why the vendor RPM doesn't install cleanly on rpm-ostree — that's the entire reason this repo exists. If the agent's package layout ever changes (vendor fixes their packaging), revisit whether this container is still necessary.

5. **`HostName=%H` in the quadlet resolves at unit instantiation.** Changing the host's hostname requires `systemctl daemon-reload` + `systemctl restart ninjarmm-agent.service` for the agent to pick up the new name.

## Where things live

| What | Where |
|---|---|
| Image build | `docker/Containerfile` |
| Container PID 1 | `docker/entrypoint.sh` |
| Podman quadlet | `quadlet/ninjarmm-agent.container` (deployed to `/etc/containers/systemd/` by `install.sh`) |
| Docker compose | `compose/docker-compose.yml` |
| Volume backing | Podman named volume `ninjarmm-state` (default storage at `/var/lib/containers/storage/volumes/ninjarmm-state/_data/`) |
| Agent install (in volume) | `/state/ninjarmm/app/` — bound to host's `/opt/NinjaRMMAgent` by entrypoint |
| Downstream-script storage (in volume) | `/state/{docdb,db,logs}/` |

## Branch model

Per DTC standard: `development` is default, `release` is the protected promotion branch. Branch prefixes communicate version impact (see [Semantic Versioning](https://kb.dtctoday.com/books/developer-operations-devops/page/semantic-versioning)):

- `enhancement/...` → minor bump
- `improvement/...` → minor bump
- `feature/...` → minor bump
- `problem/...` → patch bump
- `bug/...` → patch bump
- `refactor/...` → patch bump (or minor if external behavior changes)

`VERSION` at repo root is bumped in the same commit/PR that makes the change. The version represents the *next release target*.

## Common tasks

```bash
# Build the image locally (requires ./agent.rpm)
./scripts/build.sh

# Install/reinstall on this machine
sudo ./scripts/install.sh

# Tail logs
sudo journalctl -u ninjarmm-agent.service -f
sudo podman logs -f ninjarmm-agent

# Shell into container (Fedora userspace, container's view)
sudo podman exec -it ninjarmm-agent bash

# Inspect host-side bind that makes the agent see real paths
mount | grep NinjaRMM

# Force a fresh re-seed from image (e.g. after image upgrade)
sudo systemctl stop ninjarmm-agent
sudo podman volume rm ninjarmm-state
sudo systemctl start ninjarmm-agent
```

## Working with this code

- Containerfile is alphabetical under `dnf install`. Maintain order when adding packages.
- Entrypoint is bash; keep it readable. Tests are deferred until we have a real CI integration runner.
- Quadlet and compose file should stay structurally aligned — same volumes, same bind mounts, same env. If you add one, add the other.
- The Containerfile expects `agent.rpm` at the build context root. If you're CI-building without an RPM (the public no-RPM image), the build will fail at `dnf -y install /tmp/agent.rpm` — that's intentional. The CI variant for no-RPM builds is tracked in `enhancement/ci-no-rpm` (TBD).
