# NinjaOne Fedora Container

A containerized NinjaOne Linux agent for hosts where installing the vendor RPM directly isn't viable — immutable distributions (Bazzite, Bluefin, Silverblue, Kinoite), bootc-based systems, storage appliances (TrueNAS SCALE), or anywhere else the agent's RPM packaging conflicts with the host filesystem layout.

The container runs its own **systemd as PID 1**, so the NinjaOne agent installs and supervises its own services exactly as it does on a normal Linux host — including the **Lockhart backup daemon** (`com.ninjarmm.lockhartd.service`), which has no other supervisor and is why a plain "agent-as-PID-1" container isn't enough. Host-level facts the agent can't see from inside its own namespace (ZFS pools, any host command) are reached by running the **host's own tools** via a namespace handoff.

| Aspect | Behavior |
|---|---|
| RMM presence, scripting, patching | Full — agent + patcher run as native systemd services |
| **Backups (Lockhart / LTDR)** | **Work** — `lockhartd` runs under the container's systemd; can target **any host path** under `/host` |
| SMART / physical disk health | Host drives — `smartctl` reads `/dev` directly (privileged) |
| ZFS pools (`zpool`, `zfs`) | Host pools, version-matched — wrappers run the host's own binaries |
| Filesystem capacity | Whole host is mounted **read-write** at `/host`; the agent reports mounted volumes and can browse/back up any host path (incl. `/host/mnt/...`) |
| Hostname / container name | Both set to the host's real hostname (`%H`) |
| OS reported | The **host OS** (Bazzite, TrueNAS SCALE) — the deploy binds the host's `/etc/os-release` in |
| Agent state / self-update | Persisted in the `ninjarmm-agent` named volume at `/opt/NinjaRMMAgent` |

## When to use this

- **Yes:** TrueNAS SCALE and other appliances; Bazzite/Bluefin/Silverblue/Kinoite/CoreOS; bootc images; any host where `rpm-ostree`/read-only root refuses the NinjaOne RPM.
- **Yes:** when you want **backups** to work (the systemd-init design exists specifically to run Lockhart).
- **Yes:** when you want a clean uninstall (drop the quadlet/app + remove the volume = gone).
- **No:** standard mutable Fedora/RHEL/Ubuntu hosts where the vendor's `dnf install` / `apt install` works — use those directly.

## Requirements

