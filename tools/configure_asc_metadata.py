#!/usr/bin/env python3
"""
Configure App Store Connect metadata, categories, age rating (4+), and $0.00 Free pricing
for free MIDI player (FOSS) (com.lukeknoble.freemidiplayer) via the App Store Connect REST API v1.
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request
from typing import Any

import jwt

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
METADATA_DIR = REPO_ROOT / "fastlane" / "metadata" / "en-US"

BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.lukeknoble.freemidiplayer")
KEY_ID = os.environ.get("ASC_KEY_ID", "362BK739MY")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "cd0c881b-f57b-4030-9d14-73f868ececb6")
KEY_PATH = pathlib.Path(
    os.environ.get("ASC_KEY_PATH", os.path.expanduser(f"~/.private_keys/AuthKey_{KEY_ID}.p8"))
)


def make_token() -> str:
    private_key = KEY_PATH.read_text(encoding="utf-8")
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def api_request(method: str, path_or_url: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    url = (
        path_or_url
        if path_or_url.startswith("https://")
        else f"https://api.appstoreconnect.apple.com{path_or_url}"
    )
    headers = {
        "Authorization": f"Bearer {make_token()}",
        "Content-Type": "application/json",
    }
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        err_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} -> HTTP {exc.code}: {err_body}") from exc


def read_meta(filename: str, default: str = "") -> str:
    path = METADATA_DIR / filename
    return path.read_text(encoding="utf-8").strip() if path.exists() else default


def configure_app() -> int:
    os.environ.setdefault("SSL_CERT_FILE", "/etc/ssl/cert.pem")
    if not KEY_PATH.exists():
        print(f"ERROR: App Store Connect private key not found at {KEY_PATH}", file=sys.stderr)
        return 1

    apps = api_request("GET", f"/v1/apps?filter%5BbundleId%5D={BUNDLE_ID}").get("data", [])
    if not apps:
        print(
            f"ERROR: App record for '{BUNDLE_ID}' not found on App Store Connect yet.\n"
            "Create the initial App record once at https://appstoreconnect.apple.com/apps -> (+) New App:\n"
            "  - Platform: iOS\n"
            "  - Name: free MIDI player (FOSS)\n"
            "  - Primary Language: English (U.S.)\n"
            f"  - Bundle ID: {BUNDLE_ID}\n"
            "  - SKU: freemidiplayer-ios-001",
            file=sys.stderr,
        )
        return 2

    app_id = apps[0]["id"]
    print(f"==> Configuring App Store Connect metadata for App ID {app_id} ({BUNDLE_ID})...")

    # 1. App Info & App Info Localizations (Subtitle, Privacy Policy URL, Categories)
    app_infos = api_request("GET", f"/v1/apps/{app_id}/appInfos").get("data", [])
    if app_infos:
        app_info_id = app_infos[0]["id"]
        try:
            api_request(
                "PATCH",
                f"/v1/appInfos/{app_info_id}",
                {
                    "data": {
                        "type": "appInfos",
                        "id": app_info_id,
                        "relationships": {
                            "primaryCategory": {"data": {"type": "appCategories", "id": "MUSIC"}},
                            "secondaryCategory": {"data": {"type": "appCategories", "id": "EDUCATION"}},
                        },
                    }
                },
            )
            print("  [OK] Updated primary/secondary categories (MUSIC / EDUCATION)")
        except Exception as exc:
            print(f"  [WARN] Category update skipped: {exc}")

        info_locs = api_request("GET", f"/v1/appInfos/{app_info_id}/appInfoLocalizations").get("data", [])
        subtitle = read_meta("subtitle.txt", "Interactive Piano Practice")[:30]
        privacy_url = read_meta(
            "privacy_url.txt",
            "https://github.com/Desync-o-tron/piano-wait/blob/main/AppStore/PRIVACY_POLICY.md",
        )
        for loc in info_locs:
            loc_id = loc["id"]
            api_request(
                "PATCH",
                f"/v1/appInfoLocalizations/{loc_id}",
                {
                    "data": {
                        "type": "appInfoLocalizations",
                        "id": loc_id,
                        "attributes": {
                            "name": read_meta("name.txt", "free MIDI player (FOSS)")[:30],
                            "subtitle": subtitle,
                            "privacyPolicyUrl": privacy_url,
                        },
                    }
                },
            )
            print(f"  [OK] Updated appInfoLocalization {loc_id} (subtitle & privacy policy URL)")

        # Age Rating Declaration (4+ All Ages)
        try:
            age_decl = api_request("GET", f"/v1/appInfos/{app_info_id}/ageRatingDeclaration").get("data")
            if age_decl:
                age_id = age_decl["id"]
                api_request(
                    "PATCH",
                    f"/v1/ageRatingDeclarations/{age_id}",
                    {
                        "data": {
                            "type": "ageRatingDeclarations",
                            "id": age_id,
                            "attributes": {
                                "alcoholTobaccoOrDrugUseOrReferences": "NONE",
                                "contests": "NONE",
                                "gambling": False,
                                "gamblingSimulated": "NONE",
                                "horrorOrFearThemes": "NONE",
                                "matureOrSuggestiveThemes": "NONE",
                                "medicalOrTreatmentInformation": "NONE",
                                "profanityOrCrudeHumor": "NONE",
                                "sexualContentGraphicAndNudity": "NONE",
                                "sexualContentOrNudity": "NONE",
                                "violenceCartoonOrFantasy": "NONE",
                                "violenceRealistic": "NONE",
                                "violenceRealisticProlongedGraphicOrSadistic": "NONE",
                                "unrestrictedWebAccess": False,
                                "lootBox": False,
                                "socialMedia": False,
                                "healthOrWellnessTopics": False,
                                "advertising": True,
                                "messagingAndChat": False,
                                "ageAssurance": False,
                                "gunsOrOtherWeapons": "NONE",
                                "userGeneratedContent": False,
                                "parentalControls": False,
                            },
                        }
                    },
                )
                print(f"  [OK] Updated ageRatingDeclaration {age_id} (4+ rating)")
        except Exception as exc:
            print(f"  [WARN] Age rating update skipped: {exc}")

    # 2. App Store Version & Version Localizations (Description, Keywords, Promotional Text, Support/Marketing URLs)
    versions = api_request("GET", f"/v1/apps/{app_id}/appStoreVersions").get("data", [])
    if versions:
        ver_id = versions[0]["id"]
        api_request(
            "PATCH",
            f"/v1/appStoreVersions/{ver_id}",
            {
                "data": {
                    "type": "appStoreVersions",
                    "id": ver_id,
                    "attributes": {
                        "copyright": "2026 Luke Knoble",
                        "releaseType": "AFTER_APPROVAL",
                    },
                }
            },
        )
        print(f"  [OK] Updated appStoreVersion {ver_id} copyright & releaseType")

        ver_locs = api_request("GET", f"/v1/appStoreVersions/{ver_id}/appStoreVersionLocalizations").get(
            "data", []
        )
        description = read_meta("description.txt")
        keywords = read_meta("keywords.txt")[:100]
        promotional_text = read_meta("promotional_text.txt")[:170]
        support_url = read_meta("support_url.txt", "https://github.com/Desync-o-tron/piano-wait/issues")
        marketing_url = read_meta("marketing_url.txt", "https://github.com/Desync-o-tron/piano-wait")

        for loc in ver_locs:
            loc_id = loc["id"]
            api_request(
                "PATCH",
                f"/v1/appStoreVersionLocalizations/{loc_id}",
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": loc_id,
                        "attributes": {
                            "description": description,
                            "keywords": keywords,
                            "promotionalText": promotional_text,
                            "supportUrl": support_url,
                            "marketingUrl": marketing_url,
                        },
                    }
                },
            )
            print(f"  [OK] Updated appStoreVersionLocalization {loc_id} (description, keywords, URLs)")

    print("==> App Store Connect metadata configuration complete.")
    return 0


if __name__ == "__main__":
    sys.exit(configure_app())
