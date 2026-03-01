from __future__ import annotations

import json
import os
import re
import tempfile
import time
from fractions import Fraction
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urljoin, urlparse

import httpx
import orjson
import typer
from bs4 import BeautifulSoup
from pydantic import BaseModel, Field

COLLECTION_URLS = [
    "https://www.bbcgoodfood.com/recipes/collection/quick-and-healthy-recipes",
    "https://www.bbcgoodfood.com/recipes/collection/healthy-dinner-recipes",
    "https://www.bbcgoodfood.com/recipes/collection/healthy-lunch-recipes",
    "https://www.bbcgoodfood.com/recipes/collection/healthy-vegetarian-recipes",
    "https://www.bbcgoodfood.com/recipes/collection/healthy-pasta-recipes",
    "https://www.bbcgoodfood.com/recipes/collection/healthy-salad-recipes",
    "https://www.bbcgoodfood.com/recipes/collection/low-calorie-dinner-recipes",
    "https://www.bbcgoodfood.com/recipes/collection/healthy-chicken-recipes",
]
RECIPE_PATH_RE = re.compile(r"^/recipes/[a-z0-9-]+/?$")

UNICODE_FRACTIONS = {
    "¼": "1/4",
    "½": "1/2",
    "¾": "3/4",
    "⅐": "1/7",
    "⅑": "1/9",
    "⅒": "1/10",
    "⅓": "1/3",
    "⅔": "2/3",
    "⅕": "1/5",
    "⅖": "2/5",
    "⅗": "3/5",
    "⅘": "4/5",
    "⅙": "1/6",
    "⅚": "5/6",
    "⅛": "1/8",
    "⅜": "3/8",
    "⅝": "5/8",
    "⅞": "7/8",
}

UNIT_NORMALIZATION: dict[str, tuple[str, float]] = {
    "g": ("g", 1.0),
    "gram": ("g", 1.0),
    "grams": ("g", 1.0),
    "kg": ("g", 1000.0),
    "ml": ("ml", 1.0),
    "milliliter": ("ml", 1.0),
    "milliliters": ("ml", 1.0),
    "l": ("ml", 1000.0),
    "liter": ("ml", 1000.0),
    "liters": ("ml", 1000.0),
}

PACKAGING_WORDS = {
    "pack",
    "packs",
    "packet",
    "packets",
    "can",
    "cans",
    "canned",
    "tin",
    "tins",
    "jar",
    "jarred",
    "bottle",
    "bottles",
    "tub",
    "tubs",
    "sachet",
    "sachets",
    "pouch",
    "pouches",
}

PREP_WORD_TO_ACTION = {
    "chargrill": "chargrill",
    "chargrilled": "chargrill",
    "char-grilled": "chargrill",
    "roasted": "roast",
    "toasted": "toast",
    "sliced": "slice",
    "diced": "dice",
    "chopped": "chop",
    "minced": "mince",
    "grated": "grate",
    "crushed": "crush",
    "shredded": "shred",
}

LEADING_MEASURE_WORDS = {
    "tbsp",
    "tsp",
    "cup",
    "cups",
    "oz",
    "ounce",
    "ounces",
    "lb",
    "lbs",
}

NAME_STOPWORDS = {
    "or",
    "and",
    "to",
    "for",
    "with",
    "about",
    "of",
    "in",
    "on",
    "from",
    "optional",
    "fresh",
    "frozen",
    "dried",
    "large",
    "small",
    "medium",
    "halved",
    "quartered",
    "roughly",
    "finely",
    "thinly",
    "rough",
    "lean",
    "boneless",
    "skinless",
    "picked",
    "juiced",
    "cut",
    "into",
    "wedges",
    "serve",
    "seeded",
    "drained",
    "your",
    "choice",
    "tbsp",
    "tsp",
    "cup",
    "cups",
    "oz",
    "ounce",
    "ounces",
    "lb",
    "lbs",
    "g",
    "kg",
    "ml",
    "l",
}


class IngredientOut(BaseModel):
    raw: str
    scaled_raw: str
    name: str
    amount_value: int | None = None
    amount_unit: str | None = None
    prep_actions: list[str] = Field(default_factory=list)


