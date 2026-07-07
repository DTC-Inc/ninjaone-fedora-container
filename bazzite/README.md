# Bazzite (and other podman / rpm-ostree hosts)

Deploys the NinjaOne agent as a **rootful podman quadlet**: systemd manages it, it
auto-starts on boot, and NinjaOne reports the box as its **real OS** (Bazzite),
not the container's Fedora. Same image as the [truenas](../truenas/) variant —
only the runtime (podman vs Docker) differs.

## Files
| File | Purpose |
|---|---|
| `ninjarmm-agent.container` | the quadlet unit (installed to `/etc/containers/systemd/`) |
| `install.sh` | build/pull the image, write the token env file, lay down the quadlet, start it |
| `uninstall.sh` | tear it down |

## Install

```bash
sudo NINJA_AGENT_URL='https://<console>/...agent.rpm' \
     IMAGE=ghcr.io/dtc-inc/ninjaone-fedora-container:latest \
     ./install.sh
```

Or build locally (no registry needed) — omit `IMAGE` and `install.sh` builds
`localhost/ninjaone-fedora-container:latest` from [`../docker/`](../docker/).

First boot downloads + installs the agent into the `ninjarmm-agent` volume, then
it checks in as the host's hostname. Requires podman ≥ 4.4 and a **privileged**
container (for systemd's cgroup, SMART via `/dev`, and the host-namespace handoff).

## Verify

```bash
sudo systemctl status ninjarmm-agent.service
sudo podman exec -it "$(hostname)" systemctl status \
     ninjarmm-agent.service com.ninjarmm.lockhartd.service
```

## Uninstall

```bash
sudo ./uninstall.sh                  # keep the agent volume
sudo PURGE_STATE=1 ./uninstall.sh    # also remove the ninjarmm-agent volume
```
