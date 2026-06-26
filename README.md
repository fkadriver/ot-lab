# OT/ICS Cybersecurity Lab

A personal OT/ICS security lab for testing and evaluating cybersecurity tools against realistic industrial control system simulations.

---

## Architecture

All modules run as independent Docker Compose stacks and are launched via `./lab.sh`.

```
┌──────────────────────────────────────────────────────────────────────┐
│                            Host Machine                              │
│                                                                      │
│  ── Process Simulations ──────────────────────────────────────────  │
│                                                                      │
│  GRFICSv3     Tennessee Eastman chemical plant                       │
│               OpenPLC · ScadaLTS · Caldera C2 · Kali                │
│               ICS Net 192.168.95.0/24 · DMZ Net 192.168.90.0/24     │
│               Router w/ Suricata IDS · Wazuh SIEM (optional)        │
│                                                                      │
│  Labshock     Multi-protocol SCADA breadth                           │
│               Modbus RTU/TCP · S7comm · EtherNet/IP · BACnet ·      │
│               OPC UA · MQTT                                          │
│                                                                      │
│  ICSSIM       Bottle-filling factory (Modbus TCP)                    │
│                                                                      │
│  ICSsVirtual  Wastewater treatment plant                             │
│               OpenPLC · ScadaLTS · attacker container                │
│                                                                      │
│  RangerDanger Electric substation segmentation training              │
│               DNP3 · Modbus · OpenDSS power-flow · IEC 62443 zones  │
│               containd NGFW built-in                                 │
│                                                                      │
│  ── Security Tools ───────────────────────────────────────────────  │
│                                                                      │
│  containd     ICS-aware NGFW — zone-based firewalling w/ DPI        │
│               Modbus · DNP3 · CIP · S7comm · IEC 61850 · BACnet     │
│                                                                      │
│  Malcolm      OT SOC/NSM — Zeek · Suricata · OpenSearch · Arkime    │
│               Native ICS protocol decoders, PCAP analysis           │
│                                                                      │
│  Conpot       ICS/SCADA honeypot                                     │
│               Modbus · S7comm · BACnet · IEC 60870-5-104 · ENIP     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
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

### Labshock — Protocol Breadth

**Repo:** https://github.com/zakharb/labshock  
**Protocols:** Modbus RTU/TCP, S7comm, EtherNet/IP, BACnet IP, OPC UA, MQTT

Broader protocol coverage than GRFICSv3. Trial mode limits sessions to 40 minutes.

### ICSSIM — Bottle-Filling Factory

**Repo:** https://github.com/AlirezaDehlaghi/ICSSIM  
**Protocols:** Modbus TCP

Extensible ICS testbed framework with a bottle-filling factory as the reference scenario. Designed for reproducible cybersecurity experiments — process topology is defined via config.

### ICSsVirtual — Wastewater Treatment Plant

**Repo:** https://github.com/sfl0r3nz05/ICSsVirtualForCiberSec  
**Protocols:** Modbus TCP

Wastewater treatment plant simulation with OpenPLC, ScadaLTS HMI, a physical process simulator, and a built-in attacker container. Supports GNS3 for realistic network topology.

### RangerDanger — Electric Substation Training

**Repo:** https://github.com/tonylturner/rangerdanger  
**Protocols:** DNP3 TCP, Modbus TCP

Hands-on substation segmentation training platform with a web-based topology console, structured lab exercises, and an OpenDSS power-flow simulator that models real electrical consequences of attacks (breaker trips, voltage changes). Built around IEC 62443 security zones. Includes containd as its built-in NGFW.

| Service | URL |
|---|---|
| Topology console | http://localhost:8088 |
| Backend API | http://localhost:9080 |
| containd NGFW | https://localhost:9443 |

Requires 16 GB RAM minimum. First run: `cd rangerdanger && ./setup.sh`

### containd — ICS-Aware NGFW

**Repo:** https://github.com/tonylturner/containd

Zone-based next-generation firewall purpose-built for ICS/OT network segmentation. Deep packet inspection down to function-code level for Modbus, DNP3, CIP/EtherNet-IP, S7comm, IEC 61850, BACnet, and OPC UA. Learn-then-enforce workflow; default-deny posture. Also included within RangerDanger.

| Service | URL |
|---|---|
| Web UI | http://localhost:8080 |
| SSH console | localhost:2222 |

### Malcolm — OT SOC/NSM

**Repo:** https://github.com/cisagov/Malcolm  
**Maintainer:** CISA / Idaho National Laboratory

Full network traffic analysis suite for ICS/OT environments: Zeek, Suricata, OpenSearch Dashboards, and Arkime packet capture. Native decoders for 20+ ICS protocols. Pairs with any simulation module to provide a blue-team SOC layer.

| Service | URL |
|---|---|
| OpenSearch Dashboards | https://localhost |
| Arkime packet capture | https://localhost:8005 |
| File upload | https://localhost:8443 |

**First-run setup required:**
```bash
cd malcolm && python3 scripts/install.py
touch .configured
```

### Conpot — ICS/SCADA Honeypot

**Repo:** https://github.com/mushorg/conpot

Low-interaction ICS honeypot emulating a Siemens S7-300 PLC and Simatic HMI by default. Broad protocol coverage in a single container — useful for deception, detection testing, and protocol fuzzing.

| Protocol | Port |
|---|---|
| Modbus | 502 |
| S7comm | 102 |
| HTTP | 80 |
| BACnet | 47808 |
| IEC 60870-5-104 | 2404 |

---

## Quick Start

```bash
git clone --recursive https://github.com/fkadriver/ot-lab
cd ot-lab

