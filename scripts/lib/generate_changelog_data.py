#!/usr/bin/env python3
"""Embed CHANGELOG.md into ChangelogData.swift for compile-time bundling."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

def resolve_root() -> Path:
    env_root = os.environ.get("ROOT", "").strip()
    if env_root:
        return Path(env_root).resolve()
    return Path(__file__).resolve().parents[2]


ROOT = resolve_root()
CHANGELOG_RU = ROOT / "CHANGELOG.md"
CHANGELOG_EN = ROOT / (os.environ.get("CHANGELOG_EN") or "CHANGELOG.en.md")
OUTPUT = ROOT / os.environ["CHANGELOG_DATA_SWIFT"]
BILINGUAL = os.environ.get("CHANGELOG_BILINGUAL", "0") in ("1", "true", "yes")


def read_changelog(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8")


def main() -> int:
    if "CHANGELOG_DATA_SWIFT" not in os.environ:
        print("error: CHANGELOG_DATA_SWIFT is not set (run via swift_scripts build/release)", file=sys.stderr)
        return 1

    if not CHANGELOG_RU.exists():
        print(f"error: missing {CHANGELOG_RU}", file=sys.stderr)
        return 1

    text_ru = read_changelog(CHANGELOG_RU)
    text_en = read_changelog(CHANGELOG_EN) if BILINGUAL else ""
    if BILINGUAL and not text_en:
        print(f"warning: missing {CHANGELOG_EN}, using Russian text for English slot", file=sys.stderr)
        text_en = text_ru

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    if BILINGUAL:
        body = (
            "// Generated from CHANGELOG.md and CHANGELOG.en.md — do not edit manually.\n\n"
            "enum ChangelogData {\n"
            f"    static let textRu = {json.dumps(text_ru, ensure_ascii=False)}\n"
            f"    static let textEn = {json.dumps(text_en, ensure_ascii=False)}\n"
            "}\n"
        )
    else:
        body = (
            "// Generated from CHANGELOG.md — do not edit manually.\n\n"
            "enum ChangelogData {\n"
            f"    static let text = {json.dumps(text_ru, ensure_ascii=False)}\n"
            "}\n"
        )

    OUTPUT.write_text(body, encoding="utf-8")
    print(f"Wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
