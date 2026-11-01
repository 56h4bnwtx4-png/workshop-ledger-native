#!/usr/bin/env python3
from __future__ import annotations

import base64
import binascii
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "WorkshopLedger" / "Resources" / "model-catalog.txt"
MAX_MODELS = 2000
MAX_MODEL_LENGTH = 100


def fail(message: str) -> int:
    print(f"Model catalog injection failed: {message}", file=sys.stderr)
    return 1


def read_payload() -> bytes | None:
    source_file = os.environ.get("MODEL_CATALOG_FILE", "").strip()
    if source_file:
        return Path(source_file).read_bytes()

    encoded = "".join(os.environ.get("MODEL_CATALOG_B64", "").split())
    if not encoded:
        return None
    try:
        return base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("MODEL_CATALOG_B64 is not valid Base64") from error


def normalize_models(payload: bytes) -> list[str]:
    try:
        text = payload.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise ValueError("model catalog must be UTF-8") from error

    models: list[str] = []
    seen: set[str] = set()
    for raw_line in text.splitlines():
        model = raw_line.strip()
        if not model or model.startswith("#"):
            continue
        if "\x00" in model:
            raise ValueError("model catalog contains a NUL character")
        if len(model) > MAX_MODEL_LENGTH:
            raise ValueError(f"a model name exceeds {MAX_MODEL_LENGTH} characters")
        if model not in seen:
            seen.add(model)
            models.append(model)

    if not models:
        raise ValueError("model catalog contains no usable model names")
    if len(models) > MAX_MODELS:
        raise ValueError(f"model catalog exceeds {MAX_MODELS} entries")
    return models


def main() -> int:
    try:
        payload = read_payload()
        if payload is None:
            print("MODEL_CATALOG_B64 is not set; keeping the public placeholder.")
            return 0

        models = normalize_models(payload)
        DESTINATION.parent.mkdir(parents=True, exist_ok=True)
        temporary = DESTINATION.with_suffix(".txt.tmp")
        temporary.write_text("\n".join(models) + "\n", encoding="utf-8", newline="\n")
        temporary.replace(DESTINATION)
        print(f"Injected {len(models)} local model names.")
        return 0
    except (OSError, ValueError) as error:
        return fail(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
