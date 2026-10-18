# Docker_Private_Source · One-click Docker install for China networks

[![sync-docker-ce](https://github.com/MinimaxFlora/Docker_Private_Source/actions/workflows/sync.yml/badge.svg)](https://github.com/MinimaxFlora/Docker_Private_Source/actions/workflows/sync.yml)

[中文](./README.md)

A one-click Docker Engine installer tuned for networks in mainland China: GitHub
Actions mirrors the official [docker-ce](https://download.docker.com) apt/yum
repositories daily, re-signs them with **this project's own GPG key**, hosts the
result on GitHub Releases, and a single script downloads it through
**ghproxy-style accelerators** and installs it from a local `file:` / `file://`
source.

No DNS tricks, no dependency on third-party mirror availability, no reliance on
get.docker.com reachability.

## Quick start

```bash
# Debian / Ubuntu (amd64 / arm64), latest stable
sh -c "$(curl -fsSL https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh)"

# Rocky 9/10, CentOS 7/9/10, RHEL 9/10, AlmaLinux 9/10, Fedora 43/44 (x86_64 / aarch64)
# the same script auto-detects the distro — no extra flags needed
```

If GitHub is unreachable, fetch the script from jsDelivr CDN instead:

```bash
sh -c "$(curl -fsSL https://testingcf.jsdelivr.net/gh/MinimaxFlora/Docker_Private_Source@master/install.sh)"
```

The script will:

1. Download the repo bundle (`docker-ce-repo-<codename>.tar` /
   `docker-ce-repo-rpm-<id>.tar`) via accelerated channels and verify its SHA256
2. Set up a local `file:` apt source (Debian/Ubuntu, `/opt/docker-ce-cn`) or a
   local `file://` yum/dnf source (Rocky/CentOS/RHEL/Alma/Fedora,
   `repo_gpgcheck=1`) with this project's public key
3. Install the full docker-ce family: `docker-ce`, `docker-ce-cli`,
   `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`,
   `docker-ce-rootless-extras`, `docker-model-plugin` (missing packages are
   skipped automatically per distro)
4. Enable and start the docker service, add the current user to the `docker` group
5. Configure `registry-mirrors` in `/etc/docker/daemon.json` (image pull acceleration)

## Options

| Option | Description |
| --- | --- |
| `--version <VERSION>` | Install a specific package version, e.g. `--version 29.7` |
| `--tag <TAG>` | Select a versioned Release (e.g. `v29.7.2`); defaults to the newest versioned Release |
| `--mirror <URL>` | Custom GitHub accelerator prefix (overrides default; auto-detects network: China prefers `gh-proxy.kejizero.xyz`, overseas uses direct) |
| `--registry-mirror <URL>` | Append one more registry mirror (repeatable) |
| `--no-registry-mirror` | Skip registry mirror configuration |
| `--no-autostart` | Do not auto-start the docker service |
| `--dry-run` | Print steps only |
| `--help` | Help |

Environment variables work as equivalents: `VERSION`, `TAG`, `DOWNLOAD_MIRROR`,
`CHINA_MIRROR` (default accelerator for China networks, defaults to
`https://gh-proxy.kejizero.xyz`), `REGISTRY_MIRRORS` (comma-separated),
`NO_AUTOSTART`, `NO_REGISTRY_MIRROR`, `PROJECT`.

## Versioned Releases

Every successful sync publishes a versioned Release tagged `v<docker-ce version>`
(for example `v29.7.2`):

- The installer defaults to the newest versioned Release through GitHub's
  `releases/latest/download` redirect (no API calls, no rate limits).
- Pin or roll back with `sudo bash install.sh --tag v29.7.2`.
- Only the three most recent versions are kept; older Releases are pruned.
- The old rolling `latest` Release is no longer used; GitHub resolves `latest`
  to the newest versioned Release.

> Network auto-detection: the script probes overseas reachability (google/baidu)
> and, when on a China network, automatically prefers the
> `gh-proxy.kejizero.xyz` accelerator with other mirrors as fallback; overseas
> networks download directly from GitHub. Override with `--mirror` or the
> `CHINA_MIRROR` environment variable.

## Supported distros

| Distro | Version | Repo | Architectures |
| --- | --- | --- | --- |
| Debian 13 | trixie | deb | amd64, arm64 |
| Debian 12 | bookworm | deb | amd64, arm64 |
| Debian 11 | bullseye | deb | amd64, arm64 |
| Ubuntu 24.04 | noble | deb | amd64, arm64 |
| Ubuntu 22.04 | jammy | deb | amd64, arm64 |
| Ubuntu 20.04 | focal | deb | amd64, arm64 |
| Rocky 10 / CentOS 10 / RHEL 10 / Alma 10 | 10 | el10 | x86_64, aarch64 |
| Rocky 9 / CentOS 9 / RHEL 9 / Alma 9 | 9 | el9 | x86_64, aarch64 |
| CentOS 7 (legacy) | 7 | el7 | x86_64, aarch64 |
| Fedora 44 / 43 | 44 / 43 | fedora-44 / fedora-43 | x86_64, aarch64 |

> Note: Docker does not publish docker-ce under the official rocky/rhel repo
> directories (rocky hosts plugin packages only). The el repos are synced from
> the official centos directory (`-1.el9` / `-1.el10` / `-1.el7` are generic el
> packages) — Rocky / CentOS / RHEL / AlmaLinux users can install them directly.
> Fedora ships a new release every 6 months; update the sync matrix
> (`.github/workflows/sync.yml` and the version whitelist in `install.sh`) when
> a new Fedora lands.

## How it works

```
┌────────────────────── GitHub Actions (daily + manual trigger) ────────────────────────┐
│  download.docker.com ──► fetch docker-ce family .deb/.rpm (last 3 versions)           │
│       │                    deb: 6 codenames × amd64/arm64                             │
│       │                    rpm: el7/el9/el10 + fedora-44/43 × x86_64/aarch64          │
│       ▼                                                                              │
│  deb: apt-ftparchive regenerates Packages index + Release                            │
│  rpm: createrepo_c regenerates repodata (repomd.xml)                                 │
│       │                    ▲                                                        │
│       ▼                    └── signed by this project's GPG private key              │
│  package docker-ce-repo-<codename>.tar / docker-ce-repo-rpm-<id>.tar + SHA256         │
│       │                                                                              │
│       ▼                                                                              │
│  GitHub Release (versioned tag: v<docker version>, last 6 kept) ── ghproxy ────────── │
└──────────────────────────────────────────────────────────────────────────────────────┘
        │
        ▼  target machine (mainland China)
   install.sh ──► accelerated download + SHA256 check ──► local file:/file:// source
        └──► apt-get / dnf install docker-ce ... ──► start service / docker group / registry
```

Security model: the packages are byte-identical to the official docker-ce
repository (never repackaged). apt verifies the repository through the GPG
signature on `Release/InRelease`; dnf/yum through `repomd.xml.asc`; the script
adds a SHA256 check on top.

## Self-hosting (fork)

1. **Fork this repo** (default branch `master`; edit `PROJECT="your/repo"` at
   the top of `install.sh`)
2. **Generate the signing key** once on your machine:

   ```bash
   ./generate-key.sh        # produces public-key.asc (commit it) and gpg-private.key (keep secret)
   ```

3. **Configure GitHub Secrets** (repo → Settings → Secrets and variables → Actions):

   | Secret | Value |
   | --- | --- |
   | `GPG_PRIVATE_KEY` | full content of `gpg-private.key` |
   | `GPG_PASSPHRASE` | the key passphrase |

4. **Commit `public-key.asc`** and manually trigger the workflow once
   (Actions → sync-docker-ce → Run workflow) to produce the first bundle
5. It then re-syncs daily at 02:23 UTC; trigger manually after new Docker releases

## FAQ

- **apt reports `InRelease` / dnf reports `repomd.xml` signature failure**: the
  signing key and public key don't match. Make sure `GPG_PRIVATE_KEY` /
  `GPG_PASSPHRASE` and the committed `public-key.asc` come from the same key
  generation.
- **Slow / failing download**: pass `--mirror https://your-accelerator`; the
  default list lives in `DEFAULT_MIRRORS` in the script.
- **Older version**: choose a versioned Release with `--tag v29.7.2`, then pin the
  package with `--version 29.7` (rpm) / `--version 27.3` (deb).
- **dnf dependency resolution fails**: dnf resolves dependencies (e.g. for
  containerd) from the machine's own base/AppStream repos, so those must be
  configured and reachable.
- **Registry mirrors dying**: registry accelerators are volatile; append with
  `--registry-mirror` or edit `/etc/docker/daemon.json` and
  `systemctl restart docker`.

## License

[MIT](./LICENSE)
