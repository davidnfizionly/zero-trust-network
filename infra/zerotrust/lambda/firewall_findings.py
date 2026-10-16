"""Turns blocked AWS Network Firewall alerts into Security Hub CSPM custom findings.

Network Firewall has no native Security Hub integration. This function receives the alert log
events that a subscription filter selects (action "blocked") and imports one finding per
rule, source address, destination port and day, so a port scan updates a bounded set of
findings instead of creating one per packet.
"""

import base64
import gzip
import json
import os
from datetime import datetime, timezone

import boto3

securityhub = boto3.client("securityhub")
FIREWALL_ARN = os.environ["FIREWALL_ARN"]


def _finding(event, account_id, region, now):
    alert = event["event"]["alert"]
    src = event["event"].get("src_ip", "unknown")
    dest_port = event["event"].get("dest_port", 0)
    proto = event["event"].get("proto", "")
    day = now[:10]
    finding_id = f"nfw/{alert['signature_id']}/{src}/{dest_port}/{day}"
    return {
        "SchemaVersion": "2018-10-08",
        "Id": finding_id,
        "ProductArn": f"arn:aws:securityhub:{region}:{account_id}:product/{account_id}/default",
        "GeneratorId": f"network-firewall-sid-{alert['signature_id']}",
        "AwsAccountId": account_id,
        "Types": ["Unusual Behaviors/Network Flow"],
        "CreatedAt": now,
        "UpdatedAt": now,
        "Severity": {"Label": "MEDIUM"},
        "Title": alert.get("signature", "Network Firewall blocked traffic")[:256],
        "Description": (
            f"AWS Network Firewall blocked {proto} traffic from {src} to port {dest_port}. "
            f"Rule: {alert.get('signature', '')}"
        )[:1024],
        "Resources": [{"Type": "Other", "Id": FIREWALL_ARN, "Region": region}],
        "ProductFields": {"Source": "network-firewall-alert-log"},
        "RecordState": "ACTIVE",
        "Workflow": {"Status": "NEW"},
    }


def handler(event, context):
    payload = json.loads(gzip.decompress(base64.b64decode(event["awslogs"]["data"])))
    region = context.invoked_function_arn.split(":")[3]
    account_id = context.invoked_function_arn.split(":")[4]
    now = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

    findings = {}
    for log_event in payload.get("logEvents", []):
        record = json.loads(log_event["message"])
        finding = _finding(record, account_id, region, now)
        findings[finding["Id"]] = finding

    batch = list(findings.values())
    for i in range(0, len(batch), 100):
        result = securityhub.batch_import_findings(Findings=batch[i : i + 100])
        if result.get("FailedCount"):
            print(json.dumps({"failed": result["FailedFindings"]}))
    return {"imported": len(batch)}
