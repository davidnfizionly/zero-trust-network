import os
import logging
from decimal import Decimal
from typing import Optional

import boto3
from botocore.exceptions import ClientError
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("wallet-service")

app = FastAPI(title="Wallet Service", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
WALLETS_TABLE = os.getenv("WALLETS_TABLE", "payment-platform-wallets")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
wallets_table = dynamodb.Table(WALLETS_TABLE)


class WalletCreate(BaseModel):
    wallet_id: str
    owner_name: str
    initial_balance: Decimal = Field(default=Decimal("0"), ge=0)


class WalletResponse(BaseModel):
    wallet_id: str
    owner_name: str
    balance: Decimal


class AdjustBalanceRequest(BaseModel):
    amount: Decimal = Field(gt=0, description="Strictly positive amount")
    transaction_id: Optional[str] = None


@app.get("/health")
def health():
    return {"status": "ok", "service": "wallet-service"}


@app.post("/wallets", response_model=WalletResponse, status_code=201)
def create_wallet(wallet: WalletCreate):
    try:
        wallets_table.put_item(
            Item={
                "wallet_id": wallet.wallet_id,
                "owner_name": wallet.owner_name,
                "balance": wallet.initial_balance,
            },
            ConditionExpression="attribute_not_exists(wallet_id)",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise HTTPException(status_code=409, detail="Wallet already exists")
        logger.error(f"Error creating wallet: {e}")
        raise HTTPException(status_code=500, detail="Internal error creating wallet")

    return WalletResponse(
        wallet_id=wallet.wallet_id,
        owner_name=wallet.owner_name,
        balance=wallet.initial_balance,
    )


@app.get("/wallets/{wallet_id}", response_model=WalletResponse)
def get_wallet(wallet_id: str):
    response = wallets_table.get_item(Key={"wallet_id": wallet_id})
    item = response.get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Wallet not found")
    return WalletResponse(
        wallet_id=item["wallet_id"],
        owner_name=item["owner_name"],
        balance=item["balance"],
    )


@app.post("/wallets/{wallet_id}/debit", response_model=WalletResponse)
def debit_wallet(wallet_id: str, request: AdjustBalanceRequest):
    try:
        response = wallets_table.update_item(
            Key={"wallet_id": wallet_id},
            UpdateExpression="SET balance = balance - :amount",
            ConditionExpression="attribute_exists(wallet_id) AND balance >= :amount",
            ExpressionAttributeValues={":amount": request.amount},
            ReturnValues="ALL_NEW",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise HTTPException(
                status_code=422,
                detail="Insufficient balance or wallet does not exist",
            )
        logger.error(f"Error debiting wallet {wallet_id}: {e}")
        raise HTTPException(status_code=500, detail="Internal error debiting wallet")

    item = response["Attributes"]
    logger.info(
        f"Debited {request.amount} from {wallet_id} "
        f"(transaction_id={request.transaction_id})"
    )
    return WalletResponse(
        wallet_id=item["wallet_id"],
        owner_name=item["owner_name"],
        balance=item["balance"],
    )


@app.post("/wallets/{wallet_id}/credit", response_model=WalletResponse)
def credit_wallet(wallet_id: str, request: AdjustBalanceRequest):
    try:
        response = wallets_table.update_item(
            Key={"wallet_id": wallet_id},
            UpdateExpression="SET balance = balance + :amount",
            ConditionExpression="attribute_exists(wallet_id)",
            ExpressionAttributeValues={":amount": request.amount},
            ReturnValues="ALL_NEW",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise HTTPException(status_code=404, detail="Wallet not found")
        logger.error(f"Error crediting wallet {wallet_id}: {e}")
        raise HTTPException(status_code=500, detail="Internal error crediting wallet")

    item = response["Attributes"]
    logger.info(
        f"Credited {request.amount} to {wallet_id} "
        f"(transaction_id={request.transaction_id})"
    )
    return WalletResponse(
        wallet_id=item["wallet_id"],
        owner_name=item["owner_name"],
        balance=item["balance"],
    )


@app.get("/wallets")
def list_wallets():
    """Lists all wallets, used for the balance overview in the dashboard."""
    response = wallets_table.scan()
    return {"wallets": response.get("Items", [])}
