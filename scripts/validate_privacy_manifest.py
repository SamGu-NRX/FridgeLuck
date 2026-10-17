#!/usr/bin/env python3
"""Validate a privacy manifest (PrivacyInfo.xcprivacy) against Apple's schema and,
with --expect-app, against FridgeLuck's exact source-backed declarations.

Modes:
  --manifest PATH   Validate the file's structure (default when no mode is given).
  --expect-app      Additionally assert FridgeLuck's exact declared surface.
  --self-test       Run built-in fixtures (one valid, nine negative mutations);
                    exit 0 only if every fixture behaves as expected.

Embedded tables and their provenance (all retrieved 2026-10-09):
  * Approved reason codes per API category were copied verbatim from Apple's
    primary doc JSON for the NSPrivacyAccessedAPIType key:
    https://developer.apple.com/tutorials/data/documentation/bundleresources/
      app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype.json
      FileTimestamp:  DDA9.1 C617.1 3B52.1 0A2A.1
      SystemBootTime: 35F9.1 8FFB.1 3D61.1
      DiskSpace:      85F4.1 E174.1 7D9E.1 B728.1
      ActiveKeyboards: 3EC4.1 54BD.1
      UserDefaults:   CA92.1 1C8F.1 C56D.1 AC6B.1
  * Collected-data-type values were copied verbatim from the primary doc JSON for
    NSPrivacyCollectedDataType (.../nsprivacycollecteddatatypes/nsprivacycollecteddatatype.json).
  * Purpose values follow the NSPrivacyCollectedDataTypePurposes key doc.

The Swift mirror of these rules lives in apps/ios/Tests/PrivacyManifestTests.swift
(PrivacyRulebook). Keep the two tables in sync; both files reference each other.
"""

import argparse
import plistlib
import re
import sys
from xml.parsers.expat import ExpatError

REASON_PATTERN = re.compile(r"^[A-Z0-9]{4}\.[0-9]+$")

APPROVED_REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}

ALLOWED_TOP_KEYS = {
    "NSPrivacyTracking",
    "NSPrivacyTrackingDomains",
    "NSPrivacyCollectedDataTypes",
    "NSPrivacyAccessedAPITypes",
}

ALLOWED_DATA_TYPES = frozenset(
    "NSPrivacyCollectedDataType" + name
    for name in (
        "Name", "EmailAddress", "PhoneNumber", "PhysicalAddress",
        "OtherUserContactInfo", "Health", "Fitness", "PaymentInfo", "CreditInfo",
        "OtherFinancialInfo", "PreciseLocation", "CoarseLocation", "SensitiveInfo",
        "Contacts", "EmailsOrTextMessages", "PhotosorVideos", "AudioData",
        "GameplayContent", "CustomerSupport", "OtherUserContent", "BrowsingHistory",
        "SearchHistory", "UserID", "DeviceID", "PurchaseHistory",
        "ProductInteraction", "AdvertisingData", "OtherUsageData", "CrashData",
        "PerformanceData", "OtherDiagnosticData", "EnvironmentScanning", "Hands",
        "Head", "OtherDataTypes",
    )
)

ALLOWED_PURPOSES = frozenset(
    "NSPrivacyCollectedDataPurpose" + name
    for name in (
        "AppFunctionality", "Analytics", "ProductPersonalization",
        "DeveloperAdvertising", "ThirdPartyAdvertising", "DeveloperMarketing",
        "OtherPurposes",
    )
)

EXPECTED_APP_ACCESSED = {
    "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
    "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
}

EXPECTED_APP_COLLECTED_TYPES = {
    "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypeOtherDataTypes",
    "NSPrivacyCollectedDataTypeOtherUserContent",
    "NSPrivacyCollectedDataTypePhotosorVideos",
    "NSPrivacyCollectedDataTypeAudioData",
    "NSPrivacyCollectedDataTypeHealth",
}

COLLECTED_ENTRY_KEYS = {
    "NSPrivacyCollectedDataType",
    "NSPrivacyCollectedDataTypeLinked",
    "NSPrivacyCollectedDataTypeTracking",
    "NSPrivacyCollectedDataTypePurposes",
}


class Invalid(Exception):
    """Raised for structural failures such as unparseable plists."""


