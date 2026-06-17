import json
import re
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent.parent / "assets" / "i18n"
EN_PATH = BASE_DIR / "en.json"
PLACEHOLDER_RE = re.compile(r"\{[^}]+\}")


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    en = load_json(EN_PATH)
    for path in sorted(BASE_DIR.glob("*.json")):
        data = load_json(path)
        missing = sorted(set(en) - set(data))
        extra = sorted(set(data) - set(en))
        same_as_en = []
        bad_placeholders = []

        for key, en_value in en.items():
            value = data.get(key)
            if isinstance(en_value, str) and isinstance(value, str):
                if path.name != "en.json" and value == en_value:
                    same_as_en.append(key)
                if sorted(PLACEHOLDER_RE.findall(en_value)) != sorted(
                    PLACEHOLDER_RE.findall(value)
                ):
                    bad_placeholders.append(key)

        print(
            f"{path.name}: keys={len(data)} missing={len(missing)} "
            f"extra={len(extra)} same_as_en={len(same_as_en)} "
            f"bad_placeholders={len(bad_placeholders)}"
        )
        if bad_placeholders:
            print(f"  placeholder_mismatch: {', '.join(bad_placeholders[:10])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