class RecipeOut(BaseModel):
    source_url: str
    title: str
    servings_original: int | None
    servings_target: int
    ingredients: list[IngredientOut] = Field(default_factory=list)
    steps: list[str] = Field(default_factory=list)


app = typer.Typer(add_completion=False, no_args_is_help=True, help="BBC Good Food recipe scraper")


def _pretty_dumps(payload: Any) -> bytes:
    return orjson.dumps(payload, option=orjson.OPT_INDENT_2 | orjson.OPT_SORT_KEYS) + b"\n"


def atomic_write_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=str(path.parent), delete=False) as tmp:
        tmp.write(payload)
        tmp.flush()
        os.fsync(tmp.fileno())
        temp_name = tmp.name
    os.replace(temp_name, path)


def _normalize_unicode_fractions(text: str) -> str:
    out = text
    for ch, repl in UNICODE_FRACTIONS.items():
        # Handle "1½" -> "1 1/2" before global replacement.
        out = re.sub(rf"(\d){re.escape(ch)}", rf"\1 {repl}", out)
        out = out.replace(ch, repl)
    return out


def _parse_numeric_token(token: str) -> float | None:
    clean = token.strip()
    if not clean:
        return None
    if re.fullmatch(r"\d+\s+\d+/\d+", clean):
        whole, frac = clean.split(maxsplit=1)
        return float(int(whole) + Fraction(frac))
    if re.fullmatch(r"\d+/\d+", clean):
        return float(Fraction(clean))
    if re.fullmatch(r"\d+(?:\.\d+)?", clean):
        return float(clean)
    return None


def parse_leading_quantity(raw: str) -> tuple[float | None, str]:
    text = _normalize_unicode_fractions(raw.strip())
    match = re.match(r"^(?P<qty>\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)\s*(?P<rest>.*)$", text)
    if not match:
        return None, raw.strip()
    qty = _parse_numeric_token(match.group("qty"))
    if qty is None:
        return None, raw.strip()
    return qty, match.group("rest").strip()


def format_quantity(value: float) -> str:
    rounded_int = round(value)
    if abs(value - rounded_int) < 1e-6:
        return str(int(rounded_int))

    frac = Fraction(value).limit_denominator(16)
    if abs(float(frac) - value) < 0.02:
        whole = frac.numerator // frac.denominator
        rem = frac - whole
        if whole and rem.numerator:
            return f"{whole} {rem.numerator}/{rem.denominator}"
        if whole:
            return str(whole)
        return f"{frac.numerator}/{frac.denominator}"

    return f"{value:.2f}".rstrip("0").rstrip(".")


def scale_ingredient(raw: str, servings_original: int | None, servings_target: int) -> str:
    if not servings_original or servings_original <= 0:
        return raw
    qty, rest = parse_leading_quantity(raw)
    if qty is None:
        return raw
    factor = servings_target / float(servings_original)
    scaled_qty = qty * factor
    prefix = format_quantity(scaled_qty)
    return f"{prefix} {rest}".strip()


def _normalize_unit(raw_unit: str) -> tuple[str, float] | None:
    unit_key = raw_unit.strip().lower().rstrip(".")
    return UNIT_NORMALIZATION.get(unit_key)


def parse_measurable_amount(raw: str) -> tuple[int | None, str | None]:
    text = _normalize_unicode_fractions(raw.strip())
    compact = re.sub(r"\s+", " ", text)

    multi_match = re.match(
        r"^(?P<count>\d+(?:\.\d+)?)\s*x\s*(?P<size>\d+(?:\.\d+)?)\s*(?P<unit>[a-zA-Z]+)\b",
        compact,
        flags=re.IGNORECASE,
    )
    if multi_match:
        unit_data = _normalize_unit(multi_match.group("unit"))
        if unit_data:
            canonical_unit, factor = unit_data
            total = float(multi_match.group("count")) * float(multi_match.group("size")) * factor
            return int(round(total)), canonical_unit

    qty, rest = parse_leading_quantity(compact)
    if qty is None:
        return None, None
    unit_match = re.match(r"^(?P<unit>[a-zA-Z]+)\b", rest)
    if not unit_match:
        return None, None
    unit_data = _normalize_unit(unit_match.group("unit"))
    if not unit_data:
        return None, None
    canonical_unit, factor = unit_data
    return int(round(qty * factor)), canonical_unit


