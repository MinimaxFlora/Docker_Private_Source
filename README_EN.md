# docker-install-cn · One-click Docker install for China networks

[![sync-docker-ce](https://github.com/MinimaxFlora/docker-install-cn/actions/workflows/sync.yml/badge.svg)](https://github.com/MinimaxFlora/docker-install-cn/actions/workflows/sync.yml)

[中文](./README.md)

A one-click Docker Engine installer tuned for networks in mainland China: GitHub
Actions periodically mirrors the official
[docker-ce](https://download.docker.com) apt repository, re-signs it with
**this project's own GPG key**, hosts it on GitHub Releases, and a single script
downloads it through **ghproxy-style accelerators** and installs it from a local
`file:` apt source.

No DNS tricks, no dependency on third-party mirror availability, no reliance on
get.docker.com reachability.

## Quick start

```bash
# Debian / Ubuntu (amd64 / arm64), latest stable
sh -c "$(curl -fsSL https://github.com/MinimaxFlora/docker-install-cn/raw/refs/heads/master/install.sh)"
```

If GitHub is unreachable, fetch the script from jsDelivr CDN instead:

```bash
sh -c "$(curl -fsSL https://testingcf.jsdelivr.net/gh/MinimaxFlora/docker-install-cn@master/install.sh)"
```

The script will:

1. Download the repo bundle (`docker-ce-repo-<codename>.tar`) via accelerated
   channels and verify its SHA256
2. Set up a local `file:` apt source (`/opt/docker-ce-cn`) with this project's
   public key
3. Install the full docker-ce family: `docker-ce`, `docker-ce-cli`,
   `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`,
   `docker-ce-rootless-extras`, `docker-model-plugin`
4. Enable and start the docker service, add the current user to the `docker` group
5. Configure `registry-mirrors` in `/etc/docker/daemon.json` (image pull acceleration)

## Options

| Option | Description |
| --- | --- |
| `--version <VERSION>` | Install a specific version, e.g. `--version 27.3` |
| `--mirror <URL>` | Custom GitHub accelerator prefix (auto-probes by default) |
| `--registry-mirror <URL>` | Append one more registry mirror (repeatable) |
| `--no-registry-mirror` | Skip registry mirror configuration |
| `--no-autostart` | Do not auto-start the docker service |
| `--dry-run` | Print steps only |
| `--help` | Help |

Environment variables work as equivalents: `VERSION`, `DOWNLOAD_MIRROR`,
`REGISTRY_MIRRORS` (comma-separated), `NO_AUTOSTART`, `NO_REGISTRY_MIRROR`,
`PROJECT`, `TAG`.

## Supported distros

| Distro | Codename | Architectures |
| --- | --- | --- |
| Debian 13 | trixie | amd64, arm64 |
| Debian 12 | bookworm | amd64, arm64 |
| Debian 11 | bullseye | amd64, arm64 |
| Ubuntu 24.04 | noble | amd64, arm64 |
| Ubuntu 22.04 | jammy | amd64, arm64 |
| Ubuntu 20.04 | focal | amd64, arm64 |

## How it works

```
┌────────────────────── GitHub Actions (weekly + manual trigger) ──────────────────────┐
│  download.docker.com ──► fetch docker-ce family .deb (last 3 versions per package)   │
│       │                    amd64 / arm64 × 6 codenames                                │
│       ▼                                                                              │
│  apt-ftparchive regenerates Packages index + Release                                  │
│       │                    ▲                                                         │
│       ▼                    └── signed by this project's GPG private key              │
│  package docker-ce-repo-<codename>.tar + SHA256 (one asset per codename)              │
│       │                                                                              │
│       ▼                                                                              │
│  GitHub Release (fixed tag: latest, overwritten each run) ── ghproxy proxies only    │
└──────────────────────────────────────────────────────────────────────────────────────┘
        │
        ▼  target machine (mainland China)
   install.sh ──► accelerated download + SHA256 check ──► local file: apt source
        └──► apt-get install docker-ce ... ──► start service / docker group / registry
```

Security model: the .deb packages are byte-identical to the official docker-ce
repository (never repackaged). apt verifies the repository through the GPG
signature on `Release/InRelease` (this project's key), and the script adds a
SHA256 check on top.

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
5. It then re-syncs every Monday; trigger manually after new Docker releases

## FAQ

- **apt reports `InRelease` verification failure**: the signing key and public
  key don't match. Make sure `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE` and the
  committed `public-key.asc` come from the same key generation.
- **Slow / failing download**: pass `--mirror https://your-accelerator`; the
  default list lives in `DEFAULT_MIRRORS` in the script.
- **Older version**: the repo keeps the last 3 versions per package —
  `--version 24.0` works.
- **Registry mirrors dying**: registry accelerators are volatile; append with
  `--registry-mirror` or edit `/etc/docker/daemon.json` and
  `systemctl restart docker`.

## License

[MIT](./LICENSE)
