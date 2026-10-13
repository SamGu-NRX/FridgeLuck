from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Annotated

import orjson
import typer

from usda_core.batches import export_batch
from usda_core.build_sqlite import build_sqlite
from usda_core.cache_store import CacheStore
from usda_core.candidates import fetch_candidates
from usda_core.client_async import USDAAsyncClient
from usda_core.config import AUDIT_DIR, CACHE_DB, CANONICAL_JSON, CANDIDATE_DIR, DEFAULT_REPORT_OUT, DEFAULT_SQLITE_OUT, REFERENCE_DIR, REVIEW_BATCH_DIR
from usda_core.io import load_batch, load_canonical, save_batch, save_canonical, save_json
from usda_core.migrate import migrate_from_clean_json
from usda_core.promote import PromoteError, promote_batch
from usda_core.report import build_report, write_report
from usda_core.schema import CanonicalCatalog, CuratedIngredientRow
from usda_core.validate import ValidationError, validate_catalog
from usda_core.utils import utc_now_iso

app = typer.Typer(add_completion=False, no_args_is_help=True, help="USDA pipeline CLI for FridgeLuck")


def _load_queries(query_file: Path | None, query: list[str]) -> list[str]:
    out: list[str] = [q.strip() for q in query if q.strip()]
    if query_file and query_file.exists():
        for line in query_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line)
    seen = set()
    deduped = []
    for q in out:
        key = q.lower().strip()
        if key in seen:
            continue
        seen.add(key)
        deduped.append(q)
    return deduped


def _api_key(value: str | None) -> str:
    api_key = (value or os.getenv("USDA_FDC_API_KEY") or "").strip()
    if not api_key:
        raise typer.BadParameter("USDA_FDC_API_KEY is required (via --api-key or env var)")
    return api_key


@app.command("bootstrap-canonical")
def bootstrap_canonical(
    from_clean: Annotated[Path, typer.Option("--from-clean", help="Existing clean JSON to migrate from")] = Path(
        "scripts/data/.cache/usda_cooking_ingredient_catalog_clean.json"
    ),
    canonical: Annotated[Path, typer.Option("--canonical", help="Canonical catalog output path")] = CANONICAL_JSON,
) -> None:
    catalog = migrate_from_clean_json(from_clean)
    save_canonical(canonical, catalog)
    typer.echo(f"Bootstrapped canonical catalog: {canonical}")
    typer.echo(f"Rows: {len(catalog.records)}")


@app.command("fetch-candidates")
def cmd_fetch_candidates(
    out: Annotated[Path, typer.Option("--out", help="Candidate output JSON path")] = CANDIDATE_DIR / "run_001.json",
    query: Annotated[list[str], typer.Option("--query", help="Query term(s)")] = [],
    query_file: Annotated[Path | None, typer.Option("--query-file", help="Line-delimited query file")] = None,
    fdc_id: Annotated[list[int], typer.Option("--fdc-id", help="Explicit FDC IDs to fetch")] = [],
    api_key: Annotated[str | None, typer.Option("--api-key", help="USDA API key")]=None,
    cache_db: Annotated[Path, typer.Option("--cache-db", help="SQLite cache DB path")] = CACHE_DB,
    max_connections: Annotated[int, typer.Option("--max-connections")] = 32,
    max_keepalive_connections: Annotated[int, typer.Option("--max-keepalive-connections")] = 16,
    concurrency: Annotated[int, typer.Option("--concurrency")] = 12,
    connect_timeout: Annotated[float, typer.Option("--connect-timeout")] = 5.0,
    read_timeout: Annotated[float, typer.Option("--read-timeout")] = 20.0,
    write_timeout: Annotated[float, typer.Option("--write-timeout")] = 10.0,
    pool_timeout: Annotated[float, typer.Option("--pool-timeout")] = 5.0,
) -> None:
    resolved_key = _api_key(api_key)
    queries = _load_queries(query_file=query_file, query=query)

    async def _run() -> list[CuratedIngredientRow]:
        cache = CacheStore(cache_db)
        client = USDAAsyncClient(
            api_key=resolved_key,
            cache=cache,
            max_connections=max_connections,
            max_keepalive_connections=max_keepalive_connections,
            concurrency=concurrency,
            connect_timeout=connect_timeout,
            read_timeout=read_timeout,
            write_timeout=write_timeout,
            pool_timeout=pool_timeout,
        )
        try:
            return await fetch_candidates(client, queries=queries, add_fdc_ids=fdc_id)
        finally:
            await client.aclose()

    rows = asyncio.run(_run())
    payload = {
        "generated_at_utc": utc_now_iso(),
        "query_count": len(queries),
        "fdc_id_count": len(fdc_id),
        "record_count": len(rows),
        "records": [row.model_dump(mode="json") for row in rows],
    }
    save_json(out, payload)
    typer.echo(f"Wrote candidates: {out}")
    typer.echo(f"Rows: {len(rows)}")


