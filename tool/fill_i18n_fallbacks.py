import json
import re
import sys
from pathlib import Path

from deep_translator import GoogleTranslator


BASE_DIR = Path(__file__).resolve().parent.parent / "assets" / "i18n"
EN_PATH = BASE_DIR / "en.json"
PLACEHOLDER_RE = re.compile(r"\{[^}]+\}")

LANG_MAP = {
    "ar": "ar",
    "de": "de",
    "es": "es",
    "fr": "fr",
    "hi": "hi",
    "id": "id",
    "it": "it",
    "ja": "ja",
    "ko": "ko",
    "pl": "pl",
    "pt": "pt",
    "ru": "ru",
    "tr": "tr",
    "uk": "uk",
    "vi": "vi",
    "zh": "zh-CN",
}

SKIP_EXACT = {
    "dashboardTitle",
    "dashboardPro",
    "proTitle",
    "proPriceMonthly",
    "proPriceYearly",
    "proIntelTitle",
    "chainEthereum",
    "chainPolygon",
    "chainArbitrum",
    "chainOptimism",
    "chainBase",
    "chainGnosis",
    "chainBNBChain",
    "settingsSupportEmailValue",
}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload: dict) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def mask_placeholders(text: str):
    placeholders = PLACEHOLDER_RE.findall(text)
    masked = text
    tokens = {}
    for i, ph in enumerate(placeholders):
        token = f"PHTOKEN{i}XYZ"
        masked = masked.replace(ph, token, 1)
        tokens[token] = ph
    return masked, tokens


def unmask_placeholders(text: str, tokens: dict[str, str]) -> str:
    restored = text
    for token, ph in tokens.items():
        restored = restored.replace(token, ph)
    return restored


def normalize_spacing(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def chunked(values: list[str], size: int):
    for index in range(0, len(values), size):
        yield values[index : index + size]


def placeholders_match(source: str, translated: str) -> bool:
    return sorted(PLACEHOLDER_RE.findall(source)) == sorted(
        PLACEHOLDER_RE.findall(translated)
    )


def translate_entries(target_lang: str, entries: dict[str, str]) -> dict[str, str]:
    if not entries:
        return {}
    translator = GoogleTranslator(source="en", target=LANG_MAP[target_lang])
    keys = list(entries.keys())
    masked_values = []
    token_map: dict[str, dict[str, str]] = {}
    for key in keys:
        masked, tokens = mask_placeholders(entries[key])
        masked_values.append(masked)
        token_map[key] = tokens

    translated_values = []
    for batch in chunked(masked_values, 20):
        batch_result = translator.translate_batch(batch)
        if not isinstance(batch_result, list):
            batch_result = [batch_result]
        translated_values.extend(batch_result)

    translated: dict[str, str] = {}
    for key, value in zip(keys, translated_values):
        restored = unmask_placeholders(value, token_map[key])
        translated[key] = normalize_spacing(restored)
    return translated


def main() -> int:
    requested = set(sys.argv[1:]) if len(sys.argv) > 1 else set(LANG_MAP.keys())
    en = load_json(EN_PATH)

    for lang in sorted(requested):
        if lang not in LANG_MAP:
            print(f"skip unknown language: {lang}")
            continue

        path = BASE_DIR / f"{lang}.json"
        if not path.exists():
            print(f"missing file: {path}")
            continue

        current = load_json(path)
        repair_keys = {
            key
            for key, value in en.items()
            if isinstance(value, str)
            and isinstance(current.get(key), str)
            and not placeholders_match(value, current[key])
        }
        to_translate = {
            key: value
            for key, value in en.items()
            if isinstance(value, str)
            and key not in SKIP_EXACT
            and (current.get(key) == value or key in repair_keys)
        }

        translated = translate_entries(lang, to_translate)
        current.update(translated)
        save_json(path, current)
        print(
            f"{lang}: translated {len(translated)} strings "
            f"(fallbacks + placeholder repairs)"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
