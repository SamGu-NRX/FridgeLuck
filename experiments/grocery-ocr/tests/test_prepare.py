"""Unit checks for the input preparation helpers."""
import prepare_inputs


def test_split_items_basic():
    assert prepare_inputs.split_items("tomato paste, water, salt") == [
        "tomato paste", "water", "salt"]


def test_split_items_strips_percents():
    # leading percents are annotation noise; trailing percents stay with the item
    assert prepare_inputs.split_items("20% sugar, milk") == ["sugar", "milk"]
    assert prepare_inputs.split_items("sugar 20%, milk") == ["sugar 20%", "milk"]


def test_name_variants_brand_stripped():
    row = {"product_name": "Barilla Tomato Sauce", "generic_name": "tomato sauce",
           "brands": "Barilla"}
    v = prepare_inputs.name_variants(row)
    assert "Barilla Tomato Sauce" in v and "Tomato Sauce" in v


def test_category_leaf_prefers_last_tag():
    assert prepare_inputs.category_leaf({"categories_tags": "en:food,en:sauces,en:tomato-ketchups"}) \
        == "tomato ketchups"
