"""Turns AWS Network Firewall alert log entries into AWS Security Hub CSPM custom findings.

Invoked by a CloudWatch Logs subscription on the firewall alert log group. Alerts are grouped
per rule, source address and hour, so a port scan becomes one finding that is updated, not
one finding per probed port.
"""
import base64
import gzip
import hashlib
import json
import os
from datetime import datetime, timezone

import boto3

securityhub = boto3.client("securityhub")

FIREWALL_ARN = os.environ["FIREWALL_ARN"]


def _severity(action: str) -> str:
    return "MEDIUM" if action == "blocked" else "LOW"


def _finding(account: str, region: str, record: dict) -> dict:
    event = record.get("event", {})
    alert = event.get("alert", {})
    action = alert.get("action", "unknown")
    signature = alert.get("signature", "Network Firewall alert")
    if signature.startswith("aws:"):
        # Policy default action: no rule allowed this traffic.
        signature = "Default deny: no rule allows this established connection"
    sid = alert.get("signature_id", 0)
    src = event.get("src_ip", "unknown")
    dest = event.get("dest_ip", "unknown")
    dest_port = event.get("dest_port")
    proto = event.get("proto", "")
    seen = datetime.fromtimestamp(int(record.get("event_timestamp", 0)) or datetime.now().timestamp(), timezone.utc)
    seen_iso = seen.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    bucket = seen.strftime("%Y%m%d%H")
    finding_id = hashlib.sha256(f"{FIREWALL_ARN}|{sid}|{src}|{bucket}".encode()).hexdigest()

    detail = f"{proto} {src} -> {dest}" + (f":{dest_port}" if dest_port else "")
    if "tls" in event and event["tls"].get("sni"):
        detail += f", TLS SNI {event['tls']['sni']}"
    if "http" in event and event["http"].get("url"):
        detail += f", HTTP {event['http'].get('http_method', '')} {event['http']['url']}"

    return {
        "SchemaVersion": "2018-10-08",
        "Id": f"network-firewall/{finding_id}",
        "ProductArn": f"arn:aws:securityhub:{region}:{account}:product/{account}/default",
        "GeneratorId": f"network-firewall-rule-{sid}",
        "AwsAccountId": account,
        "Types": ["Unusual Behaviors/Network Flow"],
        "CreatedAt": seen_iso,
        "UpdatedAt": seen_iso,
        "FirstObservedAt": seen_iso,
        "LastObservedAt": seen_iso,
        "Severity": {"Label": _severity(action)},
        "Title": signature[:256],
        "Description": f"Network Firewall {action} traffic: {detail}"[:1024],
        "ProductFields": {
            "Source": "AWS Network Firewall alert log (custom integration)",
            "RuleSid": str(sid),
            "Action": action,
        },
        "Resources": [
            {
                "Type": "Other",
                "Id": FIREWALL_ARN,
                "Region": region,
                "Details": {"Other": {"SourceIp": src, "DestinationIp": dest, "DestinationPort": str(dest_port or "")}},
            }
        ],
        "RecordState": "ACTIVE",
        "Workflow": {"Status": "NEW"},
    }


def handler(event, context):
    payload = json.loads(gzip.decompress(base64.b64decode(event["awslogs"]["data"])))
    account = payload["owner"]
    region = context.invoked_function_arn.split(":")[3]

    findings = {}
    for log_event in payload.get("logEvents", []):
        try:
            record = json.loads(log_event["message"])
        except json.JSONDecodeError:
            continue
        if record.get("event", {}).get("event_type") != "alert":
            continue
        f = _finding(account, region, record)
        findings[f["Id"]] = f

    batch = list(findings.values())
    imported, failed = 0, 0
    for i in range(0, len(batch), 100):
        resp = securityhub.batch_import_findings(Findings=batch[i : i + 100])
        imported += resp.get("SuccessCount", 0)
        failed += resp.get("FailedCount", 0)
    print(json.dumps({"alerts": len(payload.get("logEvents", [])), "imported": imported, "failed": failed}))
    return {"imported": imported, "failed": failed}
