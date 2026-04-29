#!/usr/bin/env python3
# span-test.py — Generate Modbus traffic to verify Armis SPAN capture is working.
# Run inside the kali container:
#   docker exec kali python3 /scripts/span-test.py
# Or from the host:
#   docker exec kali python3 - < scripts/span-test.py

import sys
import time

try:
    from pymodbus.client import ModbusTcpClient
    from pymodbus.exceptions import ModbusException
except ImportError:
    print("ERROR: pymodbus not installed")
    sys.exit(1)

TARGET = "192.168.95.2"
PORT   = 502
SLAVE  = 1

PASS = "\033[32m✓\033[0m"
FAIL = "\033[31m✗\033[0m"
INFO = "\033[36m·\033[0m"

def banner(title):
    print(f"\n── {title} {'─' * (50 - len(title))}")

def result(label, resp):
    if resp is None or resp.isError():
        print(f"  {FAIL}  {label}: {resp}")
        return False
    print(f"  {PASS}  {label}: {resp.registers if hasattr(resp, 'registers') else resp.bits if hasattr(resp, 'bits') else 'ok'}")
    return True


def reconnect(c):
    """Re-establish connection after the PLC closes it following an exception response."""
    c.close()
    time.sleep(0.2)
    if not c.connect():
        print(f"  {FAIL}  reconnect failed")
        return False
    return True


def run_tests(c):
    passed = failed = 0

    # ── Function Code 01 — Read Coils ────────────────────────────────────────
    banner("FC01 Read Coils")
    for addr in [0, 8, 16]:
        r = c.read_coils(addr, count=8, slave=SLAVE)
        if result(f"coils @ {addr}", r): passed += 1
        else: failed += 1

    # ── Function Code 02 — Read Discrete Inputs ──────────────────────────────
    banner("FC02 Read Discrete Inputs")
    for addr in [0, 8]:
        r = c.read_discrete_inputs(addr, count=8, slave=SLAVE)
        if result(f"discrete @ {addr}", r): passed += 1
        else: failed += 1

    # ── Function Code 03 — Read Holding Registers ────────────────────────────
    banner("FC03 Read Holding Registers")
    for addr, count in [(0, 10), (10, 10), (100, 5)]:
        r = c.read_holding_registers(addr, count=count, slave=SLAVE)
        if result(f"holding @ {addr} count={count}", r): passed += 1
        else: failed += 1

    # ── Function Code 04 — Read Input Registers ──────────────────────────────
    banner("FC04 Read Input Registers")
    for addr in [0, 10]:
        r = c.read_input_registers(addr, count=10, slave=SLAVE)
        if result(f"input @ {addr}", r): passed += 1
        else: failed += 1

    # ── Function Code 05 — Write Single Coil ─────────────────────────────────
    banner("FC05 Write Single Coil")
    for val in [True, False]:
        r = c.write_coil(0, val, slave=SLAVE)
        if result(f"write coil 0 = {val}", r): passed += 1
        else: failed += 1

    # ── Function Code 06 — Write Single Register ──────────────────────────────
    banner("FC06 Write Single Register")
    for val in [0x1234, 0xFFFF, 0x0001]:
        r = c.write_register(0, val, slave=SLAVE)
        ok = result(f"write reg 0 = 0x{val:04X}", r)
        if ok: passed += 1
        else:
            failed += 1
            reconnect(c)  # PLC exception response closes the TCP connection

    # ── Function Code 15 — Write Multiple Coils ──────────────────────────────
    banner("FC15 Write Multiple Coils")
    r = c.write_coils(0, [True, False, True, False, True, False, True, False], slave=SLAVE)
    if result("write 8 coils @ 0", r): passed += 1
    else: failed += 1

    # ── Function Code 16 — Write Multiple Registers ───────────────────────────
    banner("FC16 Write Multiple Registers")
    r = c.write_registers(0, [0x0001, 0x0002, 0x0003, 0x0004], slave=SLAVE)
    if result("write 4 regs @ 0", r): passed += 1
    else: failed += 1

    # ── Sustained burst — 30 rapid polls (mimics PLC scan cycle) ─────────────
    banner("Sustained Poll Burst (30 cycles)")
    print(f"  {INFO}  polling holding registers @ 0 every 100ms...")
    reconnect(c)  # start burst on a fresh connection
    burst_ok = 0
    for i in range(30):
        try:
            r = c.read_holding_registers(0, count=10, slave=SLAVE)
            if not r.isError():
                burst_ok += 1
            else:
                reconnect(c)
        except Exception:
            reconnect(c)
        time.sleep(0.1)
    label = f"burst: {burst_ok}/30 ok"
    if burst_ok == 30:
        print(f"  {PASS}  {label}")
        passed += 1
    else:
        print(f"  {FAIL}  {label}")
        failed += 1

    return passed, failed


def main():
    print(f"Armis SPAN Test — Modbus target {TARGET}:{PORT} slave={SLAVE}")
    print("Generating traffic across multiple Modbus function codes...\n")

    c = ModbusTcpClient(TARGET, port=PORT, timeout=3)
    if not c.connect():
        print(f"ERROR: cannot connect to {TARGET}:{PORT}")
        sys.exit(1)
    print(f"{PASS} Connected to {TARGET}:{PORT}")

    try:
        passed, failed = run_tests(c)
    finally:
        c.close()

    total = passed + failed
    print(f"\n{'═' * 55}")
    print(f"  Results: {passed}/{total} passed", end="")
    if failed:
        print(f"  ({failed} failed — PLC may not support those FCs)")
    else:
        print()
    print(f"{'═' * 55}")
    print("\nCheck Armis collector → Span Statistics for rising unicast count.")
    print("Devices should appear in the portal within 1–2 minutes.")


if __name__ == "__main__":
    main()
