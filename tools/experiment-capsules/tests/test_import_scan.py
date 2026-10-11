"""Import-coverage tests: static resolution, dynamic constructs, gaps."""

from capsule_model import parse_binding
from import_scan import analyze_binding_sources, scan_source


def scan(text):
    observations, err = scan_source(text, "x.py")
    assert err is None, err
    return observations


def test_stdlib_import_is_static():
    obs = scan("import json\nimport os.path\n")
    assert [(o.module_head, o.kind) for o in obs] == [("json", "static"), ("os", "static")]


def test_from_import_records_head():
    obs = scan("from decimal import Decimal\n")
    assert obs[0].module_head == "decimal"
    assert obs[0].kind == "static"


def test_dynamic_import_with_fstring_is_dynamic():
    obs = scan("import importlib\nimportlib.import_module(f'codec_{name}')\n")
    assert [o.kind for o in obs] == ["static", "dynamic"]


def test_dynamic_import_with_literal_is_knowable():
    obs = scan("importlib.import_module('codec_alpha')\n")
    assert obs[0].kind == "static"
    assert obs[0].module_head == "codec_alpha"


def test_builtin_import_is_dynamic_when_not_literal():
    obs = scan("name = 'x'\n__import__(name)\n")
    assert any(o.kind == "dynamic" for o in obs)


def test_syntax_error_is_returned_not_raised():
    observations, err = scan_source("def broken(:\n", "bad.py")
    assert observations == []
    assert err is not None and "line 1" in err


# ---------------------------------------------------------------------------
# analyze_binding_sources over a synthetic repo layout
# ---------------------------------------------------------------------------

MAIN_PLAIN = "import helper\n"
MAIN_DYNAMIC = (
    "import importlib\n\n\ndef load(name):\n"
    "    return importlib.import_module(f'accel_{name}')\n"
)


def build_repo(tmp_path, main_text, helper_text=None, declared_helper=True, gaps=(), deps=()):
    (tmp_path / "src").mkdir(parents=True, exist_ok=True)
    (tmp_path / "src" / "main.py").write_text(main_text, encoding="utf-8")
    if helper_text is not None:
        (tmp_path / "src" / "helper.py").write_text(helper_text, encoding="utf-8")
    sources = [
        {"path": "src/main.py", "role": "source", "sha256": "a" * 64},
    ]
    if declared_helper:
        sources.append({"path": "src/helper.py", "role": "import", "sha256": "b" * 64})
    raw = {
        "schema_version": "1",
        "capsule_id": "synthetic",
        "title": "t",
        "owner": "o",
        "sources": sources,
        "toolchain": {
            "language": "python",
            "language_version": "3.13.14",
            "dependencies": list(deps),
        },
        "permitted_inputs": ["data/in.csv"],
        "model_transport": {"mode": "offline-deterministic"},
        "coverage_gaps": list(gaps),
        "outputs": [{"path": "out/t.txt", "sha256": "c" * 64, "bytes": 1}],
    }
    binding, findings = parse_binding(raw)
    assert binding is not None, findings
    return binding


def codes(findings):
    return [f.code for f in findings]


def test_declared_local_import_is_covered(tmp_path):
    binding = build_repo(tmp_path, MAIN_PLAIN, helper_text="x = 1\n")
    assert analyze_binding_sources(binding, tmp_path) == []


def test_undeclared_local_import_is_reported(tmp_path):
    binding = build_repo(tmp_path, MAIN_PLAIN, helper_text="x = 1\n", declared_helper=False)
    findings = analyze_binding_sources(binding, tmp_path)
    assert codes(findings) == ["undeclared-import"]
    assert "src/helper.py" in findings[0].detail


def test_absent_helper_is_the_checkers_job(tmp_path):
    binding = build_repo(tmp_path, MAIN_PLAIN, helper_text=None)
    assert analyze_binding_sources(binding, tmp_path) == []


def test_dynamic_import_without_gap_is_reported(tmp_path):
    binding = build_repo(tmp_path, MAIN_DYNAMIC, helper_text=None)
    findings = analyze_binding_sources(binding, tmp_path)
    assert codes(findings) == ["undeclared-dynamic-import"]
    assert "no declared coverage gap" in findings[0].detail


def test_dynamic_import_with_declared_gap_is_accepted(tmp_path):
    gaps = [{"file": "src/main.py", "reason": "target computed at runtime"}]
    binding = build_repo(tmp_path, MAIN_DYNAMIC, helper_text=None, gaps=gaps)
    assert analyze_binding_sources(binding, tmp_path) == []


def test_external_dependency_must_be_declared(tmp_path):
    binding = build_repo(tmp_path, "import requests\n", helper_text=None)
    findings = analyze_binding_sources(binding, tmp_path)
    assert codes(findings) == ["undeclared-dependency"]


def test_declared_external_dependency_is_accepted(tmp_path):
    binding = build_repo(tmp_path, "import requests\n", helper_text=None, deps=["requests"])
    assert analyze_binding_sources(binding, tmp_path) == []


def test_relative_import_resolved_and_checked(tmp_path):
    pkg = tmp_path / "src" / "pkg"
    pkg.mkdir(parents=True)
    (pkg / "main.py").write_text("from . import sibling\n", encoding="utf-8")
    (pkg / "sibling.py").write_text("x = 1\n", encoding="utf-8")
    raw = {
        "schema_version": "1",
        "capsule_id": "synthetic",
        "title": "t",
        "owner": "o",
        "sources": [{"path": "src/pkg/main.py", "role": "source", "sha256": "a" * 64}],
        "toolchain": {"language": "python", "language_version": "3.13.14", "dependencies": []},
        "permitted_inputs": ["data/in.csv"],
        "model_transport": {"mode": "offline-deterministic"},
        "coverage_gaps": [],
        "outputs": [{"path": "out/t.txt", "sha256": "c" * 64, "bytes": 1}],
    }
    binding, findings = parse_binding(raw)
    assert binding is not None, findings
    result = analyze_binding_sources(binding, tmp_path)
    assert codes(result) == ["undeclared-import"]
    assert "src/pkg/sibling.py" in result[0].detail
