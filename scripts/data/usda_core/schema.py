from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .utils import canonical, dedupe_keep_order

CategoryLabel = Literal[
    "protein",
    "vegetable",
    "fruit",
    "grain_legume",
    "dairy_egg",
    "oil_fat",
    "herb_spice",
    "nut_seed",
    "fungi",
    "condiment",
    "sweetener_baking",
    "other",
]


class MacroSet(BaseModel):
    model_config = ConfigDict(extra="forbid")

    calories: float = 0.0
    protein_g: float = 0.0
    carbs_g: float = 0.0
    fat_g: float = 0.0
    fiber_g: float = 0.0
    sugar_g: float = 0.0
    sodium_g: float = 0.0

    @field_validator("calories", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sodium_g")
    @classmethod
    def _round_values(cls, value: float) -> float:
        return round(float(value), 4)


class SourceMeta(BaseModel):
    model_config = ConfigDict(extra="forbid")

    data_type: str = ""
    food_category: str = ""
    verified_at_utc: str = ""
    verification_source: str = "USDA FoodData Central API"


class CuratedIngredientRow(BaseModel):
    model_config = ConfigDict(extra="forbid")

    fdc_id: int
    display_name: str
    alt_names: list[str] = Field(default_factory=list)
    category_label: CategoryLabel
    sprite_group: str = "other"
    sprite_key: str = ""
    description: str = ""
    source_description: str = ""
    source_meta: SourceMeta
    macros: MacroSet

    @field_validator("display_name", "description", "source_description")
    @classmethod
    def _strip_strings(cls, value: str) -> str:
        return value.strip()

    @field_validator("category_label", mode="before")
    @classmethod
    def _normalize_category_label(cls, value: Any) -> str:
        text = canonical(str(value or "other")).replace(" ", "_")
        text = text.replace("-", "_")
        alias_map = {
            "grainlegume": "grain_legume",
            "dairyegg": "dairy_egg",
            "oilfat": "oil_fat",
            "herbspice": "herb_spice",
            "nutseed": "nut_seed",
            "sweetener": "sweetener_baking",
            "sweetenerbaking": "sweetener_baking",
        }
        return alias_map.get(text.replace("_", ""), text)

    @field_validator("alt_names")
    @classmethod
    def _normalize_aliases(cls, value: list[str]) -> list[str]:
        return dedupe_keep_order([v for v in value if isinstance(v, str) and v.strip()])

    @field_validator("sprite_group")
    @classmethod
    def _normalize_sprite_group(cls, value: str) -> str:
        return canonical(value).replace(" ", "_") or "other"

    @field_validator("sprite_key")
    @classmethod
    def _normalize_sprite_key(cls, value: str) -> str:
        return canonical(value)


class CanonicalCatalog(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: str = "v2"
    generated_at_utc: str
    records: list[CuratedIngredientRow]


class BatchRow(BaseModel):
    model_config = ConfigDict(extra="forbid")

    action: Literal["upsert", "drop"] = "upsert"
    row: CuratedIngredientRow
    review_notes: str = ""


class BatchPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    batch_id: int
    batch_size: int
    records: list[BatchRow]


def row_to_search_text(row: CuratedIngredientRow) -> str:
    corpus = [
        canonical(row.display_name),
        canonical(row.description),
        canonical(row.source_description),
        *[canonical(a) for a in row.alt_names],
    ]
    return " | ".join(dedupe_keep_order(corpus))


def existing_macro_map(catalog: CanonicalCatalog) -> dict[int, MacroSet]:
    return {row.fdc_id: row.macros for row in catalog.records}


def macros_equal(a: MacroSet, b: MacroSet, epsilon: float = 1e-6) -> bool:
    return (
        abs(a.calories - b.calories) <= epsilon
        and abs(a.protein_g - b.protein_g) <= epsilon
        and abs(a.carbs_g - b.carbs_g) <= epsilon
        and abs(a.fat_g - b.fat_g) <= epsilon
        and abs(a.fiber_g - b.fiber_g) <= epsilon
        and abs(a.sugar_g - b.sugar_g) <= epsilon
        and abs(a.sodium_g - b.sodium_g) <= epsilon
    )


def from_dict(payload: dict[str, Any]) -> CanonicalCatalog:
    return CanonicalCatalog.model_validate(payload)