def validate_structure(manifest):
    """Return a list of schema errors (empty when the manifest is valid)."""
    errors = []
    if not isinstance(manifest, dict):
        return ["root object is not a dictionary"]

    unknown_keys = sorted(set(manifest) - ALLOWED_TOP_KEYS)
    if unknown_keys:
        errors.append("unknown top-level keys: %s" % ", ".join(unknown_keys))

    tracking = manifest.get("NSPrivacyTracking")
    if tracking is None:
        errors.append("missing required key NSPrivacyTracking")
    elif type(tracking) is not bool:
        errors.append("NSPrivacyTracking must be a boolean")

    if "NSPrivacyTrackingDomains" in manifest:
        domains = manifest["NSPrivacyTrackingDomains"]
        if not isinstance(domains, list) or not all(isinstance(d, str) for d in domains):
            errors.append("NSPrivacyTrackingDomains must be an array of strings")
        elif tracking is False and domains:
            errors.append("NSPrivacyTrackingDomains must be empty when NSPrivacyTracking is false")

    seen_data_types = set()
    for index, entry in enumerate(manifest.get("NSPrivacyCollectedDataTypes") or []):
        label = "NSPrivacyCollectedDataTypes[%d]" % index
        if not isinstance(entry, dict):
            errors.append("%s is not a dictionary" % label)
            continue
        missing = COLLECTED_ENTRY_KEYS - set(entry)
        if missing:
            errors.append("%s missing keys: %s" % (label, ", ".join(sorted(missing))))
        data_type = entry.get("NSPrivacyCollectedDataType")
        if not isinstance(data_type, str) or data_type not in ALLOWED_DATA_TYPES:
            errors.append("%s has unknown NSPrivacyCollectedDataType %r" % (label, data_type))
        elif data_type in seen_data_types:
            errors.append("%s repeats data type %s" % (label, data_type))
        seen_data_types.add(data_type)
        for key in ("NSPrivacyCollectedDataTypeLinked", "NSPrivacyCollectedDataTypeTracking"):
            value = entry.get(key)
            if type(value) is not bool:
                errors.append("%s %s must be a boolean" % (label, key))
        purposes = entry.get("NSPrivacyCollectedDataTypePurposes")
        if not isinstance(purposes, list) or not purposes or not all(isinstance(p, str) for p in purposes):
            errors.append("%s NSPrivacyCollectedDataTypePurposes must be a non-empty array of strings" % label)
        else:
            for purpose in purposes:
                if purpose not in ALLOWED_PURPOSES:
                    errors.append("%s has unknown purpose %r" % (label, purpose))
        if entry.get("NSPrivacyCollectedDataTypeTracking") is True and tracking is False:
            errors.append("%s declares tracking while NSPrivacyTracking is false" % label)

    seen_categories = set()
    for index, entry in enumerate(manifest.get("NSPrivacyAccessedAPITypes") or []):
        label = "NSPrivacyAccessedAPITypes[%d]" % index
        if not isinstance(entry, dict):
            errors.append("%s is not a dictionary" % label)
            continue
        category = entry.get("NSPrivacyAccessedAPIType")
        if not isinstance(category, str) or category not in APPROVED_REASONS:
            errors.append("%s has unknown NSPrivacyAccessedAPIType %r" % (label, category))
            continue
        if category in seen_categories:
            errors.append("%s repeats category %s" % (label, category))
        seen_categories.add(category)
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(reasons, list) or not reasons or not all(isinstance(r, str) for r in reasons):
            errors.append("%s NSPrivacyAccessedAPITypeReasons must be a non-empty array of strings" % label)
            continue
        for reason in reasons:
            if not REASON_PATTERN.match(reason):
                errors.append("%s reason %r is not formatted like a reason code" % (label, reason))
            elif reason not in APPROVED_REASONS[category]:
                errors.append("%s reason %r is not approved for %s" % (label, reason, category))

    return errors


def validate_expect_app(manifest):
    """Return errors for any drift from FridgeLuck's source-backed declarations."""
    errors = []
    if manifest.get("NSPrivacyTracking") is not False:
        errors.append("app expectation: NSPrivacyTracking must be false")
    if manifest.get("NSPrivacyTrackingDomains") != []:
        errors.append("app expectation: NSPrivacyTrackingDomains must be empty")

    accessed = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes") or []:
        if isinstance(entry, dict) and isinstance(entry.get("NSPrivacyAccessedAPIType"), str):
            accessed[entry["NSPrivacyAccessedAPIType"]] = entry.get("NSPrivacyAccessedAPITypeReasons")
    expected_accessed = {k: list(v) for k, v in EXPECTED_APP_ACCESSED.items()}
    if accessed != expected_accessed:
        errors.append("app expectation: accessed API types must be exactly %r, found %r" % (expected_accessed, accessed))

    collected_types = set()
    for entry in manifest.get("NSPrivacyCollectedDataTypes") or []:
        if not isinstance(entry, dict):
            continue
        data_type = entry.get("NSPrivacyCollectedDataType")
        collected_types.add(data_type)
        if entry.get("NSPrivacyCollectedDataTypeLinked") is not True:
            errors.append("app expectation: %s must be linked (conservative posture)" % data_type)
        if entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
            errors.append("app expectation: %s must not be tracking" % data_type)
        if entry.get("NSPrivacyCollectedDataTypePurposes") != ["NSPrivacyCollectedDataPurposeAppFunctionality"]:
            errors.append("app expectation: %s must declare only AppFunctionality" % data_type)
    if collected_types != EXPECTED_APP_COLLECTED_TYPES:
        errors.append(
            "app expectation: collected data types must be exactly %r, found %r"
            % (sorted(EXPECTED_APP_COLLECTED_TYPES), sorted(collected_types))
        )

    return errors


