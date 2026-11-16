#!/usr/bin/env python3
"""Promote a Google Play release from one track to another (same version codes).

Why this exists: the Play API rejects uploading an AAB whose version code
already exists on another track ("Version code N has already been used").
Run 43867508615 hit exactly that: the internal-track publish had already
uploaded versionCode 21, so the production dispatch could not re-upload
the same AAB. Promotion assigns the source track's *existing* version
codes to the target track instead of uploading a new binary:

  edits.insert -> tracks.get (source) -> tracks.update (target) -> edits.commit

Usage (service-account JSON via env, never via argv):
  PLAY_STORE_SERVICE_ACCOUNT_JSON='...' python3 tools/promote_play_release.py \
    --package app.storycam --from-track internal --to-track production \
    --status inProgress --user-fraction 0.20 \
    [--whatsnew-dir distribution/whatsnew]

Exit 0 only after the edit commits. Prints the promoted version codes,
target track, status and fraction. Idempotent: re-running promotes the
same version codes again, which Play accepts.
"""

import argparse
import json
import os
import sys
from pathlib import Path

SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]


def load_service_account():
    raw = os.environ.get("PLAY_STORE_SERVICE_ACCOUNT_JSON", "")
    if not raw.strip():
        print("PLAY_STORE_SERVICE_ACCOUNT_JSON is not set", file=sys.stderr)
        sys.exit(2)
    try:
        info = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"PLAY_STORE_SERVICE_ACCOUNT_JSON is not valid JSON: {exc}", file=sys.stderr)
        sys.exit(2)
    from google.oauth2 import service_account

    return service_account.Credentials.from_service_account_info(info, scopes=SCOPES)


def read_whatsnew(whatsnew_dir):
    """Return Play releaseNotes from distribution/whatsnew/<lang>.txt files."""
    notes = []
    if not whatsnew_dir:
        return notes
    root = Path(whatsnew_dir)
    if not root.is_dir():
        print(f"whatsnew dir {whatsnew_dir} not found, skipping release notes")
        return notes
    for path in sorted(root.glob("*.txt")):
        text = path.read_text(encoding="utf-8").strip()
        if text:
            notes.append({"language": path.stem, "text": text})
    return notes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, help="e.g. app.storycam")
    parser.add_argument("--from-track", required=True, help="source track, e.g. internal")
    parser.add_argument("--to-track", required=True, help="target track, e.g. production")
    parser.add_argument("--status", default="inProgress",
                        choices=["completed", "draft", "inProgress", "halted"])
    parser.add_argument("--user-fraction", default="0.20",
                        help="staged-rollout fraction; only used when status is inProgress/halted")
    parser.add_argument("--whatsnew-dir", default="",
                        help="directory of <language>.txt release notes")
    args = parser.parse_args()

    if args.from_track == args.to_track:
        print("from-track and to-track are the same; nothing to promote", file=sys.stderr)
        sys.exit(2)

    from googleapiclient.discovery import build

    service = build("androidpublisher", "v3", credentials=load_service_account())
    edits = service.edits()
    edit = edits.insert(body={}, packageName=args.package).execute()
    edit_id = edit["id"]
    try:
        source = edits.tracks().get(
            editId=edit_id, packageName=args.package, track=args.from_track
        ).execute()
        releases = source.get("releases", [])
        active = [r for r in releases if r.get("status") == "completed"] or releases
        if not active:
            print(f"no release found on track {args.from_track!r}", file=sys.stderr)
            sys.exit(1)
        version_codes = active[0].get("versionCodes", [])
        if not version_codes:
            print(f"release on track {args.from_track!r} has no versionCodes", file=sys.stderr)
            sys.exit(1)
        release_name = active[0].get("name", "")

        release = {"versionCodes": version_codes, "status": args.status}
        if release_name:
            release["name"] = release_name
        notes = read_whatsnew(args.whatsnew_dir)
        if notes:
            release["releaseNotes"] = notes
        if args.status in ("inProgress", "halted"):
            release["userFraction"] = float(args.user_fraction)

        edits.tracks().update(
            editId=edit_id,
            packageName=args.package,
            track=args.to_track,
            body={"track": args.to_track, "releases": [release]},
        ).execute()
        edits.commit(editId=edit_id, packageName=args.package).execute()
    except Exception:
        # A failed edit must not linger: a stale open edit blocks later edits.
        try:
            edits.delete(editId=edit_id, packageName=args.package).execute()
        except Exception:
            pass
        raise

    print(
        f"Promoted {args.package} versionCodes={version_codes} "
        f"{args.from_track} -> {args.to_track} "
        f"status={args.status}"
        + (f" userFraction={args.user_fraction}" if args.status in ("inProgress", "halted") else "")
    )


if __name__ == "__main__":
    main()
