# NetGuard Automation

Profile-driven security stack for Ubuntu: **UFW**, **Fail2Ban**, **ClamAV**, **Suricata**, and **ELK (Elasticsearch + Kibana + Logstash)**. Three profiles: **General / Secure / Enterprise**.

## One-line install (Enterprise by default)

```bash
curl -fsSL https://raw.githubusercontent.com/Vibsterr99/NetGuard-Automation/main/install.sh | sudo -E bash

NETGUARD_PROFILE=secure curl -fsSL https://raw.githubusercontent.com/Vibsterr99/NetGuard-Automation/main/install.sh | sudo -E bash

