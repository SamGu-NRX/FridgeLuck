from __future__ import annotations

import json
import os
import re
import tempfile
import time
import unicodedata
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

# Countable unit words that appear between quantity and ingredient name
# ("2 cloves garlic", "2 piece onion") but are not measures; they are
# stripped from the name like measure words.
COUNT_UNIT_WORDS = {
    "piece",
    "pieces",
    "clove",
    "cloves",
    "sprig",
    "sprigs",
    "slice",
    "slices",
    "stalk",
    "stalks",
    "leaf",
    "leaves",
    "head",
    "heads",
    "bunch",
    "bunches",
    "handful",
    "handfuls",
    "strip",
    "strips",
    "wedge",
    "wedges",
    "rasher",
    "rashers",
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

RECIPE_TAG_BITS: dict[str, int] = {
    "quick": 0,
    "vegetarian": 1,
    "vegan": 2,
    "asian": 3,
    "breakfast": 4,
    "budget": 5,
    "comfort": 6,
    "mediterranean": 7,
    "mexican": 8,
    "high_protein": 9,
    "low_carb": 10,
    "one_pot": 11,
}


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
        # Wikibooks lines place the conversion before the name:
        # "1 cup (240 g / 8.5 oz) butter" -> "butter". Splitting on "(" later
        # would otherwise truncate at the parenthesis and yield an empty name.
        compact = re.sub(r"^\([^)]*\)\s*", "", compact, count=1)
        count_word = re.match(r"^(?P<unit>[a-zA-Z]+)\b", compact)
        if count_word and count_word.group("unit").lower() in COUNT_UNIT_WORDS:
            # "2 cloves garlic" / "2 piece onion": drop the count unit word
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


def _canonical_text(text: str) -> str:
    normalized = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    normalized = normalized.replace("_", " ").replace("-", " ")
    normalized = re.sub(r"[^a-zA-Z0-9\s]", " ", normalized).lower()
    return re.sub(r"\s+", " ", normalized).strip()


def _singularize_word(word: str) -> str:
    if word.endswith("ies") and len(word) > 4:
        return f"{word[:-3]}y"
    if word.endswith("oes") and len(word) > 4:
        return word[:-2]
    if word.endswith("s") and not word.endswith("ss") and len(word) > 3:
        return word[:-1]
    return word


def _canonical_name_variants(name: str) -> set[str]:
    base = _canonical_text(name)
    if not base:
        return {""}
    words = base.split()
    singular_words = [_singularize_word(w) for w in words]
    variants = {base, " ".join(singular_words).strip()}
    # A bare last-word variant ("oil" from "sesame oil") leaked generic words
    # into the ingredient index and cross-mapped catalog ids ("extra virgin
    # olive oil" -> sesame oil); keep full-phrase variants only.
    return {v for v in variants if v}


def _build_ingredient_index(data_payload: dict[str, Any]) -> dict[str, int]:
    index: dict[str, int] = {}
    for id_str, ingredient_array in data_payload.get("ingredients", {}).items():
        if not isinstance(ingredient_array, list) or not ingredient_array:
            continue
        name = str(ingredient_array[0])
        for key in _canonical_name_variants(name):
            index[key] = int(id_str)
    return index


def _build_existing_recipe_title_keys(data_payload: dict[str, Any]) -> set[str]:
    titles: set[str] = set()
    for row in data_payload.get("recipes", []):
        if isinstance(row, list) and len(row) >= 2:
            titles.add(_canonical_text(str(row[1])))
    return titles


def _extract_source_url_from_instructions(instructions: Any) -> str | None:
    if not isinstance(instructions, str):
        return None
    first_line = instructions.splitlines()[0].strip() if instructions else ""
    match = re.match(r"^Source:\s*(https?://\S+)\s*$", first_line, flags=re.IGNORECASE)
    if not match:
        return None
    return match.group(1).rstrip("/")


def _build_existing_recipe_source_urls(data_payload: dict[str, Any]) -> set[str]:
    urls: set[str] = set()
    for row in data_payload.get("recipes", []):
        if not isinstance(row, list) or len(row) < 7:
            continue
        source_url = _extract_source_url_from_instructions(row[6])
        if source_url:
            urls.add(source_url)
    return urls


def _validate_bundled_data_shape(data_payload: dict[str, Any]) -> None:
    if not isinstance(data_payload, dict):
        raise typer.BadParameter("Bundled data must be a JSON object.")

    ingredients = data_payload.get("ingredients")
    recipes = data_payload.get("recipes")
    tags = data_payload.get("tags")
    if not isinstance(ingredients, dict):
        raise typer.BadParameter("Bundled data 'ingredients' must be an object keyed by ID.")
    if not isinstance(recipes, list):
        raise typer.BadParameter("Bundled data 'recipes' must be an array.")
    if not isinstance(tags, list):
        raise typer.BadParameter("Bundled data 'tags' must be an array.")

    for id_key, ingredient_array in ingredients.items():
        if not str(id_key).isdigit():
            raise typer.BadParameter(f"Ingredient key '{id_key}' is not numeric.")
        if not isinstance(ingredient_array, list) or len(ingredient_array) < 10:
            raise typer.BadParameter(
                f"Ingredient '{id_key}' must be an array with at least 10 fields."
            )

    for idx, row in enumerate(recipes):
        if not isinstance(row, list) or len(row) < 8:
            raise typer.BadParameter(
                f"Recipe row at index {idx} is not compatible with GRDB seed shape."
            )


def _resolve_ingredient_id(name: str, index: dict[str, int]) -> int | None:
    alias_map = {
        "spring onion": "green onion",
        "spring onions": "green onion",
        "scallion": "green onion",
        "scallions": "green onion",
        "red pepper": "bell pepper",
        "red peppers": "bell pepper",
        "courgette": "zucchini",
        "courgettes": "zucchini",
        "chilli flakes": "red pepper flakes",
        "chili flakes": "red pepper flakes",
        "chilies": "red pepper flakes",
        "chillies": "red pepper flakes",
        "garlic clove": "garlic",
        "garlic cloves": "garlic",
        "chickpeas": "chickpea",
        "black beans": "black beans",
        "tuna": "canned tuna",
        "extra virgin olive oil": "olive oil",
        "virgin olive oil": "olive oil",
        "tinned tomatoes": "tomato",
        "tinned tomato": "tomato",
        "chopped tomatoes": "tomato",
        "chopped tomato": "tomato",
        "plum tomatoes": "tomato",
        "plum tomato": "tomato",
        "cherry tomatoes": "tomato",
        "cherry tomato": "tomato",
        "canned tomatoes": "tomato",
        "tomatoes": "tomato",
        "minced beef": "ground beef",
        "yellow pepper": "bell pepper",
        "yellow peppers": "bell pepper",
        "orange pepper": "bell pepper",
        "orange peppers": "bell pepper",
        "green pepper": "bell pepper",
        "green peppers": "bell pepper",
        "red onion": "onion",
        "red onions": "onion",
        "white onion": "onion",
        "white onions": "onion",
        "brown onion": "onion",
        "brown onions": "onion",
        "yellow onion": "onion",
        "yellow onions": "onion",
        "sweetcorn": "corn",
        "canned chickpeas": "chickpea",
        "greek yogurt": "yogurt",
        "greek yoghurt": "yogurt",
        "plain yogurt": "yogurt",
        "natural yogurt": "yogurt",
        "baby spinach": "spinach",
        "new potatoes": "potato",
        "new potato": "potato",
        "baking potatoes": "potato",
        "baking potato": "potato",
    }
    variants = _canonical_name_variants(name)
    for variant in variants:
        if variant in index:
            return index[variant]
    for variant in variants:
        mapped = alias_map.get(variant)
        if mapped:
            mapped_key = _canonical_text(mapped)
            if mapped_key in index:
                return index[mapped_key]
    return None


_VOLUME_UNIT_GRAMS: dict[str, float] = {
    "cup": 240.0,
    "cups": 240.0,
    "tbsp": 15.0,
    "tablespoon": 15.0,
    "tablespoons": 15.0,
    "tsp": 5.0,
    "teaspoon": 5.0,
    "teaspoons": 5.0,
    "oz": 28.35,
    "ounce": 28.35,
    "ounces": 28.35,
    "lb": 453.6,
    "lbs": 453.6,
    "pound": 453.6,
    "pounds": 453.6,
    "stick": 113.0,
    "sticks": 113.0,
    "pint": 473.0,
    "pints": 473.0,
    "quart": 946.0,
    "quarts": 946.0,
}


def _parenthetical_grams(text: str) -> float | None:
    """Metric/imperial mass stated in parentheses, e.g. '1 cup (240 g / 8.5 oz)'.

    Wikibooks lines carry conversions this way; the first number+unit pair
    inside the parens is the most precise estimate available.
    """
    for inner in re.findall(r"\(([^)]*)\)", text):
        match = re.search(r"(?P<qty>\d+(?:\.\d+)?)\s*(?P<unit>kg|g|ml|l|oz|lb)\b", inner, flags=re.IGNORECASE)
        if not match:
            continue
        unit = match.group("unit").lower()
        qty = float(match.group("qty"))
        factor = {"g": 1.0, "kg": 1000.0, "ml": 1.0, "l": 1000.0, "oz": 28.35, "lb": 453.6}[unit]
        return qty * factor
    return None


def _estimate_grams(ingredient: IngredientOut) -> float:
    if ingredient.amount_value and ingredient.amount_value > 0:
        if ingredient.amount_unit in {"g", "ml"}:
            return float(ingredient.amount_value)

    scaled = ingredient.scaled_raw or ""

    paren_grams = _parenthetical_grams(scaled)
    if paren_grams is not None and paren_grams > 0:
        return min(1000.0, max(5.0, paren_grams))

    qty, rest = parse_leading_quantity(scaled)
    if qty is None or qty <= 0:
        return 50.0

    # Use the unit after the quantity ("1 cup milk" -> 240 g) instead of
    # discarding it; metric units come from UNIT_NORMALIZATION, kitchen
    # units from _VOLUME_UNIT_GRAMS.
    rest_lower = rest.lower()
    if rest_lower.startswith("fl oz"):
        factor = 29.57
    else:
        unit_match = re.match(r"^(?P<unit>[a-zA-Z]+)\b", rest)
        unit_word = unit_match.group("unit").lower().rstrip(".") if unit_match else ""
        unit_data = _normalize_unit(unit_word)
        factor = unit_data[1] if unit_data else _VOLUME_UNIT_GRAMS.get(unit_word)
    if factor:
        return min(1000.0, max(5.0, float(qty) * factor))

    single_unit_grams = {
        "egg": 50.0,
        "onion": 110.0,
        "garlic": 3.0,
        "tomato": 123.0,
        "pepper": 119.0,
        "potato": 150.0,
        "sweet potato": 114.0,
        "carrot": 61.0,
        "banana": 118.0,
        "apple": 182.0,
        "avocado": 150.0,
        "bread": 30.0,
        "tortilla": 45.0,
        "lemon": 58.0,
        "lime": 67.0,
    }

    canonical_name = _canonical_text(ingredient.name)
    per_unit = 50.0
    for key, grams in single_unit_grams.items():
        # word-boundary match: "egg" must not hit "eggplant"
        if re.search(rf"\b{re.escape(key)}\b", canonical_name):
            per_unit = grams
            break
    estimated = qty * per_unit
    return min(1000.0, max(5.0, estimated))


def _infer_tag_bitmask(recipe: RecipeOut) -> int:
    title = _canonical_text(recipe.title)
    ingredient_blob = " ".join(_canonical_text(ing.name) for ing in recipe.ingredients)
    corpus = f"{title} {ingredient_blob} {_canonical_text(recipe.source_url)}"

    bits = 0
    if recipe.steps and len(recipe.steps) <= 6:
        bits |= 1 << RECIPE_TAG_BITS["quick"]
    if any(k in corpus for k in ["quick", "10 minute", "15 minute"]) or len(recipe.steps) <= 5:
        bits |= 1 << RECIPE_TAG_BITS["quick"]

    # Word-boundary matching with explicit inflections: the old substring
    # tokens matched "egg" inside "eggplant" and missed whole families
    # (stocks, cured pork, fish sauce, ghee, paneer, ...).
    animal_re = re.compile(
        r"\b(chicken|beef|pork|lamb|veal|turkey|duck|bacon|pancetta|prosciutto|"
        r"chorizo|salami|pepperoni|sausage|sausages|mince|minced|meat|meatball|"
        r"meatballs|steak|anchovy|anchovies|fish|tuna|salmon|cod|haddock|"
        r"mackerel|sardine|sardines|trout|bass|shrimp|prawn|prawns|crab|crabs|"
        r"lobster|squid|clam|clams|mussel|mussels|scallop|scallops|octopus|"
        r"oyster|marrow|stock|stocks|broth|broths|gelatin|gelatine|lard|"
        r"dripping|drippings|worcestershire|bonito|dashi|jerky)\b"
    )
    # Plant-based lookalikes (coconut milk/cream, nut butters, soy/oat milk)
    # must not count as animal products.
    milk_guard = r"(?<!coconut )(?<!soy )(?<!oat )(?<!almond )(?<!rice )"
    butter_guard = r"(?<!peanut )(?<!almond )(?<!cashew )(?<!cocoa )(?<!shea )"
    dairy_egg_re = re.compile(
        "|".join(
            [
                milk_guard + r"\bmilk\b",
                r"(?<!coconut )\bcream(ed)?\b",
                butter_guard + r"\bbutter\b",
                r"\b(eggs?|mayonnaise|mayo|buttermilk|crema|ghee|cheeses?|"
                r"yogurt|yoghurt|kefir|honey|whey|paneer|halloumi|mozzarella|"
                r"feta|mascarpone|ricotta|custard)\b",
            ]
        )
    )

    has_animal = bool(animal_re.search(corpus))
    has_dairy_or_egg = bool(dairy_egg_re.search(corpus))
    if not has_animal:
        bits |= 1 << RECIPE_TAG_BITS["vegetarian"]
    if not has_animal and not has_dairy_or_egg:
        bits |= 1 << RECIPE_TAG_BITS["vegan"]

    if any(k in corpus for k in ["noodle", "soy", "miso", "udon", "satay", "stir fry", "jalfrezi", "korma", "madras"]):
        bits |= 1 << RECIPE_TAG_BITS["asian"]
    if any(k in corpus for k in ["breakfast", "omelette", "oats", "toast", "frittata", "pancake"]):
        bits |= 1 << RECIPE_TAG_BITS["breakfast"]
    if any(k in corpus for k in ["budget", "cheap"]):
        bits |= 1 << RECIPE_TAG_BITS["budget"]
    if any(k in corpus for k in ["soup", "stew", "bake", "risotto", "curry", "ragu"]):
        bits |= 1 << RECIPE_TAG_BITS["comfort"]
    if any(k in corpus for k in ["mediterranean", "feta", "couscous", "hummus", "tzatziki", "halloumi"]):
        bits |= 1 << RECIPE_TAG_BITS["mediterranean"]
    if any(k in corpus for k in ["mexican", "taco", "burrito", "enchilada", "guacamole", "salsa"]):
        bits |= 1 << RECIPE_TAG_BITS["mexican"]
    if any(k in corpus for k in ["chicken", "tuna", "salmon", "tofu", "egg", "beef", "bean", "chickpea"]):
        bits |= 1 << RECIPE_TAG_BITS["high_protein"]
    if not any(k in corpus for k in ["rice", "pasta", "bread", "tortilla", "potato", "oat", "couscous"]):
        bits |= 1 << RECIPE_TAG_BITS["low_carb"]
    if any(k in corpus for k in ["one pot", "one pan", "stew", "soup", "curry", "chilli", "chili"]):
        bits |= 1 << RECIPE_TAG_BITS["one_pot"]

    return bits


def _format_instruction_block(source_url: str, steps: list[str]) -> str:
    lines = [f"Source: {source_url}"]
    for idx, step in enumerate(steps, start=1):
        text = re.sub(r"\s+", " ", step).strip()
        if not text:
            continue
        lines.append(f"{idx}. {text}")
    return "\n".join(lines).strip()


def _build_override_index(path: Optional[Path]) -> dict[str, str]:
    """Map canonical titles / normalized source URLs -> override note."""
    if path is None:
        return {}
    entries = orjson.loads(path.read_bytes())
    if not isinstance(entries, list):
        raise ValueError("Overrides file must be a JSON array of {title|source_url, note} objects.")
    index: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Overrides entries must be JSON objects.")
        note = str(entry.get("note", "manual override"))
        title = entry.get("title")
        if isinstance(title, str) and title.strip():
            index[_canonical_text(title)] = note
        url = entry.get("source_url")
        if isinstance(url, str) and url.strip():
            index[url.rstrip("/")] = note
    return index


@app.command("merge-grdb")
def merge_grdb(
    scraped: Path = typer.Option(
        Path(".cache/bbc_goodfood_recipes.json"),
        "--scraped",
        help="Scraped BBC JSON file (output of scrape-recipes run).",
    ),
    bundled_data: Path = typer.Option(
        Path("../../apps/ios/Resources/data.json"),
        "--bundled-data",
        help="Existing bundled data.json to merge into.",
    ),
    out: Path = typer.Option(
        Path(".cache/data.merged.non_destructive.json"),
        "--out",
        help="Output merged JSON path (non-destructive).",
    ),
    report_out: Path = typer.Option(
        Path(".cache/merge_report.json"),
        "--report-out",
        help="Path for merge diagnostics report.",
    ),
    overrides: Optional[Path] = typer.Option(
        None,
        "--overrides",
        help=(
            "Optional JSON file of force-include entries, "
            '[{"title" or "source_url": ..., "note": "why"}]. Only recipes rejected '
            "for too_few_mapped_required_ingredients can be forced in; duplicate-title "
            "and blank-title rejections cannot be overridden."
        ),
    ),
    min_required_matches: int = typer.Option(
        2,
        "--min-required-matches",
        min=1,
        help="Minimum number of mapped required ingredients to keep a recipe.",
    ),
    in_place: bool = typer.Option(
        False,
        "--in-place",
        help="Overwrite bundled-data directly. Off by default for safety.",
    ),
) -> None:
    scraped_payload = orjson.loads(scraped.read_bytes())
    source_data = orjson.loads(bundled_data.read_bytes())
    _validate_bundled_data_shape(source_data)

    ingredient_index = _build_ingredient_index(source_data)
    existing_title_keys = _build_existing_recipe_title_keys(source_data)
    existing_source_urls = _build_existing_recipe_source_urls(source_data)
    existing_recipe_rows = source_data.get("recipes", [])
    existing_ids = [int(row[0]) for row in existing_recipe_rows if isinstance(row, list) and row]
    if len(existing_ids) != len(set(existing_ids)):
        raise typer.BadParameter("Bundled data has duplicate recipe IDs; aborting merge safely.")
    next_recipe_id = (max(existing_ids) + 1) if existing_ids else 1

    accepted_rows: list[list[Any]] = []
    rejected: list[dict[str, Any]] = []
    review: list[dict[str, Any]] = []
    overridden: list[dict[str, Any]] = []
    unmatched_ingredients: dict[str, int] = {}
    override_index = _build_override_index(overrides)

    for raw_item in scraped_payload:
        recipe = RecipeOut.model_validate(raw_item)
        title_key = _canonical_text(recipe.title)
        normalized_source_url = recipe.source_url.rstrip("/")
        if not title_key:
            rejected.append({"title": recipe.title, "source_url": recipe.source_url, "reasons": ["blank_title"]})
            continue
        if title_key in existing_title_keys:
            # duplicate titles and source URLs are structural: they would collide
            # with seed identity, so no override applies
            rejected.append({"title": recipe.title, "source_url": recipe.source_url, "reasons": ["duplicate_title"]})
            continue
        if normalized_source_url in existing_source_urls:
            rejected.append({"title": recipe.title, "source_url": recipe.source_url, "reasons": ["duplicate_source_url"]})
            continue

        required: list[list[Any]] = []
        optional: list[list[Any]] = []
        used_ids: set[int] = set()
        for ing in recipe.ingredients:
            ingredient_id = _resolve_ingredient_id(ing.name, ingredient_index)
            if ingredient_id is None:
                key = _canonical_text(ing.name)
                if key:
                    unmatched_ingredients[key] = unmatched_ingredients.get(key, 0) + 1
                continue
            if ingredient_id in used_ids:
                continue
            used_ids.add(ingredient_id)
            grams = _estimate_grams(ing)
            pair = [ingredient_id, int(round(grams))]
            if "optional" in ing.raw.lower():
                optional.append(pair)
            else:
                required.append(pair)

        if len(required) < min_required_matches:
            entry = {
                "title": recipe.title,
                "source_url": recipe.source_url,
                "reasons": ["too_few_mapped_required_ingredients"],
                "mapped_required_count": len(required),
            }
            note = override_index.get(title_key) or override_index.get(normalized_source_url)
            if note:
                entry["overridden"] = True
                overridden.append({**entry, "note": note})
            else:
                rejected.append(entry)
                continue

        flags: list[dict[str, Any]] = []
        default50_count = sum(1 for pair in required if pair[1] == 50)
        if default50_count:
            flags.append({"kind": "default_50g_estimate", "required_count": default50_count})
        total_lines = len(recipe.ingredients)
        unsupported_lines = total_lines - len(required) - len(optional)
        if total_lines and unsupported_lines / total_lines >= 0.5:
            flags.append({"kind": "high_unsupported_share", "unsupported": unsupported_lines, "total": total_lines})
        if not recipe.servings_target or recipe.servings_target <= 0:
            flags.append({"kind": "assumed_servings", "servings": 1})
        if flags:
            review.append({"title": recipe.title, "source_url": recipe.source_url, "flags": flags})

        instructions = _format_instruction_block(recipe.source_url, recipe.steps)
        tag_bitmask = _infer_tag_bitmask(recipe)
        row = [
            next_recipe_id,
            recipe.title,
            max(1, len(recipe.steps) * 5),
            max(1, recipe.servings_target),
            required,
            optional,
            instructions,
            tag_bitmask,
        ]
        accepted_rows.append(row)
        existing_title_keys.add(title_key)
        existing_source_urls.add(normalized_source_url)
        next_recipe_id += 1

    merged_payload = {
        "tags": source_data.get("tags", []),
        "ingredients": source_data.get("ingredients", {}),
        "recipes": [*existing_recipe_rows, *accepted_rows],
    }
    report = {
        "scraped_recipe_count": len(scraped_payload),
        "accepted_recipe_count": len(accepted_rows),
        "rejected_recipe_count": len(rejected),
        "rejected_recipes": rejected,
        "review_recipe_count": len(review),
        "review_recipes": review,
        "overridden_recipe_count": len(overridden),
        "overridden_recipes": overridden,
        "top_unmatched_ingredients": sorted(
            [{"name": name, "count": count} for name, count in unmatched_ingredients.items()],
            key=lambda item: item["count"],
            reverse=True,
        )[:100],
        "notes": [
            "Merge is non-destructive by default: ingredients are untouched and recipes are appended only.",
            "Rejections are structural (blank title, duplicate title, duplicate source URL, or too few mapped required ingredients).",
            "Overrides can force-include recipes rejected only for too_few_mapped_required_ingredients; every forced import is listed under overridden_recipes.",
            "Accepted recipes with heuristic quality flags are listed under review_recipes; they are imported regardless.",
            "Unknown ingredients are reported for later nutrition curation.",
        ],
        "collision_checks": {
            "existing_recipe_id_collisions": len(existing_ids) - len(set(existing_ids)),
            "existing_source_url_count": len(_build_existing_recipe_source_urls(source_data)),
            "accepted_source_url_count": len(existing_source_urls),
        },
    }

    target_path = bundled_data if in_place else out
    atomic_write_bytes(target_path, _pretty_dumps(merged_payload))
    atomic_write_bytes(report_out, _pretty_dumps(report))

    typer.echo(f"Merged recipes written: {target_path}")
    typer.echo(f"Merge report written: {report_out}")
    typer.echo(f"Accepted recipes: {len(accepted_rows)} (review-flagged: {len(review)}, overridden: {len(overridden)})")
    typer.echo(f"Rejected recipes: {len(rejected)}")


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
