#!/usr/bin/env python3
"""Inspect or push live OTA configuration (`config/ota-config.json`) to the PianoWait cloud bucket.

    tools/push_ota_config.py show
    tools/push_ota_config.py push [--file config/ota-config.json] [--dry-run]

Uploads go through the gcloud CLI (or curl/HTTPS for read), so they take effect immediately on app
launch / practice session start without waiting on App Store or Google Play review.
"""

import argparse
import datetime
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_BUCKET = os.environ.get("PIANOWAIT_BUCKET", "luke-piano-midis")
REMOTE_OBJECT_PATH = "config/ota-config.json"

DEFAULT_OTA_CONFIG = {
    "version": 1,
    "updatedAt": None,
    "dsp": {
        "noiseGateRMS": 0.0012,
        "requiredConsecutiveFrames": 2,
        "onsetRiseRatio": 1.18,
        "onsetFallRatio": 0.92,
        "referenceA4": 440.0,
        "tracksLiveTuning": True,
        "fundamentalRatio": 0.1,
        "supportRatio": 0.03,
        "minimumSalience": 0.06,
        "unexplainedShare": 0.25,
        "highOvertoneFundamentalMargin": 1.6,
        "requiredUnexplainedPartials": 2,
    },
    "engine": {
        "rollWindow": 0.85,
        "earlyGrace": 0.45,
        "strikeMemorySeconds": 0.85,
        "continuousWindow": 0.25,
        "synthEchoSuppression": 1.0,
        "partialChordGraceSeconds": 0.9,
        "highlightLeadTimeSeconds": 1.5,
    },
    "ui": {
        "autoPanKeyboardToExpectedNotes": True,
        "showUpcomingStepHighlight": True,
    },
    "telemetry": {
        "enabled": True,
        "flushStepInterval": 5,
        "uploadAudioSnippets": True,
        "telemetryBucket": "luke-piano-telemetry",
    },
}


def fetch_remote_config(bucket: str):
    url = f"https://storage.googleapis.com/{bucket}/{REMOTE_OBJECT_PATH}"
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    except urllib.error.URLError as error:
        if not isinstance(error.reason, ssl.SSLCertVerificationError) or shutil.which("curl") is None:
            raise
    result = subprocess.run(["curl", "-fsS", "--max-time", "15", url], capture_output=True, check=False)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bucket", default=DEFAULT_BUCKET, help="GCS bucket name (default: luke-piano-midis)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("show", help="Fetch and print the live OTA config in the bucket")
    sub.add_parser("defaults", help="Print the default OTA config JSON template")

    push_p = sub.add_parser("push", help="Upload OTA config JSON to gs://<bucket>/config/ota-config.json")
    push_p.add_argument("--file", type=Path, help="Local JSON file to upload (uses defaults if omitted)")
    push_p.add_argument("--set", action="append", default=[], metavar="KEY=VALUE", help="Override dotted key (e.g. dsp.noiseGateRMS=0.0015)")
    push_p.add_argument("--account", help="gcloud account to upload with")
    push_p.add_argument("--dry-run", action="store_true", help="Print JSON without uploading")

    args = parser.parse_args(argv)

    if args.command == "defaults":
        cfg = dict(DEFAULT_OTA_CONFIG)
        cfg["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        print(json.dumps(cfg, indent=2))
        return 0

    if args.command == "show":
        remote = fetch_remote_config(args.bucket)
        if remote is None:
            print(f"No live config at gs://{args.bucket}/{REMOTE_OBJECT_PATH} (404)", file=sys.stderr)
            return 1
        print(json.dumps(remote, indent=2))
        return 0

    if args.file:
        with open(args.file, "r", encoding="utf-8") as f:
            payload = json.load(f)
    else:
        payload = json.loads(json.dumps(DEFAULT_OTA_CONFIG))

    for item in args.set:
        if "=" not in item:
            print(f"Invalid --set {item!r}, expected KEY=VALUE", file=sys.stderr)
            return 1
        key_path, raw_val = item.split("=", 1)
        try:
            val = json.loads(raw_val)
        except json.JSONDecodeError:
            val = raw_val
        parts = key_path.split(".")
        cursor = payload
        for part in parts[:-1]:
            cursor = cursor.setdefault(part, {})
        cursor[parts[-1]] = val

    payload["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    formatted = json.dumps(payload, indent=2) + "\n"

    destination = f"gs://{args.bucket}/{REMOTE_OBJECT_PATH}"
    if args.dry_run:
        print(f"# Dry run -> {destination}")
        print(formatted, end="")
        return 0

    env = os.environ.copy()
    if args.account:
        env["CLOUDSDK_CORE_ACCOUNT"] = args.account

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as tmp:
        tmp.write(formatted)
        tmp_path = tmp.name

    try:
        cmd = [
            "gcloud",
            "storage",
            "cp",
            "--content-type=application/json",
            "--cache-control=no-cache, max-age=0",
            tmp_path,
            destination,
        ]
        res = subprocess.run(cmd, env=env, check=False)
        if res.returncode != 0:
            return res.returncode
        print(f"Uploaded live OTA config -> {destination}")
        return 0
    finally:
        Path(tmp_path).unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())
