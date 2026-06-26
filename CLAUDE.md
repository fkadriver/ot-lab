# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ot-lab** is an OT/ICS cybersecurity lab for testing security tools against realistic industrial control system environments. It combines simulation platforms (GRFICSv3, Labshock) with an optional Wazuh SIEM integration.

## Lab Management Commands

```bash
# Interactive launcher — select one or more modules from a numbered menu
./lab.sh

# Legacy per-component launcher (GRFICSv3 / Labshock only)
./scripts/start-lab.sh [grfics|labshock|all] [--siem]
./scripts/start-lab.sh restart [grfics|labshock|all]
./scripts/start-lab.sh reset [grfics|labshock|all]    # wipe + restart

# Stop lab environments
./scripts/stop-lab.sh [grfics|labshock|all] [--wipe]  # --wipe removes volumes

# Traffic generation (requires GRFICSv3 running)
docker exec kali nmap -p 502 --script modbus-discover 192.168.95.2
```

### Malcolm first-run setup
Malcolm requires one-time configuration before `lab.sh` can start it:
```bash
cd malcolm && python3 scripts/install.py
touch .configured   # signals lab.sh that install is complete
```

## Architecture

### Git Submodules
- **GRFICSv3/** — primary ICS simulation (Tennessee Eastman chemical process)
- **labshock/** — multi-protocol ICS breadth lab (Modbus, S7comm, EtherNet/IP, BACnet, OPC UA, MQTT)
- **rangerdanger/** — electric substation segmentation training platform; Docker Compose, DNP3 + Modbus, OpenDSS power-flow simulation, IEC 62443 zones, structured lab exercises; bundles containd as its NGFW; needs ports 8088/9080/9443/2222 and 16 GB RAM
- **containd/** — ICS-aware NGFW container (Go binary, Docker Compose); zone-based firewalling with deep packet inspection for Modbus, DNP3, CIP, S7comm, IEC 61850, BACnet, OPC UA at function-code level; learn-then-enforce workflow; can augment the Suricata router in GRFICSv3 for protocol-aware enforcement

### Network Segments
| Segment | CIDR | Hosts |
|---|---|---|
| ICS Net | 192.168.95.0/24 | OpenPLC, simulation, ScadaLTS, engineering workstation |
| DMZ Net | 192.168.90.0/24 | Kali attacker, Caldera C2 |
| Admin Bridge | 172.18.0.0/16 | Wazuh SIEM |

The router container sits at the boundary of all three segments and runs Suricata IDS with DigitalBond Quickdraw ICS/SCADA signatures.

### Docker Compose Structure
- `GRFICSv3/docker-compose.yml` — base GRFICSv3 stack
- `overrides/grfics-override.yml` — local customizations to GRFICSv3
- `labshock/docker-compose.yml` — standalone Labshock stack

The `start-lab.sh` script merges these with `-f` flags as needed.

## Key Files
- `scripts/start-lab.sh` — orchestration entry point; controls which compose files are merged