# Interactive launcher — select modules from a menu
./lab.sh

# Or start specific components directly
./scripts/start-lab.sh grfics
./scripts/start-lab.sh grfics --siem
./scripts/start-lab.sh all --siem
```

---

## Lab Management

```bash
# Start
./scripts/start-lab.sh [grfics|labshock|all] [--siem]

# Stop (keeps all data)
./scripts/stop-lab.sh [grfics|labshock|all]

# Restart (keeps data)
./scripts/start-lab.sh restart [grfics|labshock|all] [--siem]

# Reset — wipe all volumes and start fresh
./scripts/start-lab.sh reset [grfics|labshock|all] [--siem]

# Stop and wipe volumes only (no restart)
./scripts/stop-lab.sh [grfics|labshock|all] --wipe
```

**What `--wipe` clears:** ScadaLTS historian DB, PLC state, router config, Wazuh indexes, Labshock portal data.

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

## Azure Deployment

A self-contained Azure deployment package is in [ot-lab_azure/](ot-lab_azure/). It includes:

- **Bicep template** — single-VM deployment (Ubuntu 22.04, nested-virt capable D-series)
- **cloud-init** — bootstraps Docker, QEMU/KVM, and OVMF at first boot
- **Azure network override** — uses Docker `bridge` instead of `macvlan` (Azure hypervisors drop macvlan subinterface traffic)
- **Scripts** — all lab scripts with credentials stripped
- No Wazuh/SIEM in the Azure package

```bash
# One-time deploy
az group create -n ot-lab-rg -l eastus
az deployment group create -g ot-lab-rg -f ot-lab_azure/deploy/main.bicep \
  -p adminUsername=labadmin adminPublicKey="$(cat ~/.ssh/id_rsa.pub)"
```

See [ot-lab_azure/README.md](ot-lab_azure/README.md) for full deployment steps.

---

## Resources

- [GRFICSv3](https://github.com/Fortiphyd/GRFICSv3)
- [Labshock](https://github.com/zakharb/labshock)
- [ICSSIM](https://github.com/AlirezaDehlaghi/ICSSIM)
- [ICSsVirtualForCiberSec](https://github.com/sfl0r3nz05/ICSsVirtualForCiberSec)
- [RangerDanger](https://github.com/tonylturner/rangerdanger)
- [containd](https://github.com/tonylturner/containd)
- [Malcolm](https://github.com/cisagov/Malcolm)
- [Conpot](https://github.com/mushorg/conpot)
- [MITRE ATT&CK for ICS](https://attack.mitre.org/matrices/ics/)
- [Wazuh Documentation](https://documentation.wazuh.com/)
- [DigitalBond Quickdraw Rules](https://github.com/digitalbond/Quickdraw-Snort)
- [CISA ICS Advisories](https://www.cisa.gov/ics-advisories)

### Additional ICS Security Resources

- [ITI/ICS-Security-Tools](https://github.com/ITI/ICS-Security-Tools) — curated index of ICS simulation environments, protocol tools, and testbeds maintained by the University of Illinois Information Trust Institute
- [ICS Village CTF — Hack the Plan(e)t](https://hacktheplanet.ctfd.io) — self-paced CTF challenges covering Modbus, DNP3, EtherNet/IP, and BACnet packet analysis, PLC logic, and ICS forensics; updated each DEFCON cycle
- [libIEC61850](https://github.com/mz-automation/libiec61850) — reference open-source C library for IEC 61850 (MMS, GOOSE, Sampled Values); ships with working IED server/client examples for building custom substation emulators