def extract_prep_actions(raw: str) -> list[str]:
    lowered = raw.lower()
    actions: list[str] = []
    for token, action in PREP_WORD_TO_ACTION.items():
        if re.search(rf"\b{re.escape(token)}\b", lowered):
            actions.append(action)
    return list(dict.fromkeys(actions))


def _strip_leading_amount_segment(text: str) -> str:
    compact = re.sub(r"\s+", " ", text.strip())
    compact = re.sub(r"^\d+(?:\.\d+)?\s*-\s*\d+(?:\.\d+)?\s*[a-zA-Z]+\b\s*", "", compact)
    compact = re.sub(
        r"^\d+(?:\.\d+)?\s*x\s*\d+(?:\.\d+)?\s*[a-zA-Z]+\b\s*",
        "",
        compact,
        flags=re.IGNORECASE,
    )
    qty, rest = parse_leading_quantity(compact)
    if qty is not None:
        compact = rest
        unit_candidate = re.match(r"^(?P<unit>[a-zA-Z]+)\b", compact)
        if unit_candidate and (
            _normalize_unit(unit_candidate.group("unit"))
            or unit_candidate.group("unit").lower() in LEADING_MEASURE_WORDS
        ):
            compact = re.sub(r"^[a-zA-Z]+\b\s*", "", compact, count=1)
    return compact.strip()


def normalize_ingredient_name(raw: str) -> str:
    text = _normalize_unicode_fractions(raw.strip())
    text = _strip_leading_amount_segment(text)
    text = re.split(r"[;(]", text, maxsplit=1)[0]
    lowered = text.lower()

    for token in PREP_WORD_TO_ACTION:
        lowered = re.sub(rf"\b{re.escape(token)}\b", " ", lowered)

    lowered = re.sub(r"\b\d+(?:\.\d+)?\b", " ", lowered)
    lowered = re.sub(r"[^\w\s-]", " ", lowered)
    words = [w for w in lowered.split() if w]

    filtered: list[str] = []
    for word in words:
        if re.search(r"\d", word):
            continue
        if word in PACKAGING_WORDS:
            continue
        if word in NAME_STOPWORDS:
            continue
        filtered.append(word)

    if not filtered:
        return " ".join(words).strip()
    return " ".join(filtered).strip()


def _action_already_in_steps(action: str, ingredient_name: str, steps: list[str]) -> bool:
    if not ingredient_name:
        return True
    body = " ".join(steps).lower()
    noun = ingredient_name.split()[-1]
    action_patterns = {
        "chargrill": r"\bchar-?grill(?:ed|ing)?\b",
        "roast": r"\broast(?:ed|ing)?\b",
        "toast": r"\btoast(?:ed|ing)?\b",
        "slice": r"\bslic(?:e|ed|ing)\b",
        "dice": r"\bdic(?:e|ed|ing)\b",
        "chop": r"\bchopp?(?:ed|ing)?\b|\bchop\b",
        "mince": r"\bminc(?:e|ed|ing)\b",
        "grate": r"\bgrat(?:e|ed|ing)\b",
        "crush": r"\bcrush(?:ed|ing)?\b",
        "shred": r"\bshred(?:ded|ding)?\b",
    }
    pattern = action_patterns.get(action, rf"\b{re.escape(action)}(?:ed|ing)?\b")
    return re.search(pattern, body) is not None and re.search(rf"\b{re.escape(noun)}\b", body) is not None


def build_prep_steps(ingredients: list[IngredientOut], steps: list[str]) -> list[str]:
    prep_steps: list[str] = []
    for ingredient in ingredients:
        if not ingredient.name:
            continue
        for action in ingredient.prep_actions:
            if _action_already_in_steps(action, ingredient.name, steps):
                continue
            prep_steps.append(f"{action.capitalize()} the {ingredient.name}.")
    return list(dict.fromkeys(prep_steps))


