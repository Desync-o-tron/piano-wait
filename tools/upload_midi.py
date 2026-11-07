#!/usr/bin/env python3
"""List and upload MIDI files to the PianoWait cloud bucket.

    tools/upload_midi.py list
    tools/upload_midi.py upload song.mid folder/of/midis/ [--prefix classical/] [--dry-run]

Uploads go through the gcloud CLI, so they use your gcloud login. Choose an account
with --account or the CLOUDSDK_CORE_ACCOUNT environment variable.
"""

import argparse
import json
import os
import shutil
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_BUCKET = os.environ.get("PIANOWAIT_BUCKET", "")
MIDI_SUFFIXES = {".mid", ".midi"}
MIDI_MAGIC = b"MThd"


def find_midi_files(paths):
    """Expands files and directories into MIDI files, and reports anything unusable."""
    found, problems = [], []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            candidates = sorted(p for p in path.rglob("*") if p.suffix.lower() in MIDI_SUFFIXES)
        elif path.is_file():
            candidates = [path]
        else:
            problems.append(f"{raw}: no such file or directory")
            continue

        for candidate in candidates:
            if candidate.suffix.lower() not in MIDI_SUFFIXES:
                problems.append(f"{candidate}: not a .mid or .midi file")
            elif not is_midi_file(candidate):
                problems.append(f"{candidate}: does not start with a MIDI header")
            else:
                found.append(candidate)
    return found, problems


def is_midi_file(path):
    with open(path, "rb") as handle:
        return handle.read(len(MIDI_MAGIC)) == MIDI_MAGIC


def object_name(path, prefix):
    return f"{prefix}{path.name}"


def fetch_json(url):
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return json.load(response)
    except urllib.error.URLError as error:
        # python.org builds of Python on macOS ship without CA certificates. curl uses the system
        # trust store and still verifies the server.
        if not isinstance(error.reason, ssl.SSLCertVerificationError) or shutil.which("curl") is None:
            raise
    result = subprocess.run(["curl", "-fsS", "--max-time", "30", url], capture_output=True, check=True)
    return json.loads(result.stdout)


def list_objects(bucket):
    """Lists MIDI objects through the bucket's public JSON API, following pagination."""
    objects, page_token = [], None
    while True:
        url = f"https://storage.googleapis.com/storage/v1/b/{bucket}/o"
        if page_token:
            url += "?" + urllib.parse.urlencode({"pageToken": page_token})
        page = fetch_json(url)
        objects += [
            item
            for item in page.get("items", [])
            if Path(item["name"]).suffix.lower() in MIDI_SUFFIXES
        ]
        page_token = page.get("nextPageToken")
        if not page_token:
            return objects


def upload(files, bucket, prefix, account, dry_run):
    """Uploads each file and returns the number of failures."""
    environment = os.environ.copy()
    if account:
        environment["CLOUDSDK_CORE_ACCOUNT"] = account

    failures = 0
    for path in files:
        destination = f"gs://{bucket}/{object_name(path, prefix)}"
        if dry_run:
            print(f"would upload {path} -> {destination}")
            continue
        result = subprocess.run(
            ["gcloud", "storage", "cp", "--content-type=audio/midi", str(path), destination],
            env=environment,
            check=False,
        )
        if result.returncode == 0:
            print(f"uploaded {path} -> {destination}")
        else:
            failures += 1
            print(f"FAILED {path}", file=sys.stderr)
    return failures


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bucket", default=DEFAULT_BUCKET)
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("list", help="list the MIDI files in the bucket")

    upload_parser = commands.add_parser("upload", help="upload MIDI files or folders of them")
    upload_parser.add_argument("paths", nargs="+")
    upload_parser.add_argument("--prefix", default="", help="folder inside the bucket, such as classical/")
    upload_parser.add_argument("--account", help="gcloud account to upload with")
    upload_parser.add_argument("--dry-run", action="store_true", help="show what would be uploaded")

    options = parser.parse_args(arguments)
    if not options.bucket:
        print("Set --bucket <name> or PIANOWAIT_BUCKET=<name>", file=sys.stderr)
        return 1

    if options.command == "list":
        for item in list_objects(options.bucket):
            print(f"{int(item.get('size', 0)):>9}  {item.get('updated', '')}  {item['name']}")
        return 0

    files, problems = find_midi_files(options.paths)
    for problem in problems:
        print(f"skipping {problem}", file=sys.stderr)
    if not files:
        print("nothing to upload", file=sys.stderr)
        return 1
    if not options.dry_run and shutil.which("gcloud") is None:
        print("gcloud is not installed: https://cloud.google.com/sdk/docs/install", file=sys.stderr)
        return 1

    prefix = options.prefix
    if prefix and not prefix.endswith("/"):
        prefix += "/"
    failures = upload(files, options.bucket, prefix, options.account, options.dry_run)
    return 1 if failures or problems else 0


if __name__ == "__main__":
    sys.exit(main())
