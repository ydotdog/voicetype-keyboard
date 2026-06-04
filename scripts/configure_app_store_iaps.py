#!/usr/bin/env python3
"""Configure VoiceType consumable IAPs through App Store Connect API.

The script intentionally keeps credentials outside the repo. It reads an
App Store Connect API private key from disk and is dry-run by default.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import os
import re
import sys
import time
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any

import httpx
import jwt


API_BASE = "https://api.appstoreconnect.apple.com"
DEFAULT_APP_ID = "6776679139"
USA_TERRITORY_ID = "USA"


@dataclass(frozen=True)
class CreditProduct:
    key: str
    product_id: str
    reference_name: str
    display_name: str
    description: str
    target_customer_price: Decimal


PRODUCTS = [
    CreditProduct(
        key="small",
        product_id="com.kyleqi.voicetype.credits.small",
        reference_name="1 Credit",
        display_name="$1 Credit",
        description="Non-expiring VoiceType credit.",
        target_customer_price=Decimal("0.99"),
    ),
    CreditProduct(
        key="medium",
        product_id="com.kyleqi.voicetype.credits.medium",
        reference_name="5 Credit",
        display_name="$5 Credit",
        description="Non-expiring VoiceType credit.",
        target_customer_price=Decimal("4.99"),
    ),
    CreditProduct(
        key="large",
        product_id="com.kyleqi.voicetype.credits.large",
        reference_name="20 Credit",
        display_name="$20 Credit",
        description="Non-expiring VoiceType credit.",
        target_customer_price=Decimal("19.99"),
    ),
]


class AppStoreConnectError(RuntimeError):
    pass


class AppStoreConnectClient:
    def __init__(
        self,
        *,
        key_id: str,
        issuer_id: str,
        private_key_path: Path,
        dry_run: bool,
    ) -> None:
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key = private_key_path.read_text()
        self.dry_run = dry_run
        self.http = httpx.Client(timeout=45.0)

    def close(self) -> None:
        self.http.close()

    def _token(self) -> str:
        now = int(time.time())
        return jwt.encode(
            {
                "iss": self.issuer_id,
                "iat": now,
                "exp": now + 20 * 60,
                "aud": "appstoreconnect-v1",
            },
            self.private_key,
            algorithm="ES256",
            headers={"kid": self.key_id, "typ": "JWT"},
        )

    def request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json_body: dict[str, Any] | None = None,
        expected: set[int] | None = None,
    ) -> httpx.Response:
        expected = expected or {200}
        url = f"{API_BASE}{path}"
        if self.dry_run and method.upper() not in {"GET", "HEAD"}:
            print(f"[dry-run] {method.upper()} {path}")
            if json_body is not None:
                print_jsonish(json_body)
            return DummyResponse(200, {"data": {"id": "dry-run"}})  # type: ignore[return-value]

        response = self.http.request(
            method,
            url,
            params=params,
            json=json_body,
            headers={
                "Authorization": f"Bearer {self._token()}",
                "Content-Type": "application/json",
            },
        )
        if response.status_code not in expected:
            raise AppStoreConnectError(
                f"{method.upper()} {path} failed with {response.status_code}: "
                f"{response.text[:2000]}"
            )
        return response

    def paged_get(
        self,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        next_url: str | None = f"{API_BASE}{path}"
        next_params = params or {}
        while next_url:
            response = self.http.get(
                next_url,
                params=next_params,
                headers={"Authorization": f"Bearer {self._token()}"},
                timeout=45.0,
            )
            if response.status_code != 200:
                raise AppStoreConnectError(
                    f"GET {next_url} failed with {response.status_code}: "
                    f"{response.text[:2000]}"
                )
            payload = response.json()
            items.extend(payload.get("data", []))
            next_url = payload.get("links", {}).get("next")
            next_params = {}
        return items


class DummyResponse:
    def __init__(self, status_code: int, payload: dict[str, Any]) -> None:
        self.status_code = status_code
        self._payload = payload
        self.text = str(payload)

    def json(self) -> dict[str, Any]:
        return self._payload


def print_jsonish(value: dict[str, Any]) -> None:
    import json

    print(json.dumps(value, indent=2, sort_keys=True))


def load_env(name: str, fallback: str | None = None) -> str:
    value = os.environ.get(name, fallback)
    if not value:
        raise SystemExit(f"Missing required env var or arg: {name}")
    return value


def list_iaps(client: AppStoreConnectClient, app_id: str) -> dict[str, dict[str, Any]]:
    data = client.paged_get(f"/v1/apps/{app_id}/inAppPurchasesV2", params={"limit": 200})
    result: dict[str, dict[str, Any]] = {}
    for item in data:
        product_id = item.get("attributes", {}).get("productId")
        if product_id:
            result[product_id] = item
    return result


def ensure_iap(
    client: AppStoreConnectClient,
    app_id: str,
    product: CreditProduct,
    existing: dict[str, dict[str, Any]],
) -> str:
    current = existing.get(product.product_id)
    if current:
        print(f"[iap] exists {product.product_id} -> {current['id']}")
        return current["id"]

    payload = {
        "data": {
            "type": "inAppPurchases",
            "attributes": {
                "name": product.reference_name,
                "productId": product.product_id,
                "inAppPurchaseType": "CONSUMABLE",
                "familySharable": False,
                "reviewNote": (
                    "Purchasing grants non-expiring VoiceType credit. "
                    "The backend verifies the StoreKit transaction and records "
                    "credit in the user's server-side ledger."
                ),
            },
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
            },
        }
    }
    response = client.request(
        "POST",
        "/v2/inAppPurchases",
        json_body=payload,
        expected={201, 409},
    )
    if response.status_code == 409:
        refreshed = list_iaps(client, app_id)
        if product.product_id in refreshed:
            return refreshed[product.product_id]["id"]
        raise AppStoreConnectError(f"Conflict creating {product.product_id}")
    iap_id = response.json()["data"]["id"]
    print(f"[iap] created {product.product_id} -> {iap_id}")
    return iap_id


def get_territory_ids(client: AppStoreConnectClient) -> list[str]:
    territories = client.paged_get("/v1/territories", params={"limit": 200})
    ids = [item["id"] for item in territories]
    if USA_TERRITORY_ID not in ids:
        ids.append(USA_TERRITORY_ID)
    return sorted(set(ids))


def ensure_availability(
    client: AppStoreConnectClient,
    iap_id: str,
    territory_ids: list[str],
) -> None:
    payload = {
        "data": {
            "type": "inAppPurchaseAvailabilities",
            "attributes": {"availableInNewTerritories": True},
            "relationships": {
                "availableTerritories": {
                    "data": [
                        {"type": "territories", "id": territory_id}
                        for territory_id in territory_ids
                    ]
                },
                "inAppPurchase": {
                    "data": {"type": "inAppPurchases", "id": iap_id}
                },
            },
        }
    }
    response = client.request(
        "POST",
        "/v1/inAppPurchaseAvailabilities",
        json_body=payload,
        expected={201, 409},
    )
    if response.status_code == 409:
        print(f"[availability] already configured for {iap_id}")
    else:
        print(f"[availability] all territories for {iap_id}")


def ensure_localization(
    client: AppStoreConnectClient,
    iap_id: str,
    product: CreditProduct,
) -> None:
    existing = client.paged_get(
        f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations",
        params={"limit": 200},
    )
    for localization in existing:
        attrs = localization.get("attributes", {})
        if attrs.get("locale") in {"en-US", "en_US"}:
            payload = {
                "data": {
                    "type": "inAppPurchaseLocalizations",
                    "id": localization["id"],
                    "attributes": {
                        "name": product.display_name,
                        "description": product.description,
                    },
                }
            }
            client.request(
                "PATCH",
                f"/v1/inAppPurchaseLocalizations/{localization['id']}",
                json_body=payload,
                expected={200},
            )
            print(f"[localization] updated en-US for {product.product_id}")
            return

    payload = {
        "data": {
            "type": "inAppPurchaseLocalizations",
            "attributes": {
                "locale": "en-US",
                "name": product.display_name,
                "description": product.description,
            },
            "relationships": {
                "inAppPurchaseV2": {
                    "data": {"type": "inAppPurchases", "id": iap_id}
                }
            },
        }
    }
    client.request(
        "POST",
        "/v1/inAppPurchaseLocalizations",
        json_body=payload,
        expected={201, 409},
    )
    print(f"[localization] created en-US for {product.product_id}")


def decimal_from_price(value: Any) -> Decimal | None:
    if value is None:
        return None
    match = re.search(r"\d+(?:\.\d+)?", str(value))
    if not match:
        return None
    return Decimal(match.group(0))


def price_points_json(response: httpx.Response) -> list[dict[str, Any]]:
    content_type = response.headers.get("content-type", "")
    if "json" in content_type:
        return response.json().get("data", [])

    rows = list(csv.DictReader(io.StringIO(response.text)))
    points: list[dict[str, Any]] = []
    for row in rows:
        point_id = row.get("id") or row.get("ID")
        price = row.get("customerPrice") or row.get("Customer Price")
        territory = row.get("territory") or row.get("Territory")
        if point_id:
            points.append(
                {
                    "id": point_id,
                    "attributes": {"customerPrice": price},
                    "relationships": {
                        "territory": {
                            "data": {"id": territory or USA_TERRITORY_ID}
                        }
                    },
                }
            )
    return points


def find_price_point(
    client: AppStoreConnectClient,
    iap_id: str,
    target: Decimal,
) -> str:
    response = client.request(
        "GET",
        f"/v2/inAppPurchases/{iap_id}/pricePoints",
        params={
            "filter[territory]": USA_TERRITORY_ID,
            "include": "territory",
            "limit": 8000,
        },
        expected={200},
    )
    points = price_points_json(response)
    best: tuple[Decimal, str, Decimal] | None = None
    for point in points:
        price = decimal_from_price(point.get("attributes", {}).get("customerPrice"))
        if price is None:
            continue
        diff = abs(price - target)
        candidate = (diff, point["id"], price)
        if best is None or candidate < best:
            best = candidate
    if best is None:
        raise AppStoreConnectError(f"No price points returned for IAP {iap_id}")
    diff, point_id, actual = best
    if diff > Decimal("0.01"):
        raise AppStoreConnectError(
            f"Closest USA price for {iap_id} is {actual}, not near target {target}"
        )
    print(f"[price-point] {iap_id} target {target} -> {actual} ({point_id})")
    return point_id


def get_current_usa_prices(
    client: AppStoreConnectClient,
    iap_id: str,
) -> list[Decimal]:
    prices: list[Decimal] = []
    for relationship in ("manualPrices", "automaticPrices"):
        response = client.request(
            "GET",
            f"/v1/inAppPurchasePriceSchedules/{iap_id}/{relationship}",
            params={
                "include": "inAppPurchasePricePoint,territory",
                "fields[inAppPurchasePrices]": (
                    "startDate,endDate,manual,inAppPurchasePricePoint,territory"
                ),
                "fields[inAppPurchasePricePoints]": (
                    "customerPrice,proceeds,territory"
                ),
                "filter[territory]": USA_TERRITORY_ID,
                "limit": 200,
            },
            expected={200},
        )
        payload = response.json()
        point_prices = {
            item["id"]: decimal_from_price(
                item.get("attributes", {}).get("customerPrice")
            )
            for item in payload.get("included", [])
            if item.get("type") == "inAppPurchasePricePoints"
        }
        for item in payload.get("data", []):
            point_id = (
                item.get("relationships", {})
                .get("inAppPurchasePricePoint", {})
                .get("data", {})
                .get("id")
            )
            price = point_prices.get(point_id)
            if price is not None:
                prices.append(price)
    return prices


def ensure_price_schedule(
    client: AppStoreConnectClient,
    iap_id: str,
    price_point_id: str,
    target: Decimal,
) -> None:
    client.request(
        "GET",
        f"/v2/inAppPurchases/{iap_id}/iapPriceSchedule",
        params={"include": "manualPrices,automaticPrices,baseTerritory"},
        expected={200, 404},
    )
    current_prices = get_current_usa_prices(client, iap_id)
    if any(abs(price - target) <= Decimal("0.01") for price in current_prices):
        print(f"[price] USA price already {target} for {iap_id}")
        return
    if current_prices:
        rendered = ", ".join(str(price) for price in current_prices)
        raise AppStoreConnectError(
            f"USA price for {iap_id} is {rendered}, expected {target}. "
            "Review the existing App Store Connect price schedule before changing it."
        )

    payload = {
        "data": {
            "type": "inAppPurchasePriceSchedules",
            "relationships": {
                "baseTerritory": {
                    "data": {"type": "territories", "id": USA_TERRITORY_ID}
                },
                "inAppPurchase": {
                    "data": {"type": "inAppPurchases", "id": iap_id}
                },
                "manualPrices": {
                    "data": [
                        {"type": "inAppPurchasePrices", "id": "${price1}"}
                    ]
                },
            },
        },
        "included": [
            {
                "type": "inAppPurchasePrices",
                "id": "${price1}",
                "attributes": {"startDate": None},
                "relationships": {
                    "inAppPurchaseV2": {
                        "data": {"type": "inAppPurchases", "id": iap_id}
                    },
                    "inAppPurchasePricePoint": {
                        "data": {
                            "type": "inAppPurchasePricePoints",
                            "id": price_point_id,
                        }
                    },
                },
            }
        ],
    }
    create_response = client.request(
        "POST",
        "/v1/inAppPurchasePriceSchedules",
        json_body=payload,
        expected={201, 409},
    )
    if create_response.status_code == 409:
        current_prices = get_current_usa_prices(client, iap_id)
        if any(abs(price - target) <= Decimal("0.01") for price in current_prices):
            print(f"[price] USA price already {target} for {iap_id}")
            return
        raise AppStoreConnectError(
            f"Price schedule already exists for {iap_id}, but USA target "
            f"{target} was not found."
        )
    else:
        print(f"[price] created schedule for {iap_id}")
    current_prices = get_current_usa_prices(client, iap_id)
    if not any(abs(price - target) <= Decimal("0.01") for price in current_prices):
        raise AppStoreConnectError(
            f"Created price schedule for {iap_id}, but USA target {target} "
            "was not returned by App Store Connect."
        )


def read_review_screenshot(
    client: AppStoreConnectClient,
    iap_id: str,
) -> dict[str, Any] | None:
    response = client.request(
        "GET",
        f"/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot",
        expected={200, 404},
    )
    if response.status_code == 404:
        return None
    return response.json().get("data")


def create_review_screenshot(
    client: AppStoreConnectClient,
    iap_id: str,
    screenshot_path: Path,
    file_size: int,
) -> dict[str, Any]:
    payload = {
        "data": {
            "type": "inAppPurchaseAppStoreReviewScreenshots",
            "attributes": {
                "fileName": screenshot_path.name,
                "fileSize": file_size,
            },
            "relationships": {
                "inAppPurchaseV2": {
                    "data": {"type": "inAppPurchases", "id": iap_id}
                }
            },
        }
    }
    response = client.request(
        "POST",
        "/v1/inAppPurchaseAppStoreReviewScreenshots",
        json_body=payload,
        expected={201, 409},
    )
    if response.status_code == 409:
        existing = read_review_screenshot(client, iap_id)
        if existing:
            return existing
        raise AppStoreConnectError(
            f"Conflict creating review screenshot for IAP {iap_id}"
        )
    return response.json()["data"]


def upload_review_screenshot_bytes(
    client: AppStoreConnectClient,
    asset: dict[str, Any],
    data: bytes,
) -> None:
    operations = asset.get("attributes", {}).get("uploadOperations", [])
    if not operations:
        raise AppStoreConnectError(
            f"No upload operations returned for review screenshot {asset['id']}"
        )
    for operation in operations:
        offset = int(operation.get("offset", 0))
        length = int(operation.get("length", len(data)))
        chunk = data[offset : offset + length]
        headers = {
            header["name"]: header["value"]
            for header in operation.get("requestHeaders", [])
        }
        response = client.http.request(
            operation.get("method", "PUT"),
            operation["url"],
            headers=headers,
            content=chunk,
            timeout=120.0,
        )
        if response.status_code // 100 != 2:
            raise AppStoreConnectError(
                f"Asset upload failed for review screenshot {asset['id']} "
                f"with {response.status_code}: {response.text[:1000]}"
            )


def commit_review_screenshot(
    client: AppStoreConnectClient,
    asset_id: str,
    checksum: str,
) -> dict[str, Any]:
    payload = {
        "data": {
            "type": "inAppPurchaseAppStoreReviewScreenshots",
            "id": asset_id,
            "attributes": {
                "sourceFileChecksum": checksum,
                "uploaded": True,
            },
        }
    }
    return client.request(
        "PATCH",
        f"/v1/inAppPurchaseAppStoreReviewScreenshots/{asset_id}",
        json_body=payload,
        expected={200},
    ).json()["data"]


def ensure_review_screenshot(
    client: AppStoreConnectClient,
    iap_id: str,
    product: CreditProduct,
    screenshot_path: Path,
) -> None:
    data = screenshot_path.read_bytes()
    checksum = hashlib.md5(data).hexdigest()
    current = read_review_screenshot(client, iap_id)
    state = (current or {}).get("attributes", {}).get("assetDeliveryState", {}).get("state")
    if current and state == "COMPLETE":
        print(f"[review-screenshot] already complete for {product.product_id}")
        return

    asset = current or create_review_screenshot(
        client,
        iap_id,
        screenshot_path,
        len(data),
    )
    if state != "UPLOAD_COMPLETE":
        upload_review_screenshot_bytes(client, asset, data)
    committed = commit_review_screenshot(client, asset["id"], checksum)
    state = committed.get("attributes", {}).get("assetDeliveryState", {}).get("state")
    print(f"[review-screenshot] committed for {product.product_id}: {state}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-id", default=os.environ.get("ASC_APP_ID", DEFAULT_APP_ID))
    parser.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID"))
    parser.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER_ID"))
    parser.add_argument(
        "--private-key-path",
        default=os.environ.get("ASC_PRIVATE_KEY_PATH"),
        help="Path to AuthKey_<KEY_ID>.p8",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Perform writes. Without this flag, only GETs and write previews run.",
    )
    parser.add_argument(
        "--review-screenshot-path",
        default=os.environ.get("ASC_REVIEW_SCREENSHOT_PATH"),
        help="Optional PNG/JPEG to upload as the App Review screenshot for each IAP.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    key_id = args.key_id or load_env("ASC_KEY_ID")
    issuer_id = args.issuer_id or load_env("ASC_ISSUER_ID")
    private_key_path = Path(args.private_key_path or load_env("ASC_PRIVATE_KEY_PATH"))
    if not private_key_path.exists():
        raise SystemExit(f"Private key not found: {private_key_path}")
    review_screenshot_path = (
        Path(args.review_screenshot_path) if args.review_screenshot_path else None
    )
    if review_screenshot_path and not review_screenshot_path.exists():
        raise SystemExit(f"Review screenshot not found: {review_screenshot_path}")

    client = AppStoreConnectClient(
        key_id=key_id,
        issuer_id=issuer_id,
        private_key_path=private_key_path,
        dry_run=not args.apply,
    )
    try:
        existing = list_iaps(client, args.app_id)
        territory_ids = get_territory_ids(client) if args.apply else [USA_TERRITORY_ID]
        for product in PRODUCTS:
            iap_id = ensure_iap(client, args.app_id, product, existing)
            if not args.apply and iap_id == "dry-run":
                print(f"[dry-run] would configure availability for {product.product_id}")
                print(f"[dry-run] would create en-US localization for {product.product_id}")
                print(
                    f"[dry-run] would set USA base price "
                    f"{product.target_customer_price} for {product.product_id}"
                )
                continue
            ensure_availability(client, iap_id, territory_ids)
            ensure_localization(client, iap_id, product)
            if args.apply:
                price_point_id = find_price_point(
                    client, iap_id, product.target_customer_price
                )
                ensure_price_schedule(
                    client,
                    iap_id,
                    price_point_id,
                    product.target_customer_price,
                )
                if review_screenshot_path:
                    ensure_review_screenshot(
                        client,
                        iap_id,
                        product,
                        review_screenshot_path,
                    )
            else:
                print(
                    f"[dry-run] would set USA base price "
                    f"{product.target_customer_price} for {product.product_id}"
                )
                if review_screenshot_path:
                    print(
                        f"[dry-run] would upload review screenshot "
                        f"{review_screenshot_path} for {product.product_id}"
                    )
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
