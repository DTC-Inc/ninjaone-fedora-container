# TrueNAS SCALE (and other Docker hosts)

Deploys the NinjaOne agent as a **Docker Compose Custom App**. Same image as the
[bazzite](../bazzite/) variant; Docker boots the container's systemd via the
explicit cgroup + tmpfs mounts (the equivalent of podman's `--systemd=always`).
NinjaOne reports the box as its **real OS** (TrueNAS SCALE), not Fedora.

## Deploy as a Custom App

Apps → **Custom App** → *Install via YAML*, paste `docker-compose.yml`, and set:

- **`NINJA_HOSTNAME`** → *optional* — the agent auto-detects the host's hostname at boot; set this only if you also want the docker container named after the box
- **`NINJA_AGENT_URL`** → your NinjaOne Linux agent `.rpm` link (console → Add Devices → Linux → Fedora/RHEL)
- **privileged** enabled; network mode **Host**

## Or over SSH

```bash
export NINJA_HOSTNAME="$(hostname)"
export NINJA_AGENT_URL='https://<console>/...agent.rpm'
docker compose up -d
```

First boot downloads + installs the agent into the `ninjarmm-agent` volume (a
couple of minutes), then it checks in. **Backups (Lockhart)** run once you assign
a backup plan to the device in NinjaOne — target host paths under `/host/...` or
pools under `/host/mnt/<pool>/<dataset>`.

> **Status:** the image + compose are validated on podman/Bazzite; the
> Docker-on-TrueNAS systemd boot is the last leg under active validation. If the
> container doesn't stay up, grab `docker logs <name>` and check the cgroup/tmpfs
> mounts.
