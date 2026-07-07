# Contributing to ninjaone-fedora-container

This is a DTC repo. Cross-cutting engineering standards (branching, PR process, semver, commit signing, image tagging) live in the [Developer Operations (DevOps) book](https://kb.dtctoday.com/books/developer-operations-devops) on the DTC KB and are referenced rather than duplicated here. This guide covers what's specific to *this* repo.

## TL;DR

1. Branch from `development` with a name like `enhancement/<short-desc>` or `problem/<short-desc>`.
2. Provide the agent one of two ways: drop your token-stamped RPM at the repo root as `./agent.rpm` (gitignored) to bake it in, **or** skip the RPM and set `NINJA_AGENT_URL` so the container downloads it at runtime.
3. Build locally: `./scripts/build.sh` (only needed for the baked-RPM path; the runtime-download path uses the prebuilt public image).
4. Test on a dev VM or your own machine: `sudo ./bazzite/install.sh` (set `NINJA_AGENT_URL=...` for the download path).
5. Bump `VERSION` per [Semantic Versioning](https://kb.dtctoday.com/books/developer-operations-devops/page/semantic-versioning).
6. Open a PR against `development`. CI builds + emits a per-PR pinnable image tag.
7. Merge after review. CI promotes via tag re-push (no rebuild on merge).

## Repo layout

```
ninjaone-fedora-container/
├── docker/
│   ├── Containerfile               # the image (systemd as PID 1)
│   ├── ninjarmm-bootstrap.service  # first-boot oneshot: install agent if absent
│   ├── ninjarmm-bootstrap.sh       # the bootstrap logic
│   └── in-host                     # run a host command via namespace handoff
│                                   # (zpool/zfs symlink to it)
├── bazzite/                        # Bazzite / podman deployment
│   ├── ninjarmm-agent.container    # Podman quadlet (deployed to /etc/containers/systemd/)
│   ├── install.sh                  # build + lay down quadlet + start service
│   ├── uninstall.sh                # tear down cleanly
│   └── README.md
├── truenas/                        # TrueNAS / Docker deployment
│   ├── docker-compose.yml
│   └── README.md
├── scripts/
│   └── build.sh                    # shared local image build (podman or docker)
├── .github/workflows/
│   ├── build-pr.yml           # CI gate: build + push per-PR image
│   ├── promote.yml            # on PR merge: retag (no rebuild)
│   └── release.yml            # on merge to release: tag, GitHub release
├── VERSION                    # SemVer; bumped per change in same commit/PR
├── README.md
├── DEVELOPMENT.md             # this file
├── CLAUDE.md                  # project context for AI work
└── LICENSE
```

## Why the architecture (systemd-init)

The container runs **systemd as PID 1**. That's the load-bearing decision: NinjaOne's agent installs and supervises its own services (`ninjarmm-agent`, the patcher timer, and the **Lockhart backup daemon** `com.ninjarmm.lockhartd.service`) the way it does on a normal host. Lockhart has no other supervisor, so a leaner "agent-as-PID-1" container can't run backups — which is why this design exists.

Consequences and how we handle them:

- **No `--pid=host`.** systemd must be PID 1, which rules out sharing the host PID namespace. So the agent runs in the *container's* namespace and a plain volume at `/opt/NinjaRMMAgent` is its persistent install (no bind/nsenter for the agent itself).
- **Host introspection on demand.** Anything that must reflect host reality runs the host's own binary via `docker/in-host`, which `nsenter`s into the host namespaces through the bind-mounted host `/proc` (`/host/proc/1/ns/*`) — no `--pid=host` needed. `zpool`/`zfs` symlink to it so ZFS is version-matched against the host kernel module.
- **Full host access at `/host`.** Host `/` is bind-mounted read-write at `/host` (established only while the container runs), so the file browser and Lockhart backups can reach and back up any host path. `/host/proc` stays read-only for the handoff.
- **SMART** reads `/dev` directly (privileged) — namespace-independent.
- **Reporting trade-offs** — installed-packages is the container's Fedora db; the OS and filesystem capacity now come from the host (the `/etc/os-release` bind and the `/host` bind-through). Documented in [README.md § Reporting trade-offs](./README.md#reporting-trade-offs).

See [README.md § Architecture](./README.md#architecture) for the full picture.

## Local development loop

You'll want a target machine to test against — your own laptop is fine if it's a non-production environment, or a VM (Fedora Workstation, Bazzite, Ubuntu — any Linux x86_64).

```bash
# After you make changes:
./scripts/build.sh
sudo systemctl stop ninjarmm-agent.service          # if installed
sudo podman volume rm ninjarmm-agent                # force a clean first boot
sudo ./bazzite/install.sh
sudo journalctl -u ninjarmm-agent.service -f        # quadlet service (host side)
sudo podman exec -it "$(hostname)" journalctl -f    # systemd INSIDE the container
sudo podman exec -it "$(hostname)" bash             # poke around inside
```

The container name equals the host's hostname (`%H`), hence `$(hostname)` above. Inside, inspect the agent's own services:

```bash
systemctl status ninjarmm-agent.service com.ninjarmm.lockhartd.service
systemctl list-units 'ninjarmm*' 'com.ninjarmm*'
journalctl -u ninjarmm-bootstrap.service            # first-boot install log
zpool status                                        # exercises the in-host handoff
```

## Adding admin tools to the image

The image ships with a curated tool set in `docker/Containerfile` — editors (nano, vim, tmux), networking (bind-utils, mtr, nmap-ncat, tcpdump), diagnostics (htop, lsof, strace, smartmontools), Python 3, etc. To add more:

1. Edit `docker/Containerfile`, append package(s) to the `dnf install` block (alphabetical).
2. Bump `VERSION` per [Semantic Versioning](https://kb.dtctoday.com/books/developer-operations-devops/page/semantic-versioning) — adding tooling is a **minor** bump.
3. PR with a description that names the new tool and why it's worth the image-size delta.

Heuristic: if a tool is something a sysadmin would `dnf install` interactively while debugging a production issue, it belongs in the image. If it's only useful to one specific script, ship it via the script's prereqs instead.

## Modifying the boot path

The fragile pieces are `docker/Containerfile` (systemd setup, unit masking), `docker/ninjarmm-bootstrap.{sh,service}` (first-boot agent install), and `docker/in-host` (host-namespace handoff). CI only *builds* the image — it can't boot systemd or talk to a real host — so changes here **must be validated on a real box**, and you should state which in the PR. Test matrix:

- A **TrueNAS SCALE** box (the canonical appliance target: read-only root, ix-apps Docker, ZFS) — confirm the agent registers, **a backup of a host path runs (Lockhart)** — e.g. `/host/mnt/<pool>/<dataset>` or `/host/etc` — and `in-host zpool status` works.
- A podman host via the quadlet (Bazzite/Fedora) — confirm `--systemd=always` boots and the agent comes up.

Watch for the classic systemd-in-container gotchas: cgroup mount, writable `/run`+`/tmp` tmpfs, and env vars set via the runtime reaching PID 1 but **not** the services it spawns (the bootstrap reads `NINJA_AGENT_URL` from `/proc/1/environ` for exactly this reason).

## Branching, commits, PRs

Per DTC standards. The short version:

- Branch from `development`. Naming: `enhancement/short-desc`, `problem/short-desc`, `feature/short-desc`, `bug/short-desc`, `improvement/short-desc`, `refactor/short-desc`. The prefix tells the version bump.
- Commits: descriptive subject lines. Sign per [Commit Signing](https://kb.dtctoday.com/books/developer-operations-devops/page/commit-signing).
- PR target: `development` for normal work; `release` for promotion (PR-only, protected).
- PR template inherited from the org-wide default. Description should explain *what changed*, *why*, *how to test*, and any *target environments tested*.

Direct pushes to `development` are allowed for scaffolding and emergency hotfixes per the [Branching Strategy](https://kb.dtctoday.com/books/developer-operations-devops/page/branching-strategy). Don't make it the default.

## CI

Three workflows in `.github/workflows/`:

| File | Trigger | What it does |
|---|---|---|
| `build-pr.yml` | `pull_request` against `development` or `release` | Multi-arch (`linux/amd64`) build, pushes `{version}-{branch-slug}-{sha}` and `{version}-{branch-slug}` to GHCR |
| `promote.yml` | `pull_request: closed` with `merged: true` | Retags via `docker buildx imagetools create` — `dev`+`{version}-dev` for dev merges, `latest`+`release`+`{version}` for release merges |
| `release.yml` | Push of a `v*` tag | Manual release path; builds + creates a GitHub Release with auto-generated changelog |

**Note**: published images don't include a token-stamped RPM. CI stages a zero-byte `agent.rpm` placeholder and the Containerfile's `dnf -y install ... || true` tolerates it, so the published image is agent-free by design.

Agent-free images get their agent at runtime: set `NINJA_AGENT_URL` and `ninjarmm-bootstrap.service` downloads + installs it on first boot (only if the `ninjarmm-agent` volume doesn't already have it). Baking remains supported for local dev — drop a real `./agent.rpm` and `scripts/build.sh` layers it in. Downstream consumers can still layer an RPM via a one-step `FROM` build instead of using the URL.

## Versioning specifics

`VERSION` at the repo root is the source of truth. The build scripts and CI both read it. Per [Semantic Versioning](https://kb.dtctoday.com/books/developer-operations-devops/page/semantic-versioning):

- **Major** — breaking changes to the volume layout (`/opt/NinjaRMMAgent`), the init model, or the install/uninstall script interface
- **Minor** — adding admin tools, new optional environment variables, new helper scripts
- **Patch** — bug fixes, base image bumps that don't change behavior, doc-only fixes (no bump needed for doc-only)

The agent RPM version itself is independent — it ships in the user's per-deployment build, and NinjaOne's own patcher updates it in the volume. Bumping our `VERSION` doesn't track agent RPM changes.

## Issues and proposals

- File issues for bugs against any version
- For larger changes (architecture, new platforms, multi-distro support beyond Fedora base), open a discussion or RFC in an issue first before sinking work into a PR

## Related KB pages

- [Branching Strategy](https://kb.dtctoday.com/books/developer-operations-devops/page/branching-strategy)
- [Pull Request & Code Review Process](https://kb.dtctoday.com/books/developer-operations-devops/page/pull-request-code-review-process)
- [Semantic Versioning](https://kb.dtctoday.com/books/developer-operations-devops/page/semantic-versioning)
- [Commit Signing](https://kb.dtctoday.com/books/developer-operations-devops/page/commit-signing)
- [Docker Image Build Workflows](https://kb.dtctoday.com/books/developer-operations-devops/page/docker-image-build-workflows)
- [Working with Third-Party Repositories](https://kb.dtctoday.com/books/developer-operations-devops/page/working-with-third-party-repositories) — relevant since we consume NinjaOne's RPM as a third-party artifact
