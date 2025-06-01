# Go Cross-Platform VPN Tool

Ein plattformübergreifendes VPN-Tool in Go für Windows (WinTun) und Linux/macOS (native TUN-Devices).

## Features

- OpenSSH-kompatibler TUN-Tunnel via `ssh -w`-Mechanik
- Automatisches Remote-TUN-Setup via SSH
- Plattformübergreifend: Windows (WinTun), Linux/macOS (/dev/net/tun)

## Installation

```bash
git clone https://github.com/<yourname>/go-cross-platform-vpn.git
cd go-cross-platform-vpn
go mod tidy
go build -o vpn-tool
```

## Verwendung

```bash
./vpn-tool
```

## Voraussetzung

- `PermitTunnel yes` in `/etc/ssh/sshd_config` auf dem Remote-Server
- Passwortloses sudo für `ip`, `sysctl` auf Remote-Server

## Lizenz

MIT