def parse_json_ld_recipes(soup: BeautifulSoup) -> list[dict[str, Any]]:
    recipes: list[dict[str, Any]] = []
    for script in soup.find_all("script", attrs={"type": "application/ld+json"}):
        text = script.get_text(strip=True)
        if not text:
            continue
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            continue
        stack: list[Any] = [data]
        while stack:
            cur = stack.pop()
            if isinstance(cur, list):
                stack.extend(cur)
            elif isinstance(cur, dict):
                typ = cur.get("@type")
                if isinstance(typ, list):
                    is_recipe = "Recipe" in typ
                else:
                    is_recipe = typ == "Recipe"
                if is_recipe:
                    recipes.append(cur)
                stack.extend(cur.values())
    return recipes


def parse_servings(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, float):
        out = int(round(value))
        return out if out > 0 else None
    if isinstance(value, list):
        for item in value:
            parsed = parse_servings(item)
            if parsed:
                return parsed
        return None
    if isinstance(value, str):
        match = re.search(r"\d+", value)
        if match:
            num = int(match.group(0))
            return num if num > 0 else None
    return None


def parse_instructions(value: Any) -> list[str]:
    steps: list[str] = []
    if isinstance(value, str):
        text = value.strip()
        if text:
            steps.append(text)
        return steps
    if isinstance(value, list):
        for item in value:
            steps.extend(parse_instructions(item))
        return steps
    if isinstance(value, dict):
        if "text" in value and isinstance(value["text"], str):
            text = value["text"].strip()
            if text:
                steps.append(text)
        elif "itemListElement" in value:
            steps.extend(parse_instructions(value["itemListElement"]))
    return steps


def _extract_section_list(soup: BeautifulSoup, heading_text: str) -> list[str]:
    heading = soup.find(
        lambda tag: tag.name in {"h1", "h2", "h3", "h4"} and heading_text.lower() in tag.get_text(" ", strip=True).lower()
    )
    if not heading:
        return []
    items: list[str] = []
    for node in heading.find_all_next():
        if node.name in {"h1", "h2", "h3", "h4"} and node is not heading:
            break
        if node.name in {"li", "p"}:
            text = node.get_text(" ", strip=True)
            if text:
                items.append(text)
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def extract_recipe_url_candidates(text: str) -> list[str]:
    return re.findall(r"https://www\.bbcgoodfood\.com/recipes/[a-z0-9-]+/?|/recipes/[a-z0-9-]+/?", text)


def normalize_recipe_url(url: str, base_url: str) -> str | None:
    absolute = urljoin(base_url, url)
    parsed = urlparse(absolute)
    if parsed.netloc != "www.bbcgoodfood.com":
        return None
    if not RECIPE_PATH_RE.match(parsed.path):
        return None
    return f"https://www.bbcgoodfood.com{parsed.path.rstrip('/')}"


def fetch_text(client: httpx.Client, url: str, retries: int = 3) -> str:
    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            response = client.get(url)
            response.raise_for_status()
            return response.text
        except (httpx.HTTPError, httpx.TimeoutException) as exc:
            last_err = exc
            if attempt < retries:
                time.sleep(0.6 * attempt)
    raise RuntimeError(f"Failed to fetch {url}: {last_err}")


def collect_recipe_urls(client: httpx.Client, collection_urls: list[str]) -> list[str]:
    discovered: set[str] = set()
    for collection_url in collection_urls:
        html = fetch_text(client, collection_url)
        soup = BeautifulSoup(html, "html.parser")

        for anchor in soup.select("a[href*='/recipes/']"):
            href = anchor.get("href")
            if not href:
                continue
            normalized = normalize_recipe_url(href, collection_url)
            if normalized:
                discovered.add(normalized)

        for script in soup.find_all("script"):
            content = script.get_text(" ", strip=True)
            if not content:
                continue
            for raw_url in extract_recipe_url_candidates(content):
                normalized = normalize_recipe_url(raw_url, collection_url)
                if normalized:
                    discovered.add(normalized)
    return sorted(discovered)


