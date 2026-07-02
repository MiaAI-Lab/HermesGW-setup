# Mia's Hermes Gateway Desktop Setup Wizard

A smart, automated wizard that configures everything needed to connect the **Hermes Desktop app** to a **remote Hermes backend server**.

No YAML editing. No manual systemd setup. One command does it all.

<p>
<a href="https://x.com/MiaAI_lab" target="_blank">
  <img src="https://img.shields.io/badge/Follow%20me%20on%20X-000000?style=for-the-badge&logo=x&logoColor=white" alt="Follow Mia on X" />
</a>
</p>
<p>
<a href='https://ko-fi.com/Z8Z3SPLOD' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi6.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>
</p>

## Quick Start

### 🚀 One-liner install (recommended)

Run this on your remote Linux machine:

```bash
curl -fsSL https://raw.githubusercontent.com/MiaAI-Lab/HermesGW-Desktop-setup/main/setup-gateway.sh | bash
```

That's it. It generates credentials, starts the server, and sets up a systemd service — all with sensible defaults.

> **⚠️ Requires Hermes v0.18.0+.** If you get `'hermes serve' not available`, run `hermes update` first.

### Or download and run locally

```bash
bash setup-gateway.sh
```

### With custom credentials

```bash
bash setup-gateway.sh myuser MySecurePass123 9119
```

### Force reconfigure

```bash
curl -fsSL https://raw.githubusercontent.com/MiaAI-Lab/HermesGW-Desktop-setup/main/setup-gateway.sh | bash -s -- --clean
```

## What It Does

1. **Detects your network** — finds your LAN and Tailscale IPs automatically
2. **Checks prerequisites** — Hermes CLI, `hermes serve` subcommand, systemd, openssl
3. **Creates credentials** — username, password, and a stable auth secret that survives restarts
4. **Configures the backend** — starts `hermes serve` on your chosen port
5. **Sets up systemd** — creates a service with `Restart=always` so it bounces back if it crashes
6. **Enables linger** — so the server starts on boot even without you logging in
7. **Prints final instructions** — exact URL, credentials, and Desktop app steps

## Usage

### Non-interactive (defaults)

```bash
bash setup-gateway.sh
```

Uses sensible defaults: `admin` username, auto-generated password, port `9119`.

### With custom credentials

```bash
bash setup-gateway.sh myuser MySecurePass123 9119
```

Arguments: `[username] [password] [port]`

### Force reconfigure (overwrite existing)

```bash
bash setup-gateway.sh --clean
# or with custom values
bash setup-gateway.sh --clean myuser MySecurePass123 9119
```

The `--clean` flag skips the "already configured" check and overwrites existing credentials.

### Interactive mode

```bash
INTERACTIVE=1 bash setup-gateway.sh
```

Prompts for every choice with a 10-second timeout. If you don't respond, uses the default.

## After Setup

### Connect the Desktop App

1. Open **Settings → Gateway**
2. Under **Remote gateway**, enter: `http://<your-lan-ip>:9119`
3. Click **Sign in**
4. Enter the username and password
5. Click **Save and reconnect**

### Management Commands

```bash
# Check status
systemctl --user status hermes-serve.service

# Start/stop/restart
systemctl --user start hermes-serve.service
systemctl --user stop hermes-serve.service
systemctl --user restart hermes-serve.service

# View logs
journalctl --user -u hermes-serve.service -f
```

## Security Notes

- **LAN-only**: Username/password auth is for trusted networks (LAN/Tailscale only)
- **Internet exposure**: Use OAuth (Nous Portal) instead of basic auth for public access
- **Password**: Generated automatically if not provided. At least 8 characters recommended
- **Secret**: A stable auth secret is generated and stored in `~/.hermes/.env` so sessions survive restarts
- **File permissions**: The `.env` file is set to `600` (owner-only read/write)

## Files Created

| File                                          | Purpose                                       |
| --------------------------------------------- | --------------------------------------------- |
| `~/.hermes/.env`                              | Auth credentials (username, password, secret) |
| `~/.config/systemd/user/hermes-serve.service` | Systemd service unit                          |

## Troubleshooting

| Issue                          | Fix                                                                                       |
| ------------------------------ | ----------------------------------------------------------------------------------------- |
| `hermes` not found             | Install Hermes CLI: `curl -fsSL https://hermes-agent.nousresearch.com/install.sh \| bash` |
| `'hermes serve' not available` | Upgrade: `hermes update` (v0.18.0+ required)                                              |
| Port already in use            | Use a different port: `bash setup-gateway.sh admin pass 9120`                             |
| Service won't start            | Check logs: `journalctl --user -u hermes-serve.service -n 50`                             |
| Can't connect from Desktop app | Verify IP with `hostname -I`, ensure firewall allows port 9119                            |
| Want to reconfigure            | Run with `--clean`: `bash setup-gateway.sh --clean`                                       |

## Requirements

- Linux with systemd (user services)
- Hermes Agent v0.18.0+ (`hermes` command on PATH)
- openssl (for secret generation)
- Network access on the chosen port

## Follow me on X: https://x.com/MiaAI_lab