# Changelog

## 2.0.0 (2026-11-20)

A rewrite. Everything now lives in one tool, `xdc-rpc`, with menus.

- **One command to install**, which also checks the download against its published checksum. No separate user-creation step, and no `screen`: long steps run in the background and keep going if you disconnect.
- **Safe to run again.** Each setup step checks how things really are and only does what's missing. If a step fails, setup says which one and why; **Finish setup** continues from there.
- **Firewall allowlist.** Port 443 is open only to your allowlisted addresses, and nginx checks them again. Port 80 stays closed except while a certificate renews. Connections that don't use your domain name get nothing back.
- **One allowlist** for RPC and WSS, with checked input. Addresses can be limited to RPC or WSS only.
- **Plugin RPCaaS** gateway allowed with one answer, and kept up to date by this tool's updates.
- **P2P port of your choice.** This also fixes the P2P port on Apothem, which the previous version left unreachable.
- **SSH:** a non-root admin user created during setup; optional SSH port change and root login off, each tested with a real login from a second window and undone automatically if that doesn't happen; an optional guided switch to SSH keys; stronger fail2ban settings.
- **APIs** chosen from a list: `eth`, `net` and `web3` by default; `XDPoS` and `debug` optional.
- **Node:** runs from a checked copy of XinFin's release, so nothing in XinFin's folder changes the running node. RPC and WebSocket listen only on the server itself; P2P is published on IPv4 only, so over IPv6 only SSH is reachable. Stopping the node sends the stop signal to XDC itself (the node image doesn't pass Docker's stop signal on, so stops used to end in a forced kill) and gives it up to 30 minutes to save its state; the menu says so if the node ever keeps crashing and restarting.
- **Node updates are never automatic.** Each XinFin release is checked against everything xdc-rpc relies on before anything is installed; the new software downloads while the node keeps running; if the new release isn't working within 10 minutes, the previous one is put back. You can also switch back to the previous release yourself.
- **Snapshots** are optional, never overwrite existing chain data, resume after an interrupted download, and are checked against a published checksum when one is available. If the node ever gets stuck, the Node menu replaces the chain data with a fresh snapshot or syncs again from block 0, keeping the node's account and identity. Setup explains the risks before a mainnet node syncs from block 0.
- **Encrypted backups** after setup, after changes and daily when anything changed (newest 10 kept), with download instructions and a restore that rebuilds the node on a new server.
- **Updates** for this tool (daily check, login notice, optional automatic updates, automatic rollback if an update doesn't apply), and for Ubuntu packages.
- **Takes over installations** made with the previous version, keeping the node, chain data, domain, certificate and allowlist.
- Cloudflare proxying is no longer part of the setup.