def parse_recipe_page(source_url: str, html: str, servings_target: int) -> RecipeOut | None:
    soup = BeautifulSoup(html, "html.parser")
    recipe_ld = parse_json_ld_recipes(soup)
    primary = recipe_ld[0] if recipe_ld else {}

    title = ""
    if isinstance(primary.get("name"), str):
        title = primary["name"].strip()
    if not title and soup.title:
        title = soup.title.get_text(" ", strip=True).replace(" recipe | Good Food", "").strip()
    if not title:
        title = "Untitled recipe"

    servings_original = parse_servings(primary.get("recipeYield"))
    if servings_original is None:
        body_text = soup.get_text(" ", strip=True)
        serv_match = re.search(r"\bserves?\s+(\d+)\b", body_text, flags=re.IGNORECASE)
        if serv_match:
            servings_original = int(serv_match.group(1))

    ingredients_raw: list[str] = []
    if isinstance(primary.get("recipeIngredient"), list):
        ingredients_raw = [str(x).strip() for x in primary["recipeIngredient"] if str(x).strip()]
    if not ingredients_raw:
        ingredients_raw = _extract_section_list(soup, "Ingredients")

    steps = parse_instructions(primary.get("recipeInstructions"))
    if not steps:
        steps = _extract_section_list(soup, "Method")

    if not ingredients_raw or not steps:
        return None

    ingredients: list[IngredientOut] = []
    for raw in ingredients_raw:
        amount_value, amount_unit = parse_measurable_amount(raw)
        ingredient = IngredientOut(
            raw=raw,
            scaled_raw=scale_ingredient(raw=raw, servings_original=servings_original, servings_target=servings_target),
            name=normalize_ingredient_name(raw),
            amount_value=amount_value,
            amount_unit=amount_unit,
            prep_actions=extract_prep_actions(raw),
        )
        ingredients.append(ingredient)

    prep_steps = build_prep_steps(ingredients=ingredients, steps=steps)
    if prep_steps:
        steps = prep_steps + steps

    candidate = RecipeOut(
        source_url=source_url,
        title=title,
        servings_original=servings_original,
        servings_target=servings_target,
        ingredients=ingredients,
        steps=steps,
    )
    return candidate


@app.command("run")
def run(
    out: Path = typer.Option(
        Path(".cache/bbc_goodfood_recipes.json"),
        "--out",
        help="Output JSON file path (single JSON array).",
    ),
    target_servings: int = typer.Option(2, "--target-servings", min=1, help="Target servings for scaled ingredients."),
    max_recipes: Optional[int] = typer.Option(None, "--max-recipes", min=1, help="Optional cap for test runs."),
    pause_seconds: float = typer.Option(0.2, "--pause-seconds", min=0.0, help="Delay between recipe requests."),
) -> None:
    headers = {
        "user-agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        )
    }
    timeout = httpx.Timeout(30.0, connect=10.0, read=30.0, write=10.0, pool=10.0)

    with httpx.Client(headers=headers, timeout=timeout, follow_redirects=True) as client:
        recipe_urls = collect_recipe_urls(client, COLLECTION_URLS)
        if max_recipes:
            recipe_urls = recipe_urls[:max_recipes]

        parsed: list[RecipeOut] = []
        for idx, recipe_url in enumerate(recipe_urls, start=1):
            try:
                html = fetch_text(client, recipe_url)
                record = parse_recipe_page(source_url=recipe_url, html=html, servings_target=target_servings)
                if record:
                    parsed.append(record)
            except Exception as exc:  # noqa: BLE001
                typer.echo(f"[warn] failed recipe ({idx}/{len(recipe_urls)}): {recipe_url} -> {exc}")
            if pause_seconds > 0:
                time.sleep(pause_seconds)

    payload = [row.model_dump(mode="json") for row in parsed]
    atomic_write_bytes(out, _pretty_dumps(payload))
    typer.echo(f"Wrote: {out}")
    typer.echo(f"Collection URLs: {len(COLLECTION_URLS)}")
    typer.echo(f"Recipe URLs discovered: {len(recipe_urls)}")
    typer.echo(f"Recipes parsed: {len(parsed)}")


def main() -> None:
    app()


if __name__ == "__main__":
    main()
