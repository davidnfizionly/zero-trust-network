#!/usr/bin/env python3
"""
Traffic simulator for the payment platform. Synthetic wallets and amounts only.

Usage:
    export API_BASE_URL=http://<ingress-host>/api
    python simulate.py setup                 # create the starting wallets
    python simulate.py background            # continuous transfers between wallets (Ctrl+C to stop)
    python simulate.py scenario velocity      # trigger the velocity abuse rule
    python simulate.py scenario spike         # trigger the amount spike rule
    python simulate.py scenario travel        # trigger the impossible travel rule
    python simulate.py scenario all           # run the three scenarios in a row
"""

import argparse
import os
import random
import sys
import time
import uuid

import requests

API_BASE_URL = os.environ.get("API_BASE_URL", "").rstrip("/")

WALLETS = [
    {"wallet_id": "alice", "owner_name": "Alice", "initial_balance": 5000},
    {"wallet_id": "bob", "owner_name": "Bob", "initial_balance": 5000},
    {"wallet_id": "charlie", "owner_name": "Charlie", "initial_balance": 3000},
]

LOCATIONS = ["Nairobi", "Kinshasa", "Kampala", "Lagos", "Dar es Salaam"]


def create_wallet(wallet_id: str, owner_name: str, initial_balance: float):
    resp = requests.post(
        f"{API_BASE_URL}/wallets",
        json={"wallet_id": wallet_id, "owner_name": owner_name, "initial_balance": initial_balance},
        timeout=10,
    )
    if resp.status_code == 201:
        print(f"[OK] Wallet created: {wallet_id} ({owner_name}, initial balance {initial_balance})")
    elif resp.status_code == 409:
        print(f"[INFO] Wallet {wallet_id} already exists, continuing")
    else:
        print(f"[WARN] Wallet {wallet_id} creation failed: {resp.status_code} {resp.text}")


def setup_wallets():
    print("Creating the starting wallets...")
    for w in WALLETS:
        create_wallet(**w)


def transfer(from_wallet: str, to_wallet: str, amount: float, location: str = "unknown"):
    idempotency_key = str(uuid.uuid4())
    resp = requests.post(
        f"{API_BASE_URL}/transfers",
        json={
            "idempotency_key": idempotency_key,
            "from_wallet": from_wallet,
            "to_wallet": to_wallet,
            "amount": amount,
            "location": location,
        },
        timeout=10,
    )
    status = "OK" if resp.status_code == 200 else "FAIL"
    print(f"[{status}] {from_wallet} -> {to_wallet}: {amount} [{location}] - HTTP {resp.status_code}")
    return resp


def run_background_traffic():
    print("Starting continuous traffic between wallets (Ctrl+C to stop)...")
    wallet_ids = [w["wallet_id"] for w in WALLETS]

    try:
        while True:
            from_wallet, to_wallet = random.sample(wallet_ids, 2)
            amount = round(random.uniform(5, 50), 2)
            location = random.choice(LOCATIONS)
            transfer(from_wallet, to_wallet, amount, location)
            time.sleep(random.uniform(1.5, 4))
    except KeyboardInterrupt:
        print("\nTraffic stopped.")


def scenario_velocity_abuse(wallet_id: str = "alice", target: str = "bob"):
    print(f"\nSCENARIO: velocity abuse on {wallet_id}")
    count = 18
    for i in range(count):
        transfer(wallet_id, target, round(random.uniform(5, 15), 2), "Nairobi")
        time.sleep(0.5)
    print(f"[OK] {count} transfers sent in a burst - check the dashboard for the alert")


def scenario_amount_spike(wallet_id: str = "alice", target: str = "bob"):
    print(f"\nSCENARIO: amount spike on {wallet_id}")
    print("Building history (small amounts)...")
    for i in range(5):
        transfer(wallet_id, target, round(random.uniform(10, 30), 2), "Nairobi")
        time.sleep(1)

    print("Sending an abnormally large amount...")
    transfer(wallet_id, target, 3000, "Nairobi")
    print("[OK] Amount spike sent - check the dashboard for the alert")


def scenario_impossible_travel(wallet_id: str = "alice", target: str = "bob"):
    print(f"\nSCENARIO: impossible travel on {wallet_id}")
    transfer(wallet_id, target, 20, "Nairobi")
    print("Transfer from Nairobi sent. Waiting 5s (well under the 90s window)...")
    time.sleep(5)
    transfer(wallet_id, target, 20, "Lagos")
    print("[OK] Transfer from Lagos sent - check the dashboard for the impossible travel alert")


def main():
    parser = argparse.ArgumentParser(description="Traffic simulator - payment platform")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("setup", help="Create the starting wallets")
    subparsers.add_parser("background", help="Run continuous traffic between wallets")

    scenario_parser = subparsers.add_parser("scenario", help="Trigger a fraud scenario")
    scenario_parser.add_argument(
        "name", choices=["velocity", "spike", "travel", "all"], help="Scenario to trigger"
    )

    args = parser.parse_args()

    if not API_BASE_URL:
        sys.exit("API_BASE_URL is not set (example: http://<ingress-host>/api)")

    if args.command == "setup":
        setup_wallets()
    elif args.command == "background":
        run_background_traffic()
    elif args.command == "scenario":
        if args.name == "velocity":
            scenario_velocity_abuse()
        elif args.name == "spike":
            scenario_amount_spike()
        elif args.name == "travel":
            scenario_impossible_travel()
        elif args.name == "all":
            scenario_velocity_abuse()
            time.sleep(3)
            scenario_amount_spike()
            time.sleep(3)
            scenario_impossible_travel()


if __name__ == "__main__":
    main()
