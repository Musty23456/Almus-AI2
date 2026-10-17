#!/usr/bin/env python3
"""Chooses a face-matching threshold from MEASURED similarity scores.

Input: a CSV with a header `kind,score`, where kind is `genuine` (two photos
of the same person) or `impostor` (photos of two different people) and score
is the cosine similarity your model + the app's preprocessing produced. Make
it from a labelled evaluation set you are allowed to use; this script cannot
invent evidence and refuses to answer when there is too little of it.

  python3 tool/calibrate_threshold.py scores.csv --target-far 0.001 \\
      --margin 0.05 --data-description "my evaluation set, N people"

Prints the `calibration` JSON block for face_model/manifest.json.
"""
import argparse
import csv
import json
import math
import sys

MIN_GENUINE = 100  # keep in sync with kMinGenuinePairs in face_calibration.dart


def load(path):
    genuine, impostor = [], []
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            kind = (row.get("kind") or "").strip().lower()
            score = float(row["score"])
            if math.isnan(score) or math.isinf(score):
                raise ValueError("invalid score")
            if kind == "genuine":
                genuine.append(score)
            elif kind == "impostor":
                impostor.append(score)
            else:
                raise ValueError("kind must be genuine or impostor: %r" % kind)
    return genuine, impostor


def choose(genuine, impostor, target_far):
    """Returns (result dict, None) or (None, reason)."""
    if not (0 < target_far < 1):
        return None, "target FAR must be between 0 and 1"
    if len(genuine) < MIN_GENUINE:
        return None, "need at least %d genuine pairs, got %d" % (MIN_GENUINE, len(genuine))
    needed = math.ceil(10 / target_far)
    if len(impostor) < needed:
        return None, "need at least %d impostor pairs for FAR %s, got %d" % (
            needed, target_far, len(impostor))
    ordered = sorted(impostor)
    allowed = math.floor(target_far * len(ordered))
    threshold = ordered[len(ordered) - 1 - allowed] + 1e-6
    far = sum(1 for s in impostor if s >= threshold) / len(impostor)
    frr = sum(1 for s in genuine if s < threshold) / len(genuine)
    return {
        "threshold": threshold,
        "measured_far": far,
        "measured_frr": frr,
        "genuine_pairs": len(genuine),
        "impostor_pairs": len(impostor),
        "target_far": target_far,
    }, None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--target-far", type=float, required=True)
    ap.add_argument("--margin", type=float, default=0.05)
    ap.add_argument("--data-description", required=True)
    args = ap.parse_args(argv)
    genuine, impostor = load(args.csv)
    result, why = choose(genuine, impostor, args.target_far)
    if result is None:
        print("NOT CALIBRATED: " + why, file=sys.stderr)
        return 2
    block = {
        "threshold": result["threshold"],
        "margin": args.margin,
        "genuine_pairs": result["genuine_pairs"],
        "impostor_pairs": result["impostor_pairs"],
        "target_far": result["target_far"],
        "data_description": args.data_description,
    }
    print(json.dumps({"calibration": block}, indent=2))
    print("measured on the supplied data: FAR=%.6f FRR=%.6f (not a guarantee for other people, cameras or lighting)"
          % (result["measured_far"], result["measured_frr"]), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
