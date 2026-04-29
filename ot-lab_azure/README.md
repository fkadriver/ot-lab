# OT/ICS Cybersecurity Lab — Azure Deployment

Deploys a GRFICSv3 chemical plant simulation with Armis vSensor integration on a single Azure VM. All ICS components run as Docker containers; the Armis collector runs as a KVM virtual machine on the same host.

---

## Architecture

```
Azure VM (Standard_D4s_v3 or larger)
│
├── Docker: GRFICSv3
│   ├── OpenPLC          — Modbus TCP PLC (192.168.95.2)
│   ├── Simulation       — Tennessee Eastman process
│   ├── ScadaLTS (HMI)   — SCADA historian + HMI
│   ├── Engineering WS   — noVNC workstation
│   ├── Router           — inter-network routing + Suricata IDS
│   ├── Kali + Caldera   — attacker + C2 (192.168.90.6)
│   │
│   ├── ICS Net   192.168.95.0/24  (Docker bridge)
│   ├── DMZ Net   192.168.90.0/24  (Docker bridge)
│   └── Admin     172.18.0.0/16    (Docker bridge)
│                      │
│                 tc SPAN mirror
│                      │
└── KVM: Armis Collector VM
    ├── enp0s2 — QEMU NAT → internet → Armis cloud
    └── enp0s3 — TAP on admin bridge (passive OT traffic capture)
```