def load_manifest(path):
    with open(path, "rb") as handle:
        data = handle.read()
    try:
        parsed = plistlib.loads(data)
    except (plistlib.InvalidFileException, ExpatError, ValueError) as exc:
        raise Invalid("not a valid property list: %s" % exc) from exc
    if not isinstance(parsed, dict):
        raise Invalid("manifest root is not a dictionary")
    return parsed


def run_self_test():
    """One valid fixture must pass; every negative mutation must be rejected."""
    valid = {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyAccessedAPITypes": [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
            }
        ],
        "NSPrivacyCollectedDataTypes": [
            {
                "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeDeviceID",
                "NSPrivacyCollectedDataTypeLinked": True,
                "NSPrivacyCollectedDataTypeTracking": False,
                "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataPurposeAppFunctionality"],
            }
        ],
    }

    def collected(tracking=False, linked=True, data_type="NSPrivacyCollectedDataTypeDeviceID",
                  purposes=("NSPrivacyCollectedDataPurposeAppFunctionality",)):
        return {
            "NSPrivacyCollectedDataType": data_type,
            "NSPrivacyCollectedDataTypeLinked": linked,
            "NSPrivacyCollectedDataTypeTracking": tracking,
            "NSPrivacyCollectedDataTypePurposes": list(purposes),
        }

    negatives = []
    negatives.append(("malformed XML bytes", None))  # handled specially below
    missing_tracking = {k: v for k, v in valid.items() if k != "NSPrivacyTracking"}
    negatives.append(("missing NSPrivacyTracking", missing_tracking))
    bad_reason = {
        **valid,
        "NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
             "NSPrivacyAccessedAPITypeReasons": ["ZZZZ.9"]}
        ],
    }
    negatives.append(("non-approved reason code", bad_reason))
    bad_category = {
        **valid,
        "NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryTelepathy",
             "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]}
        ],
    }
    negatives.append(("unknown API category", bad_category))
    bad_data_type = {**valid, "NSPrivacyCollectedDataTypes": [
        collected(data_type="NSPrivacyCollectedDataTypeTelepathy")]}
    negatives.append(("unknown collected data type", bad_data_type))
    missing_linked = {**valid, "NSPrivacyCollectedDataTypes": [{k: v for k, v in collected().items()
                                                                if k != "NSPrivacyCollectedDataTypeLinked"}]}
    negatives.append(("collected entry missing Linked flag", missing_linked))
    tracking_mismatch = {**valid, "NSPrivacyCollectedDataTypes": [collected(tracking=True)]}
    negatives.append(("tracking data while NSPrivacyTracking is false", tracking_mismatch))
    bad_purpose = {**valid, "NSPrivacyCollectedDataTypes": [
        collected(purposes=("NSPrivacyCollectedDataPurposeWorldDomination",))]}
    negatives.append(("unknown purpose", bad_purpose))
    bad_domains = {**valid, "NSPrivacyTrackingDomains": ["example.com"]}
    negatives.append(("tracking domains present while tracking disabled", bad_domains))

    failures = []
    if validate_structure(valid):
        failures.append("valid fixture was rejected: %r" % validate_structure(valid))

    for name, fixture in negatives:
        if fixture is None:
            try:
                plistlib.loads(b"<plist><dict><key>NSPrivacyTracking</key>")
            except (plistlib.InvalidFileException, ExpatError, ValueError):
                continue
            failures.append("malformed XML fixture was not rejected")
            continue
        errors = validate_structure(fixture)
        if not errors:
            failures.append("negative fixture %r was not rejected" % name)

    if failures:
        for failure in failures:
            print("SELF-TEST FAIL: %s" % failure)
        return False
    print("self-test: 1 valid fixture accepted, 9 negative mutations rejected")
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", help="path to PrivacyInfo.xcprivacy")
    parser.add_argument("--expect-app", action="store_true",
                        help="additionally assert FridgeLuck's exact declared surface")
    parser.add_argument("--self-test", action="store_true",
                        help="run built-in positive and negative fixtures")
    args = parser.parse_args(argv)

    if args.self_test:
        return 0 if run_self_test() else 1

    if not args.manifest:
        parser.error("provide --manifest PATH or --self-test")

    try:
        manifest = load_manifest(args.manifest)
    except (OSError, Invalid) as exc:
        print("FAIL: %s" % exc)
        return 1

    errors = validate_structure(manifest)
    if args.expect_app:
        errors.extend(validate_expect_app(manifest))

    if errors:
        for error in errors:
            print("FAIL: %s" % error)
        return 1

    scope = "structure and app expectations" if args.expect_app else "structure"
    print("PASS (%s): %s" % (scope, args.manifest))
    return 0


if __name__ == "__main__":
    sys.exit(main())