@app.command("export-batch")
def cmd_export_batch(
    batch_id: Annotated[int, typer.Option("--batch-id")] = 1,
    batch_size: Annotated[int, typer.Option("--batch-size")] = 50,
    canonical: Annotated[Path, typer.Option("--canonical")] = CANONICAL_JSON,
    candidates: Annotated[Path | None, typer.Option("--candidates", help="Optional candidate JSON")]=None,
    out: Annotated[Path, typer.Option("--out")] = REVIEW_BATCH_DIR / "manual_batch_001.json",
) -> None:
    catalog = load_canonical(canonical)
    candidate_rows: list[CuratedIngredientRow] | None = None
    if candidates and candidates.exists():
        payload = orjson.loads(candidates.read_bytes())
        records = payload.get("records", [])
        candidate_rows = [CuratedIngredientRow.model_validate(record) for record in records if isinstance(record, dict)]

    batch = export_batch(catalog, batch_id=batch_id, batch_size=batch_size, candidates=candidate_rows)
    save_batch(out, batch)
    typer.echo(f"Wrote batch: {out}")
    typer.echo(f"Rows: {batch.batch_size}")


@app.command("promote-batch")
def cmd_promote_batch(
    in_file: Annotated[Path, typer.Option("--in", help="Input edited batch JSON")],
    canonical: Annotated[Path, typer.Option("--canonical")] = CANONICAL_JSON,
) -> None:
    catalog = load_canonical(canonical)
    batch = load_batch(in_file)
    try:
        merged = promote_batch(catalog, batch)
    except PromoteError as exc:
        raise typer.BadParameter(str(exc)) from exc
    save_canonical(canonical, merged)
    typer.echo(f"Promoted batch into canonical: {canonical}")
    typer.echo(f"Rows: {len(merged.records)}")


@app.command("build-sqlite")
def cmd_build_sqlite(
    canonical: Annotated[Path, typer.Option("--canonical")] = CANONICAL_JSON,
    out: Annotated[Path, typer.Option("--out")] = DEFAULT_SQLITE_OUT,
) -> None:
    catalog = load_canonical(canonical)
    build_sqlite(catalog, out)
    typer.echo(f"Built SQLite: {out}")
    typer.echo(f"Rows: {len(catalog.records)}")


@app.command("validate")
def cmd_validate(
    canonical: Annotated[Path, typer.Option("--canonical")] = CANONICAL_JSON,
    required_term: Annotated[list[str], typer.Option("--required-term")] = [],
) -> None:
    catalog = load_canonical(canonical)
    terms = required_term if required_term else None
    try:
        stats = validate_catalog(catalog, required_terms=terms)
    except ValidationError as exc:
        raise typer.BadParameter(str(exc)) from exc
    typer.echo("Validation OK")
    for key, value in stats.items():
        typer.echo(f"- {key}: {value}")


@app.command("report")
def cmd_report(
    canonical: Annotated[Path, typer.Option("--canonical")] = CANONICAL_JSON,
    out: Annotated[Path, typer.Option("--out")] = DEFAULT_REPORT_OUT,
) -> None:
    catalog = load_canonical(canonical)
    report = build_report(catalog)
    write_report(out, report)
    typer.echo(f"Wrote report: {out}")


@app.command("extract-reference")
def cmd_extract_reference(
    sr_zip: Annotated[Path, typer.Option("--sr-zip", help="Path to the SR Legacy bulk JSON zip")],
    foundation_zip: Annotated[Path, typer.Option("--foundation-zip", help="Path to the Foundation Foods bulk JSON zip")],
    canonical: Annotated[Path, typer.Option("--canonical")] = CANONICAL_JSON,
    out_dir: Annotated[Path, typer.Option("--out-dir")] = REFERENCE_DIR,
    sr_edition: Annotated[str, typer.Option("--sr-edition")] = "SR Legacy 2021-10-28",
    sr_url: Annotated[str, typer.Option("--sr-url")] = "https://fdc.nal.usda.gov/fdc-datasets/foodDataCentral.srLegacyJson.2021-10-28.zip",
    foundation_edition: Annotated[str, typer.Option("--foundation-edition")] = "Foundation Foods 2024-04-18",
    foundation_url: Annotated[str, typer.Option("--foundation-url")] = "https://fdc.nal.usda.gov/fdc-datasets/foodDataCentral.foundationJson.2024-04-18.zip",
) -> None:
    from usda_core.reference_extract import ReferenceSource, sha256_file, write_reference_bundle

    catalog = load_canonical(canonical)
    sources = [
        ReferenceSource(
            dataset="sr_legacy",
            edition=sr_edition,
            url=sr_url,
            path=sr_zip,
            sha256=sha256_file(sr_zip),
            bytes=sr_zip.stat().st_size,
        ),
        ReferenceSource(
            dataset="foundation",
            edition=foundation_edition,
            url=foundation_url,
            path=foundation_zip,
            sha256=sha256_file(foundation_zip),
            bytes=foundation_zip.stat().st_size,
        ),
    ]
    manifest = write_reference_bundle(out_dir, [r.model_dump(mode="json") for r in catalog.records], sources)
    typer.echo(f"Wrote extract: {out_dir / 'fdc_reference_extracts.json'}")
    typer.echo(f"Records: {manifest['extract_record_count']}")
    typer.echo(f"Missing fdc_ids: {len(manifest['missing_fdc_ids'])}")
    typer.echo(f"Extract sha256: {manifest['extract_sha256']}")


