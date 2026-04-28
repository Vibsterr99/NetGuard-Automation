# NetGuard Automation

A profile-driven security hardening toolkit for Ubuntu that installs and configures five security tools with a single command. Choose between three hardening profiles based on environment needs — from basic firewall rules to a full monitoring stack with network IDS and centralized log management.

## What It Does

NetGuard automates the deployment and configuration of:

| Tool | Purpose | General | Secure | Enterprise |
|------|---------|---------|--------|------------|
| **UFW** | Host firewall — controls inbound/outbound traffic | Allow SSH + HTTP/S, deny rest | Restrict to SSH only, rate-limit enabled | Strict allowlist, logging enabled |
| **Fail2Ban** | Brute-force protection — bans IPs after repeated failures | SSH jail, 5 retries | SSH + HTTP jails, 3 retries, longer bans | All jails active, aggressive ban policy |
| **ClamAV** | Antivirus — scans for malware on disk | Install only | Install + scheduled weekly scan | Install + daily scan + real-time monitoring |
| **Suricata** | Network IDS — monitors traffic for threats | Not installed | Installed, ET Open rules | Installed, ET Open rules, EVE JSON logging |
| **ELK Stack** | Log management — Elasticsearch, Logstash, Kibana | Not installed | Not installed | Full stack with log ingestion pipeline |

## Quick Install

Enterprise profile (recommended for lab environments):
```bash
curl -fsSL https://raw.githubusercontent.com/Vibsterr99/NetGuard-Automation/main/install.sh | sudo -E bash
```

General profile (basic hardening):
```bash
NETGUARD_PROFILE=general curl -fsSL https://raw.githubusercontent.com/Vibsterr99/NetGuard-Automation/main/install.sh | sudo -E bash
```

Secure profile (tighter controls, no ELK):
```bash
NETGUARD_PROFILE=secure curl -fsSL https://raw.githubusercontent.com/Vibsterr99/NetGuard-Automation/main/install.sh | sudo -E bash
```

After installation, reopen the menu anytime with:
```bash
sudo netguard
```

## How It Works

The `install.sh` script downloads the repo, copies all scripts to `/usr/local/netguard/`, and runs each component script in sequence with the selected profile. Each script checks the profile flag and adjusts its configuration accordingly — for example, `ufu.sh` opens different ports depending on whether the profile is general (HTTP/HTTPS allowed) or secure (SSH only).

The scripts are designed to be idempotent — running them again on the same machine updates the configuration without breaking existing settings.

## Scripts

| Script | Tool | What It Configures |
|--------|------|-------------------|
| `ufu.sh` | UFW | Firewall rules, default deny policy, port allowlists per profile |
| `f2b.sh` | Fail2Ban | Jail configuration, retry limits, ban durations, monitored services |
| `cav.sh` | ClamAV | Virus database updates, scan schedules, exclusion paths |
| `suricata.sh` | Suricata | Interface selection, rule updates (ET Open), EVE JSON output config |
| `elk.sh` | ELK Stack | Elasticsearch, Logstash, Kibana installation and pipeline setup |
| `logrptate.sh` | Logrotate | Log rotation policies for all installed security tools |
| `main.sh` | Menu | Interactive menu for managing all components post-install |

## Requirements

- Ubuntu 22.04 or 24.04 (tested on both)
- Root/sudo access
- Internet connection for package downloads
- Minimum 4 GB RAM for General/Secure profiles
- Minimum 8 GB RAM for Enterprise profile (ELK stack is memory-intensive)

## Project Structure

```
NetGuard-Automation/
├── install.sh          # One-line installer — downloads and runs everything
├── Scripts/
│   ├── main.sh         # Interactive management menu
│   ├── ufu.sh          # UFW firewall configuration
│   ├── f2b.sh          # Fail2Ban brute-force protection
│   ├── cav.sh          # ClamAV antivirus
│   ├── suricata.sh     # Suricata network IDS
│   ├── elk.sh          # ELK stack deployment
│   └── logrptate.sh    # Log rotation setup
└── README.md
```

## Related Projects

This toolkit was built as part of a security engineering portfolio. The other two repos build on the same infrastructure:

- [detection-content-pack](https://github.com/Vibsterr99/detection-content-pack) — 10 ATT&CK-mapped Sigma detections validated on a Wazuh SIEM lab with Sysmon and Suricata telemetry
- [threat-hunt-notebooks](https://github.com/Vibsterr99/threat-hunt-notebooks) — 6 hypothesis-driven threat hunts across endpoint, identity, network, cloud, and lateral movement telemetry
