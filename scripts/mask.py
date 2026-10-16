#!/usr/bin/env python3
"""Masks account-identifying values in text read from stdin, before it is saved under proof/.

Each distinct value gets a stable label within one run (sg-1, public-ip-2, ...), so the
relationships in the output stay readable. Private RFC 1918 addresses are kept.
"""
import ipaddress
import re
import sys

labels: dict[str, str] = {}
counters: dict[str, int] = {}


def label(kind: str, value: str) -> str:
    if value not in labels:
        counters[kind] = counters.get(kind, 0) + 1
        labels[value] = f"{kind}-{counters[kind]}"
    return labels[value]


def mask_ip(m: re.Match) -> str:
    ip = m.group(0)
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    if addr.is_private or addr.is_loopback or addr.is_unspecified or ip.startswith("0."):
        return ip
    return label("public-ip", ip)


RULES = [
    (re.compile(r"arn:aws[a-z-]*:[^\s\"',]+"), lambda m: label("arn", m.group(0))),
    (re.compile(r"[A-Za-z0-9-]+\.[a-z0-9]+\.[a-z0-9-]+\.eks\.amazonaws\.com"), lambda m: label("eks-endpoint", m.group(0)) + ".eks.amazonaws.com"),
    (re.compile(r"[A-Za-z0-9-]+\.(?:[a-z0-9-]+\.)?elb\.(?:[a-z0-9-]+\.)?amazonaws\.com"), lambda m: label("lb", m.group(0)) + ".elb.amazonaws.com"),
    (re.compile(r"ec2-\d+-\d+-\d+-\d+\.[a-z0-9.-]*amazonaws\.com"), lambda m: label("public-dns", m.group(0))),
    (re.compile(r"\b(vpc|subnet|sg|eni|igw|nat|rtb|vpce|eipalloc|eipassoc|acl|i|fw|lt|sgr|pl)-[0-9a-f]{8,17}\b"), lambda m: label(m.group(1), m.group(0))),
    (re.compile(r"(?<![0-9A-Za-z])\d{12}(?![0-9A-Za-z])"), lambda m: "<account-id>"),
    (re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"), mask_ip),
]

text = sys.stdin.read()
for pattern, repl in RULES:
    text = pattern.sub(repl, text)
sys.stdout.write(text)
