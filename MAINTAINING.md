# Maintaining XDC Secure RPC & WSS

Notes for whoever publishes new versions. Users don't need any of this.

## How users get updates

- The install command always downloads the newest **GitHub Release** (`releases/latest/download/xdc-rpc.sh`), never the `main` branch. Pushing to `main` changes nothing for users until you publish a release.
- Every installed node checks for a new release once a day and shows a notice at login. Nodes with automatic updates turned on install it themselves; everyone else updates from the menu or with `sudo xdc-rpc update`.
- Each update is checked against the `xdc-rpc.sh.sha256` file in the release. After installing, the new version re-applies its managed settings (for example Plugin's gateway list). If that fails, the node goes back to the version it had.

## Changing Plugin's RPCaaS gateway address

1. In `xdc-rpc.sh`, edit the list near the top:

   ```bash
   PLUGIN_RPCAAS_IPS=(
     "194.163.189.137"
   )
   ```

   One quoted IPv4 address (or range) per line.
2. Bump `XDC_RPC_VERSION` a patch level, for example `2.0.0` → `2.0.1`.
3. Add a short entry at the top of `CHANGELOG.md`, such as `## 2.0.1 (date)` and `- Plugin's RPCaaS gateway address updated.`
4. Commit and push to `main`, then publish the release (below).

Nodes that allow Plugin's gateway switch to the new list as soon as they update: their firewall and nginx allowlist are rewritten automatically. Nodes that don't allow Plugin aren't affected. Operators without automatic updates see the notice when they next log in, so it's worth also telling Plugin operators to update.

## When XinFin changes their node files

xdc-rpc never runs the node straight from XinFin's folder. Every XinFin release is checked first, then copied into `/var/lib/xdc-rpc/node` and run from there. A release is only used if all of these still hold (see `node_upstream_check` in `xdc-rpc.sh`):

- The network folder (`mainnet` or `testnet`) has a `docker-compose.yml` with exactly one service and an image.
- That compose file mounts `/work/xdcchain`, `/work/genesis.json`, `/work/start.sh`, `/work/bootnodes.list` and `/work/.pwd`. The files it mounts there must exist; their names can change.
- The start script passes `bash -n`, sets `--port` on a line of its own, uses `--datadir /work/xdcchain`, `/work/genesis.json`, `/work/bootnodes.list` and `/work/.pwd`, binds `--http-addr` and `--ws-addr` to `0.0.0.0` inside the container, and reads `ENABLE_RPC`, `ENABLE_WS`, `RPC_PORT`, `WS_PORT`, `API`, `GC_MODE` and `INSTANCE_NAME` or `NODE_NAME`.
- `env.example` has all of those settings, plus `CONTACT_DETAILS`.
- `genesis.json` is for chain id 50 (mainnet) or 51 (testnet), and the bootnodes file lists at least one `enode://`.

If a new XinFin release breaks any of these, nodes don't install it. Their daily check notices in advance, and the login message and **Updates** say the release needs a newer xdc-rpc, with the reason. Nothing changes on those nodes until you publish a version that understands the new layout.

To handle a change:

1. Look at what XinFin changed in [XinFin-Node](https://github.com/XinFinOrg/XinFin-Node).
2. Update the parts of `xdc-rpc.sh` that deal with XinFin's files: `node_upstream_check` (what's checked), `node_write_start_script` (the P2P port edit), `_compose_text` (how the node is run) and `node_env_apply` (the settings xdc-rpc manages).
3. Test on a throwaway Apothem server: a fresh install, and an update of a node that runs the previous XinFin release.
4. Publish a release. Operators update xdc-rpc first, then the node.

Node updates also check the node itself: the new software is downloaded before anything stops, and if the node isn't answering within 10 minutes of restarting (or comes back from an empty database), the previous release is put back automatically.

## Publishing a release

1. Make sure `XDC_RPC_VERSION` in `xdc-rpc.sh` is a version that hasn't been released yet (`MAJOR.MINOR.PATCH`), and `CHANGELOG.md` has a section for it.
2. On GitHub: **Actions → Release → Run workflow**.

The workflow refuses to run if that version already exists. It checks the script (`bash -n` and ShellCheck), makes the checksum file, creates the release `vX.Y.Z` as a draft, attaches `xdc-rpc.sh` and `xdc-rpc.sh.sha256`, then publishes it as the latest release. The release notes come from that version's section of `CHANGELOG.md`.

Use a new patch number for fixes, a new minor number for new features, and a new major number only for changes that need operators to do something themselves.

## Before releasing a bigger change

- Run `bash -n xdc-rpc.sh` and `shellcheck -s bash -S warning xdc-rpc.sh`.
- Try it on a throwaway Apothem (testnet) server: a fresh install, then `sudo xdc-rpc setup` again (it should change nothing), then an update from the previous release.
- If you change anything that's written to disk (nginx, firewall rules, SSH drop-ins, the node's compose file), make sure running setup again on an existing server still works, because that's what every update does.

