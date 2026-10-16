#!/usr/bin/env python3
"""TCP connect scan of this project's own public endpoints, run from outside the VPC.

Usage: port_scan.py <host> [<host> ...]
Scans ports 1-1024 plus the ports the platform is known to use (Istio, kubelet, NodePort
samples). A port is reported open only when the TCP handshake completes. Every port that
does not answer in the first pass is probed a second time, and a port counts as open if either
pass completes the handshake: too many parallel connections from one machine can make a
listening port look closed, never the reverse.
"""
import asyncio
import socket
import sys
import time

EXTRA_PORTS = [1433, 2379, 2380, 3000, 3306, 5432, 6379, 6443, 8000, 8080, 8443, 9090,
               9443, 10250, 10255, 15017, 15021, 15443, 20001, 31400, 30000, 32767]
PORTS = sorted(set(range(1, 1025)) | set(EXTRA_PORTS))
TIMEOUT = 3.0
CONCURRENCY = 64


async def probe(ip: str, port: int, sem: asyncio.Semaphore) -> bool:
    async with sem:
        try:
            _, writer = await asyncio.wait_for(asyncio.open_connection(ip, port), TIMEOUT)
            writer.close()
            return True
        except Exception:
            return False


async def scan(ip: str) -> list[int]:
    sem = asyncio.Semaphore(CONCURRENCY)
    first = await asyncio.gather(*(probe(ip, p, sem) for p in PORTS))
    open_ports = {p for p, ok in zip(PORTS, first) if ok}
    retry = [p for p in PORTS if p not in open_ports]
    second = await asyncio.gather(*(probe(ip, p, sem) for p in retry))
    open_ports |= {p for p, ok in zip(retry, second) if ok}
    return sorted(open_ports)


def main() -> None:
    hosts = sys.argv[1:]
    if not hosts:
        sys.exit("usage: port_scan.py <host> [<host> ...]")
    print(f"scan started {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime())} UTC, "
          f"{len(PORTS)} TCP ports per address, connect timeout {TIMEOUT}s, {CONCURRENCY} parallel probes, "
          f"two passes")
    scanned: dict[str, str] = {}
    for host in hosts:
        try:
            ips = sorted({ai[4][0] for ai in socket.getaddrinfo(host, None, socket.AF_INET)})
        except socket.gaierror as exc:
            print(f"{host}: does not resolve ({exc})")
            continue
        for ip in ips:
            if ip in scanned:
                print(f"{host} ({ip}): already scanned as {scanned[ip]}")
                continue
            scanned[ip] = host
            open_ports = asyncio.run(scan(ip))
            shown = ", ".join(map(str, open_ports)) if open_ports else "none"
            print(f"{host} ({ip}): open TCP ports: {shown}")
    print(f"scan finished {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime())} UTC")


if __name__ == "__main__":
    main()