@app.command("audit-reference")
def cmd_audit_reference(
    canonical: Annotated[Path, typer.Option("--canonical")] = CANONICAL_JSON,
    reference: Annotated[Path, typer.Option("--reference", help="Extract JSON or the directory containing it")] = REFERENCE_DIR,
    out_dir: Annotated[Path, typer.Option("--out-dir")] = AUDIT_DIR / "reference_audit",
) -> None:
    from usda_core.reference_audit import audit_catalog, write_audit_csv

    extract_path = reference if reference.is_file() else reference / "fdc_reference_extracts.json"
    extract = orjson.loads(extract_path.read_bytes())
    catalog = load_canonical(canonical)

    archive_hashes = {
        f"{'sr_legacy' if 'srLegacy' in s.get('url', '') else 'foundation'}": s.get("sha256", "")
        for s in extract.get("sources", [])
    }
    result = audit_catalog(
        [r.model_dump(mode="json") for r in catalog.records],
        extract,
        source_archive_sha256=archive_hashes,
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    audit_path = out_dir / "audit.json"
    audit_path.write_bytes(orjson.dumps(result.to_json(), option=orjson.OPT_SORT_KEYS | orjson.OPT_INDENT_2) + b"\n")
    csv_path = out_dir / "discrepancies.csv"
    write_audit_csv(result.records, csv_path)
    proposals_path = out_dir / "correction_proposals.json"
    proposals_path.write_bytes(
        orjson.dumps({"corrections": result.proposals}, option=orjson.OPT_SORT_KEYS | orjson.OPT_INDENT_2) + b"\n"
    )
    typer.echo(f"Audit written: {audit_path}")
    typer.echo(f"Discrepancy table: {csv_path}")
    for verdict, count in sorted(result.verdict_counts.items(), key=lambda kv: -kv[1]):
        typer.echo(f"- {verdict}: {count}")
    typer.echo(f"Correction proposals: {len(result.proposals)}")


@app.command("apply-corrections")
def cmd_apply_corrections(
    corrections: Annotated[Path, typer.Option("--corrections", help="Reviewed corrections JSON")],
    canonical: Annotated[Path, typer.Option("--canonical")] = CANONICAL_JSON,
    reference: Annotated[Path, typer.Option("--reference", help="Extract JSON or the directory containing it")] = REFERENCE_DIR,
    report: Annotated[Path, typer.Option("--report")] = AUDIT_DIR / "corrections_applied.json",
) -> None:
    from usda_core.apply_corrections import apply_reference_corrections

    extract_path = reference if reference.is_file() else reference / "fdc_reference_extracts.json"
    outcome = apply_reference_corrections(canonical, extract_path, corrections)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_bytes(orjson.dumps(outcome, option=orjson.OPT_SORT_KEYS | orjson.OPT_INDENT_2) + b"\n")
    typer.echo(f"Applied: {outcome['n_applied']}  Refused: {outcome['n_refused']}  Rows stamped: {outcome['n_rows_stamped']}")
    for refused in outcome["refused"]:
        typer.echo(f"- REFUSED fdc_id={refused.get('fdc_id')} field={refused.get('field')} reason={refused.get('reason')}")
    typer.echo(f"Report: {report}")


@app.command("rebuild-sqlite")
def cmd_rebuild_sqlite(
    canonical: Annotated[Path, typer.Option("--canonical")] = CANONICAL_JSON,
    out: Annotated[Path, typer.Option("--out", help="Rebuilt DB path (never the installed app DB by accident)")] = AUDIT_DIR / "rebuilt_catalog.sqlite",
) -> None:
    catalog = load_canonical(canonical)
    build_sqlite(catalog, out)
    typer.echo(f"Rebuilt SQLite (standalone copy): {out}")
    typer.echo(f"Rows: {len(catalog.records)}")


@app.command("compare-sqlite")
def cmd_compare_sqlite(
    old: Annotated[Path, typer.Option("--old")],
    new: Annotated[Path, typer.Option("--new")],
    out: Annotated[Path, typer.Option("--out")] = AUDIT_DIR / "sqlite_compare.json",
) -> None:
    from usda_core.sqlite_compare import compare_sqlite, save_report

    report = compare_sqlite(old, new)
    out.parent.mkdir(parents=True, exist_ok=True)
    save_report(report, out)
    for table, stats in report["tables"].items():
        typer.echo(
            f"{table}: old={stats['n_old']} new={stats['n_new']} "
            f"added={stats['n_added']} removed={stats['n_removed']} changed={stats['n_changed']}"
        )
    typer.echo(f"Identical: {report['identical']}")
    typer.echo(f"Report: {out}")


def main() -> None:
    app()


if __name__ == "__main__":
    main()
