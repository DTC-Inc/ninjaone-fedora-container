# Contributing to ninjaone-fedora-container

This is a DTC repo. Cross-cutting engineering standards (branching, PR process, semver, commit signing, image tagging) live in the [Developer Operations (DevOps) book](https://kb.dtctoday.com/books/developer-operations-devops) on the DTC KB and are referenced rather than duplicated here. This guide covers what's specific to *this* repo.

## TL;DR

1. Branch from `development` with a name like `enhancement/<short-desc>` or `problem/<short-desc>`.
2. Provide the agent one of two ways: drop your token-stamped RPM at the repo root as `./agent.rpm` (gitignored) to bake it in, **or** skip the RPM and set `NINJA_AGENT_URL` so the container downloads it at runtime.
3. Build locally: `./scripts/build.sh` (only needed for the baked-RPM path; the runtime-download path uses the prebuilt public image).
4. Test on a dev VM or your own machine: `sudo ./scripts/install.sh` (set `NINJA_AGENT_URL=...` for the download path).
5. Bump `VERSION` per [Semantic Versioning](https://kb.dtctoday.com/books/developer-operations-devops/page/semantic-versioning).
6. Open a PR against `development`. CI builds + emits a per-PR pinnable image tag.
7. Merge after review. CI promotes via tag re-push (no rebuild on merge).

## Repo layout

```
ninjaone-fedora-container/
├── docker/
│   ├── Containerfile          # the image
│   └── entrypoint.sh          # PID 1 inside container — sets up volume,
│                              # binds host paths, execs agent via nsenter
├── quadlet/
│   └── ninjarmm-agent.container   # Podman quadlet (deployed to /etc/containers/systemd/)
├── compose/
│   └── docker-compose.yml         # Docker alternative
├── scripts/
│   ├── build.sh               # local image build (podman or docker)
│   ├── install.sh             # build + lay down quadlet + start service
│   └── uninstall.sh           # tear down cleanly
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

## Why the unusual architecture

Standard "monitoring agent in a container" approach is to install the agent in the container, share `--pid=host --network=host`, mount `/host` as a window. That doesn't fully solve the *filesystem reporting* problem: the agent reads `/proc/self/mountinfo` and `statvfs()` from inside its mount namespace, so it sees container overlay storage instead of the host's real disks.

This repo uses a **mount-namespace handoff** approach: the agent process itself runs in the host's mount namespace via `nsenter -t 1 -m`. The container's mount namespace is only used during the entrypoint phase to set up the volume binds; once `nsenter` happens, the agent operates as if natively installed on the host. Disk/mount/OS reporting becomes correct without giving up the container's lifecycle benefits (image versioning, clean uninstall, isolated tool chain).

See [README.md § Architecture](./README.md#architecture) for the full picture.

## Local development loop

You'll want a target machine to test against — your own laptop is fine if it's a non-production environment, or a VM (Fedora Workstation, Bazzite, Ubuntu — any Linux x86_64).

```bash
# After you make changes:
./scripts/build.sh
sudo systemctl stop ninjarmm-agent.service          # if installed
sudo podman volume rm ninjarmm-state                # force re-seed if entrypoint changed
sudo ./scripts/install.sh
sudo journalctl -u ninjarmm-agent.service -f        # watch the agent come up
sudo podman exec -it ninjarmm-agent bash            # poke around inside
```

To debug the entrypoint specifically (without it exec'ing the agent):

```bash
sudo podman run --rm -it \
    --name ninjarmm-debug \
    --pid=host --ipc=host --privileged \
    --network host \
    -v ninjarmm-state:/state \
    -v /sys:/sys:ro -v /dev:/dev \
    -v /:/host:ro,rslave \
    -v /etc:/host/etc:rw,rslave \
    -v /var:/host/var:rw,rslave \
    -v /home:/host/home:rw,rslave \
    --entrypoint=/bin/bash \
    localhost/ninjaone-fedora-container:latest
```

Inside that shell, manually walk the entrypoint logic step by step.

## Adding admin tools to the image

The image ships with a curated tool set in `docker/Containerfile` — editors (nano, vim, tmux), networking (bind-utils, mtr, nmap-ncat, tcpdump), diagnostics (htop, lsof, strace, smartmontools), Python 3, etc. To add more:

1. Edit `docker/Containerfile`, append package(s) to the `dnf install` block (alphabetical).
2. Bump `VERSION` per [Semantic Versioning](https://kb.dtctoday.com/books/developer-operations-devops/page/semantic-versioning) — adding tooling is a **minor** bump.
3. PR with a description that names the new tool and why it's worth the image-size delta.

Heuristic: if a tool is something a sysadmin would `dnf install` interactively while debugging a production issue, it belongs in the image. If it's only useful to one specific script, ship it via the script's prereqs instead.

## Modifying the entrypoint

`docker/entrypoint.sh` is the most fragile piece. Changes that touch:

- The `nsenter` invocation
- The volume layout (`/state/...`)
- The host bind mounts (`/opt/NinjaRMMAgent`)

…need to be tested on at least:

- An rpm-ostree host (Bazzite is fine — that's the canonical target)
- A traditional Fedora install (where `/opt` is real, not a symlink to `/var/opt`)
- A Ubuntu host (different `/etc/os-release`, different SSH key conventions)

Until we have CI integration tests covering all three, **explicitly state which targets you tested in your PR description**.

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

Agent-free images get their agent at runtime: set `NINJA_AGENT_URL` and the entrypoint downloads + installs it on first run (only if the `ninjarmm-state` volume doesn't already have it). Baking remains supported for local dev — drop a real `./agent.rpm` and `scripts/build.sh` layers it in. Downstream consumers can still layer an RPM via a one-step `FROM` build instead of using the URL.

## Versioning specifics

`VERSION` at the repo root is the source of truth. The build scripts and CI both read it. Per [Semantic Versioning](https://kb.dtctoday.com/books/developer-operations-devops/page/semantic-versioning):

- **Major** — breaking changes to the volume layout, the `/state` contract, or the install/uninstall script interface
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
