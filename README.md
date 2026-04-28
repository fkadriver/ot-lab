# OT/ICS Cybersecurity Lab

A personal OT/ICS security lab for testing and evaluating cybersecurity tools against realistic industrial control system simulations.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          Host Machine                           │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   GRFICSv3 (Docker)                     │   │
│  │                                                         │   │
│  │  OpenPLC ── Simulation ── ScadaLTS ── Engineering WS   │   │
│  │      │           │                                      │   │
│  │  ICS Net (192.168.95.0/24)   DMZ Net (192.168.90.0/24) │   │
│  │      └───────── Router ────────── Kali + Caldera ───┘  │   │
│  │                    │                                    │   │
│  │            Admin Bridge (172.18.0.0/16)                │   │
│  │                    │                                    │   │
│  │          Wazuh SIEM (optional --siem)                  │   │
│  └────────────────────┼───────────────────────────────────┘   │
│                        │ tc SPAN mirror                         │
│  ┌─────────────────────▼─────────────────────────────────┐    │
│  │        Armis Collector VM / QCOW2 (optional --armis)   │    │
│  │        Passive capture → lab-kudelski.armis.com        │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              Labshock (Docker, optional)                  │  │
│  │   Multi-protocol SCADA: Modbus/S7/OPC-UA/BACnet/MQTT    │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Components

### GRFICSv3 — Chemical Plant Simulation

**Repo:** https://github.com/Fortiphyd/GRFICSv3  
**Protocols:** Modbus TCP, EtherNet/IP

Simulates a Tennessee Eastman chemical process with a full ICS stack:

| Service | URL | Notes |
|---|---|---|
| OpenPLC (PLC runtime) | http://localhost:8080 | `openplc` / `openplc` |
| ScadaLTS (HMI) | http://localhost:6081 | `admin` / `admin` |
| Engineering WS | http://localhost:6080 | |
| Caldera C2 | http://localhost:8888 | `red` / `fortiphyd-red` |

**Optional add-ons:**

| Flag | Add-on | URL |
|---|---|---|
| `--siem` | Wazuh SIEM (Manager + Indexer + Dashboard) | http://localhost:5601 — `admin` / `admin` |
| `--armis` | Armis vSensor collector VM | https://localhost:18443 — `config` / `Armis` |

### Labshock — Protocol Breadth

**Repo:** https://github.com/zakharb/labshock  
**Protocols:** Modbus RTU/TCP, S7comm, EtherNet/IP, BACnet IP, OPC UA, MQTT

Broader protocol coverage than GRFICSv3. Trial mode limits sessions to 40 minutes.

---

## Quick Start

```bash
git clone --recursive https://github.com/fkadriver/ot-lab
cd ot-lab

# GRFICSv3 only
./scripts/start-lab.sh grfics

# GRFICSv3 + Wazuh SIEM
./scripts/start-lab.sh grfics --siem

# GRFICSv3 + Armis collector
source .env.armis
./scripts/start-lab.sh grfics --armis

# Everything
./scripts/start-lab.sh all --siem --armis

# Start the Armis collector VM (first time or after host reboot)
sudo -E ./scripts/armis-collector-setup.sh
```

---

## Lab Management

```bash
# Start
./scripts/start-lab.sh [grfics|labshock|all] [--siem] [--armis]

# Stop (keeps all data)
./scripts/stop-lab.sh [grfics|labshock|all]

# Restart (keeps data)
./scripts/start-lab.sh restart [grfics|labshock|all] [--siem] [--armis]

# Reset — wipe all volumes and start fresh
./scripts/start-lab.sh reset [grfics|labshock|all] [--siem] [--armis]

# Stop and wipe volumes only (no restart)
./scripts/stop-lab.sh [grfics|labshock|all] --wipe
```

**What `--wipe` clears:** ScadaLTS historian DB, PLC state, router config, Armis PCAPs/flow stats, Wazuh indexes, Labshock portal data, Armis VM UEFI state. Does **not** delete the Armis QCOW2 image.

---

## Armis Integration

The Armis vSensor collector VM receives a tc-mirrored copy of all ICS/DMZ traffic from the router and sends it to `lab-kudelski.armis.com` for cloud analysis.

```bash
# One-time setup
./scripts/armis-setup.sh --api-key "your-api-token"

# Start lab with Armis
source .env.armis
./scripts/start-lab.sh grfics --armis

# Start collector VM (required after host reboot)
sudo -E ./scripts/armis-collector-setup.sh

# Restart collector VM only
sudo -E ./scripts/armis-collector-setup.sh --restart
```

**Collector VM details:**
- Web UI: https://localhost:18443 (`config` / `Armis`)
- Collector ID: 8156 — Tenant: lab-kudelski.armis.com
- SPAN mirrors on router are re-applied automatically by `start-lab.sh --armis`

---

## Wazuh SIEM

Wazuh is bundled as an optional all-in-one container (Manager + OpenSearch Indexer + Dashboard). Wazuh agents are pre-installed on the router (Suricata/Quickdraw ICS alerts) and ScadaLTS (Tomcat/MariaDB logs).

```bash
./scripts/start-lab.sh grfics --siem
# Dashboard: http://localhost:5601  (admin / admin)
```

**What's monitored out of the box:**
- Router: Suricata IDS alerts with DigitalBond Quickdraw ICS/SCADA signatures (Modbus, DNP3, EtherNet/IP)
- ScadaLTS: Tomcat access/error logs, MariaDB error logs

---

## Attack Scenarios

Caldera with the Modbus OT plugin is pre-installed in the GRFICSv3 `caldera` container. The `Attack1` adversary profile runs a Modbus-based attack chain against the PLC.

```bash
# Caldera UI
open http://localhost:8888   # red / fortiphyd-red

# Manual Modbus attack from Kali
docker exec kali mbpoll -a 1 -t 0 -1 192.168.95.2 1
```

---

## Resources

- [GRFICSv3](https://github.com/Fortiphyd/GRFICSv3)
- [Labshock](https://github.com/zakharb/labshock)
- [MITRE ATT&CK for ICS](https://attack.mitre.org/matrices/ics/)
- [Wazuh Documentation](https://documentation.wazuh.com/)
- [DigitalBond Quickdraw Rules](https://github.com/digitalbond/Quickdraw-Snort)
- [CISA ICS Advisories](https://www.cisa.gov/ics-advisories)
