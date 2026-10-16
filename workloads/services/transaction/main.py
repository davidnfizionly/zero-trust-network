import os
import uuid
import logging
import time
from decimal import Decimal
from typing import Optional

import boto3
import httpx
from botocore.exceptions import ClientError
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("transaction-service")

app = FastAPI(title="Transaction Service", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
TRANSACTIONS_TABLE = os.getenv("TRANSACTIONS_TABLE", "payment-platform-transactions")
EVENT_BUS_NAME = os.getenv("EVENT_BUS_NAME", "payment-platform-events")
WALLET_SERVICE_URL = os.getenv("WALLET_SERVICE_URL", "http://wallet-service:8000")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
transactions_table = dynamodb.Table(TRANSACTIONS_TABLE)
events_client = boto3.client("events", region_name=AWS_REGION)


class TransferRequest(BaseModel):
    idempotency_key: str = Field(..., description="Client-generated key, unique per transfer intent")
    from_wallet: str
    to_wallet: str
    amount: Decimal = Field(gt=0)
    location: str = "unknown"


class TransferResponse(BaseModel):
    transaction_id: str
    idempotency_key: str
    from_wallet: str
    to_wallet: str
    amount: Decimal
    status: str
    replayed: bool = False


@app.get("/health")
def health():
    return {"status": "ok", "service": "transaction-service"}


def _publish_event(detail_type: str, source: str, detail: dict):
    try:
        events_client.put_events(
            Entries=[
                {
                    "Source": source,
                    "DetailType": detail_type,
                    "Detail": str(detail).replace("'", '"'),
                    "EventBusName": EVENT_BUS_NAME,
                }
            ]
        )
    except Exception as e:
        logger.warning(f"Failed to publish event {detail_type} (non-blocking): {e}")


def _find_existing_by_idempotency_key(idempotency_key: str) -> Optional[dict]:
    response = transactions_table.query(
        IndexName="idempotency_key-index",
        KeyConditionExpression="idempotency_key = :key",
        ExpressionAttributeValues={":key": idempotency_key},
    )
    items = response.get("Items", [])
    return items[0] if items else None


@app.post("/transfers", response_model=TransferResponse)
def create_transfer(request: TransferRequest):
    existing = _find_existing_by_idempotency_key(request.idempotency_key)
    if existing:
        logger.info(f"Idempotency key {request.idempotency_key} already processed - replaying result")
        return TransferResponse(
            transaction_id=existing["transaction_id"],
            idempotency_key=existing["idempotency_key"],
            from_wallet=existing["from_wallet"],
            to_wallet=existing["to_wallet"],
            amount=existing["amount"],
            status=existing["status"],
            replayed=True,
        )

    transaction_id = str(uuid.uuid4())

    transactions_table.put_item(
        Item={
            "transaction_id": transaction_id,
            "idempotency_key": request.idempotency_key,
            "from_wallet": request.from_wallet,
            "to_wallet": request.to_wallet,
            "amount": request.amount,
            "location": request.location,
            "status": "PENDING",
            "created_at": int(time.time()),
        }
    )

    with httpx.Client(timeout=10.0) as client:
        try:
            debit_resp = client.post(
                f"{WALLET_SERVICE_URL}/wallets/{request.from_wallet}/debit",
                json={"amount": str(request.amount), "transaction_id": transaction_id},
            )
            debit_resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            _mark_failed(transaction_id, reason="debit_failed")
            detail = "Insufficient balance" if e.response.status_code == 422 else "Debit failed"
            raise HTTPException(status_code=422, detail=detail)
        except httpx.RequestError as e:
            logger.error(f"Network error during debit: {e}")
            _mark_failed(transaction_id, reason="debit_network_error")
            raise HTTPException(status_code=503, detail="Wallet service unavailable during debit")

        try:
            credit_resp = client.post(
                f"{WALLET_SERVICE_URL}/wallets/{request.to_wallet}/credit",
                json={"amount": str(request.amount), "transaction_id": transaction_id},
            )
            credit_resp.raise_for_status()
        except (httpx.HTTPStatusError, httpx.RequestError) as e:
            logger.error(f"Credit step failed, compensating debit: {e}")
            try:
                client.post(
                    f"{WALLET_SERVICE_URL}/wallets/{request.from_wallet}/credit",
                    json={"amount": str(request.amount), "transaction_id": transaction_id},
                )
                _mark_status(transaction_id, "COMPENSATED")
            except httpx.RequestError as compensation_error:
                logger.critical(
                    f"COMPENSATION FAILED for transaction {transaction_id}: {compensation_error}"
                )
                _mark_status(transaction_id, "COMPENSATION_FAILED")
            raise HTTPException(status_code=502, detail="Transfer failed, compensating transaction applied")

    _mark_status(transaction_id, "CONFIRMED")
    _publish_event(
        detail_type="TransactionConfirmed",
        source="payment.transaction",
        detail={
            "transaction_id": transaction_id,
            "from_wallet": request.from_wallet,
            "to_wallet": request.to_wallet,
            "amount": str(request.amount),
        },
    )

    return TransferResponse(
        transaction_id=transaction_id,
        idempotency_key=request.idempotency_key,
        from_wallet=request.from_wallet,
        to_wallet=request.to_wallet,
        amount=request.amount,
        status="CONFIRMED",
        replayed=False,
    )


@app.get("/transfers/{transaction_id}", response_model=TransferResponse)
def get_transfer(transaction_id: str):
    response = transactions_table.get_item(Key={"transaction_id": transaction_id})
    item = response.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Transaction not found")
    return TransferResponse(
        transaction_id=item["transaction_id"],
        idempotency_key=item["idempotency_key"],
        from_wallet=item["from_wallet"],
        to_wallet=item["to_wallet"],
        amount=item["amount"],
        status=item["status"],
        replayed=False,
    )


def _mark_status(transaction_id: str, status: str):
    transactions_table.update_item(
        Key={"transaction_id": transaction_id},
        UpdateExpression="SET #s = :status",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":status": status},
    )


def _mark_failed(transaction_id: str, reason: str):
    transactions_table.update_item(
        Key={"transaction_id": transaction_id},
        UpdateExpression="SET #s = :status, failure_reason = :reason",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":status": "FAILED", ":reason": reason},
    )


@app.get("/transfers")
def list_transfers(limit: int = 50):
    """Lists the most recent transfers, used by the dashboard live feed."""
    response = transactions_table.scan(Limit=limit)
    items = response.get("Items", [])
    items.sort(key=lambda x: x.get("created_at", 0), reverse=True)
    return {"transfers": items[:limit]}
