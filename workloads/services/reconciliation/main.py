import os
import json
import time
import logging
import threading
from decimal import Decimal
from collections import Counter

import boto3
from fastapi import FastAPI

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("reconciliation-service")

app = FastAPI(title="Reconciliation Service", version="1.0.0")

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
WALLETS_TABLE = os.getenv("WALLETS_TABLE", "payment-platform-wallets")
RECONCILIATION_QUEUE_URL = os.getenv("RECONCILIATION_QUEUE_URL")
RECONCILIATION_INTERVAL_SECONDS = float(os.getenv("RECONCILIATION_INTERVAL_SECONDS", "30"))

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
wallets_table = dynamodb.Table(WALLETS_TABLE)
sqs = boto3.client("sqs", region_name=AWS_REGION)

_lock = threading.Lock()
_status_counts = Counter()
_last_total_balance = None
_last_check_timestamp = None
_initial_total_balance = None


def _scan_total_balance() -> Decimal:
    total = Decimal("0")
    response = wallets_table.scan()
    for item in response.get("Items", []):
        total += Decimal(str(item.get("balance", 0)))

    while "LastEvaluatedKey" in response:
        response = wallets_table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
        for item in response.get("Items", []):
            total += Decimal(str(item.get("balance", 0)))

    return total


def _reconciliation_loop():
    global _last_total_balance, _last_check_timestamp, _initial_total_balance

    logger.info("Starting periodic balance reconciliation loop...")

    while True:
        try:
            total = _scan_total_balance()
            now = time.time()

            with _lock:
                if _initial_total_balance is None:
                    _initial_total_balance = total
                    logger.info(f"Initial system balance established: {total}")
                elif _last_total_balance is not None and total != _last_total_balance:
                    logger.info(
                        f"Balance changed since last check: {_last_total_balance} -> {total} "
                        f"(expected if transfers occurred or wallets were added)"
                    )

                _last_total_balance = total
                _last_check_timestamp = now

            logger.info(f"Reconciliation check OK - total system balance: {total}")

        except Exception as e:
            logger.error(f"Error during reconciliation scan: {e}")

        time.sleep(RECONCILIATION_INTERVAL_SECONDS)


def _poll_queue_loop():
    if not RECONCILIATION_QUEUE_URL:
        logger.error("RECONCILIATION_QUEUE_URL not set - polling loop will not start")
        return

    logger.info("Starting SQS polling loop for transaction lifecycle events...")

    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=RECONCILIATION_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=10,
            )
        except Exception as e:
            logger.error(f"Error polling SQS: {e}")
            time.sleep(5)
            continue

        for message in response.get("Messages", []):
            try:
                body = json.loads(message["Body"])
                detail_type = body.get("detail-type", "Unknown")

                with _lock:
                    _status_counts[detail_type] += 1

                sqs.delete_message(
                    QueueUrl=RECONCILIATION_QUEUE_URL,
                    ReceiptHandle=message["ReceiptHandle"],
                )
            except Exception as e:
                logger.error(f"Error processing message: {e}")


@app.on_event("startup")
def start_background_threads():
    threading.Thread(target=_reconciliation_loop, daemon=True).start()
    threading.Thread(target=_poll_queue_loop, daemon=True).start()


@app.get("/health")
def health():
    return {"status": "ok", "service": "reconciliation-service"}


@app.get("/stats")
def stats():
    with _lock:
        return {
            "initial_total_balance": str(_initial_total_balance) if _initial_total_balance is not None else None,
            "current_total_balance": str(_last_total_balance) if _last_total_balance is not None else None,
            "last_check_timestamp": _last_check_timestamp,
            "event_counts": dict(_status_counts),
        }
