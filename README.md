# NinjaOne Fedora Container

A containerized NinjaOne Linux agent for hosts where installing the vendor RPM directly isn't viable — immutable distributions (Bazzite, Bluefin, Silverblue, Kinoite), bootc-based systems, or anywhere else the agent's RPM packaging conflicts with the host filesystem layout.

The agent runs **inside a Fedora container** with a managed lifecycle but **operates in the host's mount, PID, network, and IPC namespaces** via `nsenter`. NinjaOne sees the host's real disks, mounts, processes, hardware, and OS — not the container's overlay storage.

| Aspect | Behavior |
|---|---|
| Process visibility (NinjaOne "Top Processes") | Host processes |
| Filesystem usage / SMART / disk model | Host disks (real block devices) |
| OS reported | Host's `/etc/os-release` (e.g. Bazzite, Fedora, Ubuntu — whatever the host actually is) |
| Hostname | Host's hostname (`%H` from systemd) |
| Network connections | Host's interfaces and listening sockets |
| Service control via NinjaOne (e.g. `systemctl restart sshd`) | Host's services (via `/run/systemd` propagation) |
| Self-update (NinjaOne agent patcher) | Persisted in the `ninjarmm-state` named volume |

## When to use this

- **Yes:** Bazzite/Bluefin/Silverblue/Kinoite/CoreOS hosts, bootc images, any host where rpm-ostree refuses the NinjaOne RPM (the agent's RPM places files under `/tmp/rpmbuild/...` which rpm-ostree disallows).
- **Yes:** Hosts where you want a clean uninstall path (drop the quadlet + remove the volume = gone).
- **No:** Standard mutable Fedora/RHEL/Ubuntu hosts where the vendor's `dnf install` or `apt install` works without modification — use those installers directly.

## Requirements

- Linux x86_64 host (kernel ≥ 5.6 for full mount-propagation support)
- Either Podman ≥ 4.4 (for quadlet support) or Docker ≥ 24
- Ability to run a privileged container (`--privileged --pid=host`)
- Your NinjaOne Linux agent RPM, as **either**:
  - a public download URL (`NINJA_AGENT_URL`) — the container fetches + installs it on first run; pair it with the prebuilt public image, no local build needed, **or**
  - a token-stamped `agent.rpm` baked in at build time (the original flow)

## Quick start (public image + URL — no build, recommended)

Use the prebuilt no-agent base image and let the container install the agent on first run. Get the download link from the NinjaOne console (Add Devices → Linux → pick distro/arch → copy the link).

Podman + quadlet:
```bash
git clone git@github.com:DTC-Inc/ninjaone-fedora-container.git ~/github/dtc-inc/ninjaone-fedora-container
cd ~/github/dtc-inc/ninjaone-fedora-container

sudo NINJA_AGENT_URL='https://<your-console>/...agent.rpm' \
     IMAGE=ghcr.io/dtc-inc/ninjaone-fedora-container:latest \
     ./scripts/install.sh
```

Docker Compose:
```bash
cd compose
echo "NINJA_AGENT_URL=https://<your-console>/...agent.rpm" > .env
docker compose up -d
```

The agent downloads + installs only on first run; once it's in the `ninjarmm-state` volume, restarts and upgrades skip the download. The URL carries a NinjaOne org token — `install.sh` stores it at `/etc/ninjarmm-agent.env` (0600), and the compose `.env` is gitignored. Don't commit it.

## Quick start (Podman + quadlet, baked RPM)

```bash
# 1. Clone
git clone git@github.com:DTC-Inc/ninjaone-fedora-container.git ~/github/dtc-inc/ninjaone-fedora-container
cd ~/github/dtc-inc/ninjaone-fedora-container

# 2. Drop your token-stamped RPM at the repo root
#    (NinjaOne console → Add Devices → Linux → pick distro/arch → save as agent.rpm)
cp ~/Downloads/NinjaOne-Agent-*.rpm ./agent.rpm

# 3. Build + install as a system service
sudo ./scripts/install.sh
```

That installs:
- A Podman quadlet at `/etc/containers/systemd/ninjarmm-agent.container`
- A systemd service `ninjarmm-agent.service` (auto-generated from the quadlet)
- A named volume `ninjarmm-state` for persistent agent state and downstream-script storage

Verify:
```bash
sudo systemctl status ninjarmm-agent.service
sudo podman logs -f ninjarmm-agent
```

The device should appear in your NinjaOne dashboard within a minute.

## Quick start (Docker Compose — alternative)

For Docker hosts (no quadlet/systemd integration; the container is supervised by Docker itself):

```bash
git clone git@github.com:DTC-Inc/ninjaone-fedora-container.git
cd ninjaone-fedora-container
cp ~/Downloads/NinjaOne-Agent-*.rpm ./agent.rpm

BUILDER=docker ./scripts/build.sh

cd compose
docker compose up -d
```

Note: Docker Compose can't replicate `Podman --privileged --pid=host` quite as cleanly as the quadlet does (it needs `cap_add: SYS_ADMIN` for `nsenter` from a non-`--privileged` container). The compose file uses `privileged: true` for parity. If you have a hardened Docker setup that disallows privileged containers, the quadlet path is your only option.

## Architecture

```
┌─────────────────────────── HOST ───────────────────────────┐
│                                                            │
│   /opt/NinjaRMMAgent  ◄─── bind ───┐                       │
│   (mounted by entrypoint via       │                       │
│    nsenter into host's mount ns)   │                       │
│                                    │                       │
│   /var/lib/containers/storage/     │                       │
│   volumes/ninjarmm-state/_data/    │                       │
│   └── ninjarmm/app/  ──────────────┘                       │
│       ├── programfiles/  (binaries; self-update target)    │
│       └── programdata/   (runtime, internal logs)          │
│   └── docdb/    (downstream scripts — JSON store)          │
│   └── db/       (downstream scripts — RDBMS)               │
│   └── logs/     (downstream scripts — log files)           │
│                                                            │
│   ┌──────────────── ninjarmm-agent ─────────────────────┐  │
│   │  Container — Fedora userspace + admin tooling       │  │
│   │                                                     │  │
│   │  PID 1: entrypoint.sh                               │  │
│   │  └─► exec nsenter -t 1 -m -- ninjarmm-linagent      │  │
│   │      └─► AGENT runs in HOST mount namespace,        │  │
│   │           reads host /etc/os-release, sees real     │  │
│   │           /proc/mounts, SMART, etc.                 │  │
│   │  └─► background loop: nsenter -- patcher every 5min │  │
│   │                                                     │  │
│   │  Namespace shares: --pid=host --ipc=host            │  │
│   │  Network: host                                      │  │
│   │  Mounts: /state, /sys, /dev, /host{,/etc,/var,/home}│  │
│   └─────────────────────────────────────────────────────┘  │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

The key idea: the **container's mount namespace** holds the agent's install (`/opt/NinjaRMMAgent` bound from the volume), but the **agent process itself runs in the host's mount namespace** via `nsenter -t 1 -m`. So:

- The agent reads host's `/proc/self/mountinfo` → reports host filesystems correctly
- The agent reads host's `/etc/os-release` → reports the real host OS (Bazzite/Fedora/Ubuntu/whatever)
- The agent's binary path resolves through the host bind we set up at `/opt/NinjaRMMAgent`
- The agent's writes (self-update, runtime data) land in the named volume via that bind

## State layout

The `ninjarmm-state` named volume contains:

| Path | Purpose |
|---|---|
| `/state/ninjarmm/app/` | Agent install (bound to `/opt/NinjaRMMAgent` on host) |
| `/state/docdb/` | JSON / document store for downstream scripts |
| `/state/db/` | RDBMS data for downstream scripts |
| `/state/logs/` | Log files for downstream scripts |

Inside the container, the entrypoint creates this layout on first run and populates `ninjarmm/app/` — seeding from the image's baked-in agent files if present, otherwise downloading + installing the RPM from `NINJA_AGENT_URL`. A populated volume short-circuits both: restarts never re-download.

## Host filesystem access from the container

When you `podman exec -it ninjarmm-agent bash`, you're in the **container's** mount namespace, which has:

| Container path | Host path | Mode |
|---|---|---|
| `/host` | `/` | read-only baseline |
| `/host/etc` | `/etc` | read-write |
| `/host/var` | `/var` | read-write |
| `/host/home` | `/home` | read-write |
| `/sys`, `/dev` | `/sys`, `/dev` | shared (privileged) |
| `/state` | named volume | read-write |

Convention for downstream scripts: read host config from `/host/...`, write host changes to `/host/etc`, `/host/var`, or `/host/home`. Scratch space: `/state/{docdb,db,logs}` for persistence; `/tmp` for ephemeral.

## NinjaOne agent self-update

The agent's built-in patcher is invoked every `PATCHER_INTERVAL` seconds (default 300) by a background loop in the entrypoint. Patcher runs `nsenter`'d into host's mount namespace; updates write to `/opt/NinjaRMMAgent` which is bound to the volume's `ninjarmm/app/` directory — so updates persist across container restarts.

When **we** publish a new image (new RPM baseline, new tooling, base image bump), the named volume already has whatever the agent self-patched to. To force the new image's baseline to take effect:

```bash
sudo systemctl stop ninjarmm-agent.service
sudo podman volume rm ninjarmm-state
sudo systemctl start ninjarmm-agent.service
```

The first run after deletion re-seeds from the new image. Then NinjaOne's patcher takes over again.

## Uninstall

```bash
sudo ./scripts/uninstall.sh                  # leaves named volume in place
sudo PURGE_STATE=1 ./scripts/uninstall.sh    # also removes the volume
sudo PURGE_IMAGE=1 ./scripts/uninstall.sh    # also removes the image
```

## Image distribution

Built images are published to `ghcr.io/dtc-inc/ninjaone-fedora-container` via GitHub Actions on PR merge. Tags follow [DTC's image tagging conventions](https://kb.dtctoday.com/books/developer-operations-devops/page/docker-image-build-workflows):

| Tag | Meaning |
|---|---|
| `{version}` (e.g. `0.7.0`) | Pinned semver release — production safe |
| `release` / `latest` | Rolling pointer to most recent release |
| `dev` | Rolling pointer to most recent development build |
| `{version}-dev` | Rolling within a dev version cycle |
| `{version}-dev-{sha}` | Immutable per-commit dev build |

**Important**: the published images do **not** contain a token-stamped RPM. Token-stamped RPMs are tied to a specific NinjaOne organization/division and must not be public. Deploy the public no-agent base in one of two ways:

- **Runtime download (recommended):** run the public image and set `NINJA_AGENT_URL` to your console's agent download link. The entrypoint installs it on first run. Nothing to build; the org token lives only in your deploy-local `/etc/ninjarmm-agent.env` (quadlet) or compose `.env`.
- **Bake at build time:** drop your own `agent.rpm` at the repo root and rebuild via `scripts/build.sh`, or layer it onto the public base in a one-step downstream `FROM` build and push to a private registry.

For DTC internal use we also maintain per-org build images in `ghcr.io/dtc-inc/ninjaone-fedora-container-<org>` (private).

## Limitations

- **Linux x86_64 only** today. ARM64 is on the roadmap (the only blocker is whether NinjaOne ships an ARM64 RPM — they don't yet for some package types).
- **Container's package list and service-status reporting are container-flavored.** NinjaOne's "Installed Packages" view reflects the Fedora container's RPM database, not the host's. Service-status calls for host-managed services work via `/run/systemd` propagation, but services *inside the container* don't appear on the host's systemd. Hardware, disk, network, processes, OS — all correctly host-flavored.
- **The container needs a podman/docker installation on the host.** rpm-ostree-based hosts that don't already include podman would need `rpm-ostree install podman` first (which does work — podman packages cleanly).

## Related

- [DEVELOPMENT.md](./DEVELOPMENT.md) — contributor guide
- [DTC DevOps standards](https://kb.dtctoday.com/books/developer-operations-devops) (internal)
- [NinjaOne Linux agent docs](https://www.ninjaone.com/) (vendor)

## License

MIT — see [LICENSE](./LICENSE).