**Network note:** This deployment uses Docker `bridge` networks for ICS/DMZ instead of `macvlan`. Azure VM NICs enforce strict MAC filtering at the hypervisor level, which silently drops macvlan subinterface traffic. Bridge networks are functionally identical for this lab.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Azure subscription | Contributor role on target resource group |
| Azure CLI | `az` v2.50+ — [install](https://docs.microsoft.com/cli/azure/install-azure-cli) |
| SSH key pair | `ssh-keygen -t rsa -b 4096` |
| Armis tenant | API key, collector ID, and license key from Armis console |

---

## Deploy

### 1. Create the resource group and VM

```bash
az login
az group create -n ot-lab-rg -l eastus

az deployment group create \
  -g ot-lab-rg \
  -f deploy/main.bicep \
  -p adminUsername=labadmin \
     adminPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
     labName=ot-lab
```

Deployment takes ~3 minutes. The VM public IP is in the output.

```bash
# Get the IP
az deployment group show -g ot-lab-rg -n main \
  --query properties.outputs.publicIpAddress.value -o tsv
```

### 2. Wait for cloud-init to finish (~5 minutes)

```bash
ssh labadmin@<VM_IP>
sudo tail -f /var/log/cloud-init-output.log
# Wait for: "OT Lab VM bootstrap complete."
```

### 3. Configure Armis credentials

```bash
cd /opt/ot-lab
cp .env.armis.example .env.armis
nano .env.armis   # fill in all ARMIS_* values
```

The required values come from the Armis console:

| Variable | Where to find it |
|---|---|
| `ARMIS_API_KEY` | Settings → API → Generate Token |
| `ARMIS_HOSTNAME` | Your tenant URL, e.g. `your-tenant.armis.com` |
| `ARMIS_COLLECTOR_ID` | Settings → Sensors & Collectors → your collector |
| `ARMIS_COLLECTOR_LICENSE` | Settings → Sensors & Collectors → your collector |

Validate the API key:
```bash
./scripts/armis-setup.sh --api-key "$ARMIS_API_KEY" --hostname "$ARMIS_HOSTNAME"
```

### 4. Start the lab

```bash
source .env.armis
./scripts/start-lab.sh grfics --armis
```

### 5. Deploy the Armis collector VM

```bash
sudo -E ./scripts/armis-collector-setup.sh
```

The collector QCOW2 image (~3.5 GB) is downloaded from Armis automatically using your API key. The VM boots in ~3 minutes.

**Activate the collector** — from your workstation, create an SSH tunnel then open the web UI:

```bash
# On your workstation
ssh -L 18443:localhost:18443 labadmin@<VM_IP>

# Then open in browser
open https://localhost:18443   # user: config / pass: Armis
```

Enter the Armis URL, License Key, and Collector ID when prompted.

---

## Lab Access

| Service | URL | Credentials |
|---|---|---|
| ScadaLTS (HMI) | `http://<VM_IP>:6081` | `admin` / `admin` |
| Engineering WS | `http://<VM_IP>:6080` | — |
| OpenPLC | `http://<VM_IP>:8080` | `openplc` / `openplc` |
| Caldera C2 | `http://<VM_IP>:8888` | `red` / `fortiphyd-red` |
| Armis collector UI | `https://localhost:18443` (SSH tunnel) | `config` / `Armis` |
| Armis portal | `https://<ARMIS_HOSTNAME>` | your org credentials |

---

## Lab Management

```bash
# Start (keeps existing data)
./scripts/start-lab.sh grfics [--armis]

# Stop (keeps all data)
./scripts/stop-lab.sh

# Restart (keeps data, re-applies SPAN mirrors)
./scripts/start-lab.sh restart [--armis]

# Reset — wipe all volumes and start fresh
./scripts/start-lab.sh reset [--armis]

# Restart Armis collector VM only (after host reboot)
source .env.armis
sudo -E ./scripts/armis-collector-setup.sh --restart
```

**What `reset` wipes:** ScadaLTS historian DB, PLC state, router config, Armis PCAPs/flow stats. Does **not** delete the Armis QCOW2 image.

---

## Verify Armis Traffic

After the collector is active, run the SPAN test to generate known traffic:

```bash
docker cp scripts/span-test.py kali:/tmp/span-test.py
docker exec kali python3 /tmp/span-test.py
```

Or from inside kali after a restart (scripts are bind-mounted):
```bash
docker exec kali python3 /opt/lab-scripts/span-test.py
```

In the Armis collector web UI → Diagnostics → Span Statistics, you should see unicast packet counts rising. Devices (PLC, router, kali) should appear in the Armis portal within 1–2 minutes of traffic flowing.

---

## Attack Scenarios

Caldera with the Modbus OT plugin is pre-installed in the `caldera` container. The `Attack1` adversary profile runs a Modbus-based attack chain against the PLC.

```bash
# Caldera UI
open http://<VM_IP>:8888   # red / fortiphyd-red

# Manual Modbus attack from Kali
docker exec kali python3 /opt/lab-scripts/span-test.py
```

---

## Teardown

```bash
# Stop containers (keeps VM and data)
./scripts/stop-lab.sh

# Delete everything in Azure
az group delete -n ot-lab-rg --yes --no-wait
```

---

## Troubleshooting

**Armis collector shows 0 unicast in Span Statistics**
SPAN mirrors may have been lost after a container restart. Re-apply:
```bash
./scripts/start-lab.sh grfics --armis
```

**KVM not available**
Azure VMs in the Dv3/Dv4/Ev3/Ev4 families support nested virtualisation. Confirm with `kvm-ok`. If using a different VM size, check the [Azure nested virtualisation docs](https://docs.microsoft.com/azure/virtual-machines/acu).

**Port not reachable from browser**
NSG rules in `main.bicep` allow the lab ports from `*`. If your org restricts this, update the `sourceAddressPrefix` for each rule to your IP range.

**`docker compose` not found**
The cloud-init installs the Docker Compose v2 plugin (`docker compose`). If missing: `sudo apt-get install -y docker-compose-plugin`.

---

## Resources

- [GRFICSv3](https://github.com/Fortiphyd/GRFICSv3)
- [MITRE ATT&CK for ICS](https://attack.mitre.org/matrices/ics/)
- [Armis Documentation](https://docs.armis.com)
- [Azure Nested Virtualisation](https://docs.microsoft.com/azure/virtual-machines/acu)
- [CISA ICS Advisories](https://www.cisa.gov/ics-advisories)