## One-time GitHub settings

- **Repository name:** `XDC-Secure-RPC-WSS`. GitHub redirects the old name (`Plugin-XDC-Secure-RPC-WSS`) for web pages, `git clone` and release downloads. Never create a new repository with the old name: that would break the redirect.
- **Pages:** Settings → Pages → Deploy from a branch → `main`, folder `/ (root)`. Because the user site uses the custom domain `xdcoutpost.xyz`, this repository appears at `https://xdcoutpost.xyz/XDC-Secure-RPC-WSS/`. `.nojekyll` makes Pages serve the files as they are.
- **Immutable releases:** Settings → General → **Releases** → tick **Enable release immutability**. Do this before publishing 2.0.0: it only applies to releases published afterwards. Once a release is published, its tag and files can't be changed or replaced, so nobody can swap a release for a different file later. The workflow attaches the files while the release is still a draft, which is what immutable releases need.
- **Actions:** the Release workflow needs permission to create releases. It asks for `contents: write` itself; if your organisation or account restricts workflow permissions, allow it under Settings → Actions → General.

## Where things live on a node

| Path | What |
|---|---|
| `/usr/local/sbin/xdc-rpc` | The installed script (the previous version is kept in `/usr/local/lib/xdc-rpc/`) |
| `/etc/xdc-rpc/` | Settings, allowlist and the backup password |
| `/var/lib/xdc-rpc/` | State, background tasks and their logs, pending SSH undo snapshots, and the node's releases (below) |
| `/var/log/xdc-rpc/` | Logs of the daily checks (`daily.log`) and of what was done from the menus (`menu.log`) |
| `~ADMIN/XinFin-Node/` | XinFin's repository (or wherever the previous installer put it). The node's settings file is `NETWORK/.env`; the chain data is in `NETWORK/xdcchain` (or `xdcchain-testnet`) |
| `/var/lib/xdc-rpc/node/` | The release the node runs: XinFin's checked files in `upstream/`, plus the generated `start.sh`, `compose.yml`, `node.env` and the keystore password file `pwd` |
| `/var/lib/xdc-rpc/node.prev/` | The previous release, for switching back |
| `~ADMIN/XDC-Backups/` | Encrypted backups |
| `~ADMIN/XDC-RPC-Files/` | Shortcuts to everything in this table, with a README, for people looking for files. Made as the admin user and refreshed by the daily checks; xdc-rpc never reads through it |
| `/etc/nginx/sites-available/xdc-node`, `/etc/nginx/snippets/xdc-rpc-*` | nginx site and allowlists |
| `/etc/ssh/sshd_config.d/00-xdc-rpc-*.conf` | SSH port and login settings |
| `/etc/fail2ban/jail.d/xdc-rpc-sshd.local` | fail2ban jail |
| `/etc/letsencrypt/renewal-hooks/*/xdc-rpc-*` | Open and close port 80 around renewals; reload nginx |
| `xdc-rpc-daily.timer`, `/etc/update-motd.d/90-xdc-rpc` | Daily checks and the login message |

Firewall rules the tool manages have comments starting `xdc-rpc:`. The temporary port 80 rule during a renewal is commented `xdc-rpc-acme: temporary`.