- Linux x86_64 host
- Podman ≥ 4.4 (quadlet) or Docker ≥ 24 (TrueNAS Custom App counts)
- Ability to run a **privileged** container (needed for systemd's cgroup, SMART via `/dev`, and the host-namespace handoff)
- Your NinjaOne Linux agent RPM, as **either**:
  - a public download URL (`NINJA_AGENT_URL`) — installed on first boot; pair with the prebuilt public image, no local build, **or**
  - a token-stamped `agent.rpm` baked in at build time

## Quick start (public image + URL — no build, recommended)

Get the download link from the NinjaOne console (Add Devices → Linux → pick distro/arch → copy the link).

**Podman + quadlet:**
```bash
git clone git@github.com:DTC-Inc/ninjaone-fedora-container.git ~/github/dtc-inc/ninjaone-fedora-container
cd ~/github/dtc-inc/ninjaone-fedora-container

sudo NINJA_AGENT_URL='https://<your-console>/...agent.rpm' \
     IMAGE=ghcr.io/dtc-inc/ninjaone-fedora-container:latest \
     ./bazzite/install.sh
```

**Docker Compose:**
```bash
cd compose
cat > .env <<EOF
NINJA_AGENT_URL=https://<your-console>/...agent.rpm
NINJA_HOSTNAME=$(hostname)
EOF
docker compose up -d
```

**TrueNAS SCALE (Custom App):** point it at `truenas/docker-compose.yml`, set the app's **hostname** to the box name, and set `NINJA_AGENT_URL` in the environment. Privileged must be enabled. See [truenas/README.md](./truenas/README.md).

The agent installs only on first boot; once it's in the `ninjarmm-agent` volume, restarts and upgrades skip the download. The URL carries a NinjaOne org token — `install.sh` stores it at `/etc/ninjarmm-agent.env` (0600); the compose `.env` is gitignored. Don't commit it.

## Architecture

```
┌───────────────────────────── HOST (e.g. TrueNAS SCALE) ─────────────────────────────┐
│                                                                                      │
│   ZFS pools under /mnt ──────────────┐  physical drives in /dev ──────┐              │
│                                      │                                │              │
│   ┌──────────────── container (named = host's hostname) ────────────┐ │              │
│   │  PID 1: systemd                                                  │ │              │
│   │   ├─ ninjarmm-bootstrap.service  (first boot: install agent RPM) │ │              │
│   │   ├─ ninjarmm-agent.service      (the agent)                     │ │              │
│   │   ├─ ninjarmm-patcher.timer      (self-update)                   │ │              │
│   │   └─ com.ninjarmm.lockhartd.service  (BACKUPS)                   │ │              │
│   │                                                                  │ │              │
│   │  /opt/NinjaRMMAgent  ◄── ninjarmm-agent volume (install + state) │ │              │
│   │  /dev  ◄────────────────── SMART reads drives directly ──────────┼─┘              │
│   │  /mnt  ◄────────────────── host datasets (df reporting + backup) │                │
│   │  /host (+ /host/proc) ◄─── host / read-write                     │                │
│   │     └─ in-host / zpool / zfs  ─► nsenter into /host/proc/1/ns/*   │                │
│   │        run the HOST's own tools (version-matched ZFS) ───────────┼──► host pools  │
│   └──────────────────────────────────────────────────────────────────┘              │
│                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

Key points:

- **systemd is PID 1.** The agent's RPM installs `ninjarmm-agent.service`, the patcher timer, and (on policy) the Lockhart backup daemon. The container's own systemd supervises them — so backups run. The container is **not** `--pid=host` (systemd must be PID 1).
- **The agent runs in the container's namespace.** The `/opt/NinjaRMMAgent` volume persists its files, identity, and self-updates. Its systemd units, though, live in the container's ephemeral rootfs — so `ninjarmm-bootstrap` caches the RPM in the volume and re-lays the units on every boot the agent unit is missing (no re-download); the agent re-attaches as the same device and re-creates the Lockhart unit itself.
- **The host filesystem is mounted read-write at `/host`.** Full host access, established only while the container runs — nothing is persisted on the host and it's gone on uninstall. This is what lets the NinjaOne file browser and Lockhart backups reach and back up **any** host path (`/host/<path>`, e.g. `/host/mnt/<pool>` on TrueNAS). `/host/proc` stays read-only for the handoff below.
- **Host introspection is on demand.** `in-host <cmd>` enters the host's namespaces via the bind-mounted host `/proc` (`/host/proc/1/ns/*`) and runs the host's own binary. `zpool` and `zfs` are symlinks to it, so NinjaOne scripts and the remote terminal get real, version-matched ZFS against the host pools without installing a (mismatched) zfs userland in the container.
- **SMART** works because `smartctl` reads the block devices in `/dev` directly — that's device-level, namespace-independent.

## Reporting trade-offs

Running the agent in the container (required for backups) changes a few reported facts versus a bare-metal install. Know these going in:

| Fact | Result | Notes |
|---|---|---|
| Disk health (SMART) | **Accurate** | `/dev` + privileged |
| ZFS pool health | **Via scripts** | `zpool status` etc. through the `zpool`/`zfs` wrappers; NinjaOne has no native ZFS |
| Filesystem capacity | Host filesystem visible at `/host` is reported | pool-level detail still best from TrueNAS's own alerting |
| Installed packages | The **container's** RPM db, not the host's | inherent to containerizing the agent |
| OS / distro | Reports the **host OS** (Bazzite, TrueNAS SCALE) | the deploy binds the host's `/etc/os-release` over the container's; dnf `releasever` is pinned so the install is unaffected |
| Hostname | The host's real hostname | set via `%H` / `NINJA_HOSTNAME` |

## Host filesystem access from the container

`podman exec -it <hostname> bash` (or the NinjaOne remote terminal) drops you in the container, which has:

| Container path | Host path | Mode |
|---|---|---|
| `/opt/NinjaRMMAgent` | `ninjarmm-agent` volume | read-write (agent install + state) |
| `/host` | `/` | **read-write — the entire host, incl. for the file browser + backups** |
| `/host/proc` | `/proc` | read-only (namespace handoff source) |
| `/dev` | `/dev` | shared (privileged) |

Host `/` is bind-mounted read-write at `/host`, established only while the container runs — nothing is written to the host to set it up and it's gone on uninstall. So `/host/etc`, `/host/var`, `/host/home`, etc. are all reachable and writable (on an ostree/atomic host `/host/usr` stays read-only because it is read-only on the host itself). Run any host command with `in-host <cmd>` (e.g. `in-host zpool status`, `in-host systemctl restart sshd`); `zpool`/`zfs` work bare.

### Backing up host data

Because the whole host is visible at `/host`, NinjaOne's file/folder backup (Lockhart) and the file browser can target **any host path** — configure a backup of `/host/etc`, `/host/home/<user>`, `/host/srv`, or on TrueNAS `/host/mnt/<pool>/<dataset>`. Recommended exclusions so a broad job doesn't crawl pseudo-filesystems or the container's own storage:

- `/host/proc`, `/host/sys`, `/host/dev`, `/host/run` — kernel / pseudo filesystems
- `/host/var/lib/containers` — the container store (includes this container and the `ninjarmm-agent` volume)
- any network / loop mounts you don't intend to capture

## Uninstall

```bash
sudo ./bazzite/uninstall.sh                  # leaves the agent volume in place
sudo PURGE_STATE=1 ./bazzite/uninstall.sh    # also removes the ninjarmm-agent volume
sudo PURGE_IMAGE=1 ./bazzite/uninstall.sh    # also removes the image
```

## Image distribution

Built images are published to `ghcr.io/dtc-inc/ninjaone-fedora-container` via GitHub Actions on PR merge. Tags follow [DTC's image tagging conventions](https://kb.dtctoday.com/books/developer-operations-devops/page/docker-image-build-workflows):

| Tag | Meaning |
|---|---|
| `{version}` (e.g. `0.3.0`) | Pinned semver release — production safe |
| `release` / `latest` | Rolling pointer to most recent release |
| `dev` | Rolling pointer to most recent development build |
| `{version}-dev` | Rolling within a dev version cycle |
| `{version}-dev-{sha}` | Immutable per-commit dev build |

**Important**: published images do **not** contain a token-stamped RPM (token RPMs are org-specific and must not be public). Deploy the public no-agent base by setting `NINJA_AGENT_URL` (runtime download, recommended) or by baking your own `agent.rpm` via `scripts/build.sh`.

## Limitations

- **Linux x86_64 only** today.
- **Installed-packages and OS reporting are container-flavored** (see [Reporting trade-offs](#reporting-trade-offs)). Hardware, SMART, and host commands via `in-host` are host-accurate.
- **The host needs podman or docker** (TrueNAS SCALE ships docker; rpm-ostree hosts can `rpm-ostree install podman`).
- **Privileged required** — for systemd's cgroup, SMART, and the host-namespace handoff. Hardened hosts that forbid privileged containers can't run this.

## Related

- [DEVELOPMENT.md](./DEVELOPMENT.md) — contributor guide
- [DTC DevOps standards](https://kb.dtctoday.com/books/developer-operations-devops) (internal)

## License

MIT — see [LICENSE](./LICENSE).
