import os
import json
import time
import logging
import threading

import boto3
from fastapi import FastAPI

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("notification-service")

app = FastAPI(title="Notification Service", version="1.0.0")

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
NOTIFICATION_QUEUE_URL = os.getenv("NOTIFICATION_QUEUE_URL")

sqs = boto3.client("sqs", region_name=AWS_REGION)

_notifications_sent = 0
_lock = threading.Lock()


def _simulate_send_notification(event_detail: dict, detail_type: str):
    global _notifications_sent

    if detail_type == "TransactionConfirmed":
        message = (
            f"Transfer confirmed: {event_detail.get('amount')} from "
            f"{event_detail.get('from_wallet')} to {event_detail.get('to_wallet')} "
            f"(transaction {event_detail.get('transaction_id')})"
        )
    elif detail_type == "FraudAlertRaised":
        message = (
            f"Fraud alert [{event_detail.get('rule')}] on wallet "
            f"{event_detail.get('wallet_id')} : {event_detail.get('details')}"
        )
    else:
        message = f"Event received: {detail_type} - {event_detail}"

    logger.info(f"NOTIFICATION SENT: {message}")

    with _lock:
        _notifications_sent += 1


def _poll_queue_loop():
    if not NOTIFICATION_QUEUE_URL:
        logger.error("NOTIFICATION_QUEUE_URL not set - polling loop will not start")
        return

    logger.info("Starting SQS polling loop for notifications...")

    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=NOTIFICATION_QUEUE_URL,
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
                detail = body.get("detail", {})
                if isinstance(detail, str):
                    detail = json.loads(detail)

                _simulate_send_notification(detail, detail_type)

                sqs.delete_message(
                    QueueUrl=NOTIFICATION_QUEUE_URL,
                    ReceiptHandle=message["ReceiptHandle"],
                )
            except Exception as e:
                logger.error(f"Error processing message: {e}")


@app.on_event("startup")
def start_polling_thread():
    thread = threading.Thread(target=_poll_queue_loop, daemon=True)
    thread.start()


@app.get("/health")
def health():
    return {"status": "ok", "service": "notification-service"}


@app.get("/stats")
def stats():
    return {"notifications_sent": _notifications_sent}
