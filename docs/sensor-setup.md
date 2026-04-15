# Connecting OT Security Sensors to the Lab

This guide covers how to connect a Claroty, Nozomi, Dragos, or Armis sensor to the Docker-based lab environments.

## How These Tools Work

Claroty, Nozomi, Dragos, and Armis all use **passive network traffic analysis** as their primary discovery method. They need to see OT protocol traffic (Modbus, EtherNet/IP, S7, etc.) on a monitored interface. In a physical deployment this is done via a network tap or SPAN port on a managed switch.

In a Docker lab, you replicate this by either:
1. Attaching the sensor container to the same Docker network as the simulation
2. Mirroring traffic from the Docker bridge to a dedicated monitoring interface

---

## Option 1: Attach Sensor to Docker Network (Simplest)

Most OT security vendors provide a virtual sensor (OVA/Docker image) for lab/demo use.

```bash
# Find the GRFICSv3 network name
docker network ls | grep grfics

# Run your sensor container on the same network
docker run --network <grfics-network-name> --cap-add NET_ADMIN <sensor-image>
```

For Nozomi Networks Guardian, Claroty Edge, or Dragos Platform sensors delivered as OVAs, attach the VM's network adapter to the same VMware/VirtualBox host-only network that the Docker bridge uses.

---

## Option 2: Traffic Mirroring with tc/iptables

Mirror traffic from a Docker bridge to a dedicated interface for a standalone sensor appliance.

```bash
# Find the Docker bridge interface for GRFICSv3
BRIDGE=$(docker network inspect grficsv3_default --format '{{.Id}}' | cut -c1-12)
IFACE="br-${BRIDGE}"

# Mirror all traffic to a tap interface (requires iproute2)
ip link add mon0 type dummy
ip link set mon0 up
tc qdisc add dev $IFACE ingress
tc filter add dev $IFACE parent ffff: protocol all u32 match u8 0 0 action mirred egress mirror dev mon0
```

Point your sensor at `mon0`.

---

## Option 3: Wireshark Capture for Offline Analysis

Capture OT traffic from the lab and import into tools that support PCAP analysis.

```bash
# Capture from GRFICSv3 bridge
BRIDGE=$(docker network inspect grficsv3_default --format '{{.Id}}' | cut -c1-12)
tcpdump -i br-${BRIDGE} -w /tmp/ot-lab-capture.pcap

# Filter for OT protocols
tcpdump -i br-${BRIDGE} -w /tmp/ot-protocols.pcap \
  'port 502 or port 44818 or port 102 or port 4840 or port 47808'
```

Port reference:
- `502` — Modbus TCP
- `44818` — EtherNet/IP
- `102` — S7comm (Siemens)
- `4840` — OPC UA
- `47808` — BACnet/IP
- `20000` — DNP3

---

## Generating Traffic for Detection Testing

Once the sensor is connected, generate traffic to trigger detections:

```bash
# Modbus read/write (requires mbpoll)
mbpoll -a 1 -r 1 -c 10 <plc-ip>           # Read 10 coils
mbpoll -a 1 -r 1 -t 0 -1 <plc-ip> 1       # Write coil (anomalous command)

# GRFICSv3 built-in Caldera attack scenarios
# Access Caldera UI at http://localhost:8888 (default)
# Run the "ICS Attack" adversary profile
```

---

## Vendor-Specific Notes

### Nozomi Networks Guardian
- Request a trial OVA from Nozomi
- Supports passive monitoring via SPAN/TAP
- Has a REST API for programmatic asset querying

### Claroty Edge / CTD
- Claroty offers a virtual sensor for lab use
- Integrates with Active Query for active device polling (Modbus, EtherNet/IP)

### Dragos Platform
- Requires a Dragos-provided sensor image
- Works well with GRFICSv3's realistic process simulation
- Built-in threat analytics for known ICS malware signatures (CRASHOVERRIDE, INDUSTROYER2, etc.)

### Armis
- Agentless, cloud-based analysis
- Typically deployed via network traffic feed or integration
- Strong on device fingerprinting and vulnerability correlation
