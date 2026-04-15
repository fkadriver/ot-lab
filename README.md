# OT/ICS Cybersecurity Lab

A personal OT/ICS security lab for testing and evaluating cybersecurity tools (Claroty, Armis, Nozomi, Dragos) against realistic industrial control system simulations.

## Lab Goals

- Simulate realistic OT/ICS environments with real industrial protocols
- Generate OT traffic for passive monitoring/detection tools
- Test OT security platforms (Claroty, Armis, Nozomi, Dragos) in a safe environment
- Leverage existing SANS ICS course materials

---

## Recommended Lab Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Host Machine                        │
│                                                      │
│  ┌─────────────────────┐  ┌──────────────────────┐  │
│  │   GRFICSv3 (Docker) │  │  Labshock (Docker)   │  │
│  │  - Chemical Plant   │  │  - SCADA/PLC/HMI     │  │
│  │  - OpenPLC          │  │  - Modbus/S7/OPC UA  │  │
│  │  - HMI (ScadaBR)   │  │  - BACnet/MQTT/EtIP  │  │
│  │  - Kali + Caldera   │  │  - EWS/Pentest tools │  │
│  │  - Suricata IDS     │  │                      │  │
│  └──────────┬──────────┘  └──────────┬───────────┘  │
│             │                        │               │
│  ┌──────────▼────────────────────────▼───────────┐  │
│  │          OT Network Bridge (Docker)            │  │
│  │    Protocols: Modbus, S7, EtherNet/IP,        │  │
│  │    OPC-UA, BACnet, DNP3, MQTT                 │  │
│  └──────────────────────┬────────────────────────┘  │
│                         │                            │
│  ┌──────────────────────▼────────────────────────┐  │
│  │        OT Security Sensor (SPAN port)          │  │
│  │   Claroty / Nozomi / Dragos / Armis sensor     │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  ┌───────────────────────────────────────────────┐  │
│  │   SANS ICS310 RELICS VM (VMware)               │  │
│  │   Windows 10 - ICS tooling & scenarios         │  │
│  │   Source: ~/Documents/SANS/ICS/310/            │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

---

## Lab Components

### 1. GRFICSv3 (Primary — Recommended)

**Repo:** https://github.com/Fortiphyd/GRFICSv3  
**Type:** Docker Compose  
**Deploy:** `docker compose up -d`

A free, open-source OT security lab simulating a chemical plant with realistic process dynamics.

**Components:**
- OpenPLC (port 8080)
- HMI / ScadaBR (port 6081)
- Engineering Workstation (port 6080)
- Segmented network (DMZ / ICS zones) with router/firewall
- Kali Linux attacker VM with MITRE Caldera OT plugin
- Suricata IDS

**Protocols:** Modbus TCP, EtherNet/IP  
**Best for:** Generating realistic ICS traffic for passive monitoring tools (Claroty, Nozomi, Dragos)

---

### 2. Labshock (Protocol Breadth)

**Repo:** https://github.com/zakharb/labshock  
**Type:** Docker Compose  
**Deploy:** `docker compose up -d`

A quick-start OT lab with broader protocol coverage than GRFICSv3.

**Components:**
- Portal (lab management UI)
- SCADA (multi-protocol)
- PLC (full IEC 61131-3 support)
- Engineering Workstation
- Pentest Fury (offensive tools)
- Network Swiftness (traffic monitor)
- Tidal Collector (SIEM forwarding)
- Firewall simulation
- IT/OT Transfer scenarios

**Protocols:** Modbus RTU/TCP, EtherNet/IP, BACnet IP, OPC UA, MQTT, S7comm, WebAPI  
**Limitations:** Trial mode = 40-min sessions (free); license required for persistent use  
**Best for:** Protocol variety testing, S7/BACnet/OPC-UA coverage

---

### 3. SANS ICS310 RELICS VM (Already Available)

**Location:** `~/Documents/SANS/ICS/310/310.25.1.iso` (7.9 GB)  
**Type:** VMware VM (Windows 10)  
**Login:** `relics` / `relics`

Pre-built Windows 10 VM from SANS ICS310 course with ICS security tools and lab scenarios already configured. Does not require any additional downloads.

**Best for:** Hands-on ICS analysis exercises, reusing SANS course labs

---

### 4. Conpot (Honeypot / Device Emulation)

**Install:** `pip install conpot`  
**Type:** Python-based ICS honeypot

Emulates real ICS device fingerprints (Siemens S7-200, etc.) to generate realistic device discovery responses.

**Protocols:** Modbus, S7comm, BACnet, EtherNet/IP  
**Best for:** Testing asset discovery features in Claroty/Nozomi/Dragos

---

## Testing OT Security Tools (Claroty / Armis / Nozomi / Dragos)

These tools work primarily via **passive network traffic monitoring** (span port / network tap). To test them:

1. **Deploy GRFICSv3** to generate realistic Modbus/EtherNet/IP traffic
2. **Deploy Labshock** alongside for S7, OPC-UA, BACnet traffic
3. **Connect the sensor** — most tools offer a virtual sensor/probe VM or Docker image:
   - Point it at the Docker bridge network (`docker network inspect`)
   - Or configure a Linux bridge with traffic mirroring (`tc mirred` or `iptables TEE`)
4. **Run attack scenarios** using GRFICSv3's built-in Kali + Caldera to generate alerts
5. **Validate detections** — check that the tool detects:
   - Device inventory (PLCs, HMIs, EWS)
   - Protocol anomalies
   - Known attack signatures (Modbus coil writes, unauthorized engineering commands)

---

## Quick Start

```bash
# 1. Clone GRFICSv3
git clone https://github.com/Fortiphyd/GRFICSv3
cd GRFICSv3
docker compose up -d

# 2. Clone Labshock
git clone https://github.com/zakharb/labshock
cd labshock
docker compose up -d

# 3. Check running containers
docker ps

# 4. List Docker networks (for sensor attachment)
docker network ls
```

See [docs/sensor-setup.md](docs/sensor-setup.md) for connecting OT security sensors.

---

## SANS Courses Available

| Course | Description | VM Available |
|--------|-------------|--------------|
| ICS310 | ICS Security Essentials (Blue Team) | Yes — RELICS VM (7.9GB ISO) |
| ICS418 | ICS Red Team Operations | No VM (curriculum only) |
| ICS410 | ICS/SCADA Security Essentials | No VM (audio only) |

---

## Resources

- [SANS ICS Curriculum](https://www.sans.org/ics-security/)
- [GRFICSv3 GitHub](https://github.com/Fortiphyd/GRFICSv3)
- [Labshock GitHub](https://github.com/zakharb/labshock)
- [MITRE ATT&CK for ICS](https://attack.mitre.org/matrices/ics/)
- [ICS-CERT Advisories](https://www.cisa.gov/ics-advisories)
- [OpenPLC Runtime](https://autonomylogic.com/)
