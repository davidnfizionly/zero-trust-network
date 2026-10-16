import os
import time
import uuid
import logging
import threading
from decimal import Decimal
from collections import defaultdict, deque

import boto3
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fraud-detection-service")

app = FastAPI(title="Fraud Detection Service", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
TRANSACTIONS_TABLE = os.getenv("TRANSACTIONS_TABLE", "payment-platform-transactions")
FRAUD_EVENTS_TABLE = os.getenv("FRAUD_EVENTS_TABLE", "payment-platform-fraud-events")
EVENT_BUS_NAME = os.getenv("EVENT_BUS_NAME", "payment-platform-events")
POLL_INTERVAL_SECONDS = float(os.getenv("POLL_INTERVAL_SECONDS", "2"))

VELOCITY_WINDOW_SECONDS = 30
VELOCITY_THRESHOLD = 15
AMOUNT_SPIKE_MULTIPLIER = 20
IMPOSSIBLE_TRAVEL_WINDOW_SECONDS = 90

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
transactions_table = dynamodb.Table(TRANSACTIONS_TABLE)
fraud_events_table = dynamodb.Table(FRAUD_EVENTS_TABLE)
events_client = boto3.client("events", region_name=AWS_REGION)
dynamodb_streams = boto3.client("dynamodbstreams", region_name=AWS_REGION)

wallet_history = defaultdict(lambda: deque(maxlen=50))
_processed_records = set()


def _publish_fraud_event(rule: str, wallet_id: str, transaction_id: str, details: str):
    event_id = str(uuid.uuid4())
    timestamp = int(time.time())

    fraud_events_table.put_item(
        Item={
            "event_id": event_id,
            "rule": rule,
            "wallet_id": wallet_id,
            "transaction_id": transaction_id,
            "details": details,
            "timestamp": timestamp,
        }
    )

    try:
        events_client.put_events(
            Entries=[
                {
                    "Source": "payment.fraud",
                    "DetailType": "FraudAlertRaised",
                    "Detail": (
                        f'{{"event_id": "{event_id}", "rule": "{rule}", '
                        f'"wallet_id": "{wallet_id}", "transaction_id": "{transaction_id}", '
                        f'"details": "{details}"}}'
                    ),
                    "EventBusName": EVENT_BUS_NAME,
                }
            ]
        )
    except Exception as e:
        logger.warning(f"Failed to publish fraud event to EventBridge (non-blocking): {e}")

    logger.warning(f"FRAUD ALERT [{rule}] wallet={wallet_id} txn={transaction_id} - {details}")


def _check_velocity(wallet_id: str, now: float):
    recent = [t for t in wallet_history[wallet_id] if now - t["ts"] <= VELOCITY_WINDOW_SECONDS]
    if len(recent) >= VELOCITY_THRESHOLD:
        return f"{len(recent)} transactions in {VELOCITY_WINDOW_SECONDS}s (threshold: {VELOCITY_THRESHOLD})"
    return None


def _check_amount_spike(wallet_id: str, amount: Decimal):
    history = [t["amount"] for t in wallet_history[wallet_id] if t["amount"] > 0]
    if len(history) < 3:
        return None
    avg = sum(history) / len(history)
    if avg > 0 and amount > avg * AMOUNT_SPIKE_MULTIPLIER:
        return f"Amount {amount} vs recent average {avg:.2f} (x{AMOUNT_SPIKE_MULTIPLIER}+ )"
    return None


def _check_impossible_travel(wallet_id: str, location: str, now: float):
    recent = [t for t in wallet_history[wallet_id] if now - t["ts"] <= IMPOSSIBLE_TRAVEL_WINDOW_SECONDS]
    for t in recent:
        if t["location"] != "unknown" and location != "unknown" and t["location"] != location:
            delta = now - t["ts"]
            return f"Transaction from '{t['location']}' {delta:.0f}s ago, then from '{location}' now"
    return None


def _evaluate_transaction(item: dict):
    wallet_id = item.get("from_wallet")
    transaction_id = item.get("transaction_id")
    amount = Decimal(str(item.get("amount", 0)))
    location = item.get("location", "unknown")
    now = time.time()

    if not wallet_id or not transaction_id:
        return

    velocity_alert = _check_velocity(wallet_id, now)
    if velocity_alert:
        _publish_fraud_event("velocity_abuse", wallet_id, transaction_id, velocity_alert)

    amount_alert = _check_amount_spike(wallet_id, amount)
    if amount_alert:
        _publish_fraud_event("amount_spike", wallet_id, transaction_id, amount_alert)

    travel_alert = _check_impossible_travel(wallet_id, location, now)
    if travel_alert:
        _publish_fraud_event("impossible_travel", wallet_id, transaction_id, travel_alert)

    wallet_history[wallet_id].append({"ts": now, "amount": amount, "location": location})


def _poll_stream_loop():
    logger.info("Starting DynamoDB Stream polling loop...")

    table_desc = dynamodb.meta.client.describe_table(TableName=TRANSACTIONS_TABLE)
    stream_arn = table_desc["Table"]["LatestStreamArn"]

    stream_desc = dynamodb_streams.describe_stream(StreamArn=stream_arn)
    shard_iterators = {}
    for shard in stream_desc["StreamDescription"]["Shards"]:
        it = dynamodb_streams.get_shard_iterator(
            StreamArn=stream_arn,
            ShardId=shard["ShardId"],
            ShardIteratorType="LATEST",
        )
        shard_iterators[shard["ShardId"]] = it["ShardIterator"]

    while True:
        for shard_id, iterator in list(shard_iterators.items()):
            if iterator is None:
                continue
            try:
                response = dynamodb_streams.get_records(ShardIterator=iterator, Limit=50)
            except Exception as e:
                logger.error(f"Error polling shard {shard_id}: {e}")
                continue

            for record in response.get("Records", []):
                record_id = record["eventID"]
                if record_id in _processed_records:
                    continue
                _processed_records.add(record_id)

                if record["eventName"] in ("INSERT", "MODIFY"):
                    new_image = record["dynamodb"].get("NewImage", {})
                    status = new_image.get("status", {}).get("S")
                    if status == "CONFIRMED":
                        item = {
                            "transaction_id": new_image.get("transaction_id", {}).get("S"),
                            "from_wallet": new_image.get("from_wallet", {}).get("S"),
                            "amount": new_image.get("amount", {}).get("N", "0"),
                            "location": new_image.get("location", {}).get("S", "unknown"),
                        }
                        _evaluate_transaction(item)

            shard_iterators[shard_id] = response.get("NextShardIterator")

        if len(_processed_records) > 5000:
            _processed_records.clear()

        time.sleep(POLL_INTERVAL_SECONDS)


@app.on_event("startup")
def start_polling_thread():
    thread = threading.Thread(target=_poll_stream_loop, daemon=True)
    thread.start()


@app.get("/health")
def health():
    return {"status": "ok", "service": "fraud-detection-service"}


@app.get("/stats")
def stats():
    return {
        "wallets_tracked": len(wallet_history),
        "records_processed": len(_processed_records),
    }


@app.get("/fraud-events")
def list_fraud_events(limit: int = 50):
    """Lists the most recent fraud alerts, used by the dashboard."""
    response = fraud_events_table.scan(Limit=limit)
    items = response.get("Items", [])
    items.sort(key=lambda x: x.get("timestamp", 0), reverse=True)
    return {"fraud_events": items[:limit]}
