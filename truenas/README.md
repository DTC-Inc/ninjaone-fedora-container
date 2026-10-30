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

## If the container starts and immediately stops

systemd (PID 1) failed to boot — the first few lines of `docker logs <name>` name
the reason. The one we hit on TrueNAS SCALE 25.10: a
`- /sys/fs/cgroup:/sys/fs/cgroup:rw` line in the compose file. That's the cgroup
**v1** recipe. TrueNAS is cgroup v2, where Docker defaults to a *private* cgroup
namespace and `privileged` already mounts the container's own cgroup read-write —
binding the host's tree over that makes systemd try to manage the host root
cgroup, fail to create `init.scope`, and abort with *Failed to allocate manager
object*. Don't add it back. Confirm the host's cgroup version with
`stat -fc %T /sys/fs/cgroup` (`cgroup2fs` = v2).

> **Status:** the image + compose are validated on podman/Bazzite; the
> Docker-on-TrueNAS systemd boot is under active validation.
