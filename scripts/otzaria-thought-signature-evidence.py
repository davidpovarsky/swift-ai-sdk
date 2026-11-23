#!/usr/bin/env python3
"""Observe the actual Apple SwiftPM qualification; never execute replacement tests."""
import argparse
import collections
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(".evidence")
SPEC_PATH = Path("plan/otzaria-thought-signature-inputs.json")
SELF_PATH = "scripts/otzaria-thought-signature-evidence.py"
WORKFLOW_PATH = ".github/workflows/otzaria-stream-continuation.yml"
REPOSITORY = "davidpovarsky/swift-ai-sdk"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def command(args, timeout=120):
    return subprocess.check_output(args, timeout=timeout)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def blob_bytes(path, mode):
    if mode == "120000":
        return os.fsencode(os.readlink(path))
    require(mode in {"100644", "100755"}, "Unsupported source input mode: " + mode)
    return path.read_bytes()


def source_inventory(spec):
    review = spec["source_review"]
    base = review["base"]
    command(["git", "merge-base", "--is-ancestor", base, "HEAD"])
    allowed = {row["path"] for row in review["rows"]} | {
        str(SPEC_PATH), SELF_PATH, WORKFLOW_PATH
    }
    changed = set(command(["git", "diff", "--name-only", base, "HEAD"]).decode().splitlines())
    require(changed == allowed, "The committed ten-path qualification boundary changed")
    for row in review["rows"]:
        raw = Path(row["path"]).read_bytes()
        expected = row["afterimage"]
        require(len(raw) == expected["bytes"] and sha(raw) == expected["sha256"],
                "Reviewed source afterimage changed: " + row["path"])
    paths = ["Sources", "Tests", "Package.swift", "Package.resolved",
             str(SPEC_PATH), SELF_PATH, WORKFLOW_PATH, "plan/design-decisions.md"]
    listing = command(["git", "ls-tree", "-rz", "HEAD", "--", *paths])
    rows = []
    for item in listing.split(b"\0"):
        if not item:
            continue
        info, path_bytes = item.split(b"\t", 1)
        mode, kind, object_id = info.decode().split()
        path = os.fsdecode(path_bytes)
        require(kind == "blob", "Unexpected source object: " + path)
        raw = blob_bytes(Path(path), mode)
        actual_blob = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        require(actual_blob == object_id, "Working source differs from committed input: " + path)
        rows.append({"path": path, "mode": mode, "git_blob": object_id,
                     "bytes": len(raw), "sha256": sha(raw)})
    require(rows, "Empty original source inventory")
    untracked = command(["git", "ls-files", "--others", "--exclude-standard", "--",
                         "Sources", "Tests"]).decode().strip()
    require(not untracked, "Untracked original source inputs exist")
    return {"source": command(["git", "rev-parse", "HEAD"]).decode().strip(),
            "tree": command(["git", "rev-parse", "HEAD^{tree}"]).decode().strip(),
            "base": base, "changed_paths": sorted(changed), "files": rows}


def xml_inventory(data, expected_count=None):
    document = ET.fromstring(data)
    cases = list(document.iter("testcase"))
    require(cases, "No actual Swift test methods")
    identities = [(x.get("classname"), x.get("name")) for x in cases]
    require(all(all(value for value in identity) for identity in identities),
            "A test method has no stable identity")
    require(len(identities) == len(set(identities)), "Duplicate test method identities")
    if expected_count is not None:
        require(len(cases) == expected_count, "Unexpected actual method count")
    return cases, set(identities)


def passed_cases(cases):
    require(not any(x.find("failure") is not None or x.find("error") is not None
                    or x.find("skipped") is not None for x in cases),
            "Failed, errored, or skipped test method in actual XML")


def admit_baseline_archive(data, baseline):
    require(len(data) == baseline["archive_bytes"] and sha(data) == baseline["archive_sha256"],
            "Historical original-suite archive bytes/hash changed")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate archive members")
        require(all(not PurePosixPath(name).is_absolute()
                    and ".." not in PurePosixPath(name).parts for name in names),
                "Unsafe archive member")
        require(archive.testzip() is None, "Historical archive CRC failed")
        files = {}
        for name in ("full-suite-swift-testing.xml", "FULL_SUITE_RESULT.json",
                     "source-sha.txt", "swift-version.txt", "xcode-version.txt",
                     "host-architecture.txt"):
            files[name] = archive.read(name)
    require(sha(files["full-suite-swift-testing.xml"]) == baseline["xml_sha256"],
            "Historical XML hash changed")
    require(files["source-sha.txt"].decode().strip() == baseline["source"],
            "Historical source changed")
    cases, identities = xml_inventory(files["full-suite-swift-testing.xml"], 4185)
    passed_cases(cases)
    receipt = json.loads(files["FULL_SUITE_RESULT.json"])
    require(receipt["source"] == baseline["source"]
            and receipt["logical_test_methods"] == 4185
            and receipt["status"] == "ACTUAL_ORIGINAL_PACKAGE_SUITE_PASS"
            and all(receipt[key] == 0 for key in ("failed_test_methods",
                    "expectation_failures", "errors", "skipped_test_methods")),
            "Historical full-suite receipt disagrees with its original XML")
    return files, identities


def retain_baseline(spec):
    baseline = spec["baseline"]
    def api(path):
        return command(["gh", "api", "repos/" + REPOSITORY + "/" + path])
    run = json.loads(api("actions/runs/" + str(baseline["run"])))
    require(run["id"] == baseline["run"] and run["head_sha"] == baseline["source"]
            and run["run_attempt"] == 1 and run["status"] == "completed"
            and run["conclusion"] == "success", "Original run provenance changed")
    artifact = json.loads(api("actions/artifacts/" + str(baseline["artifact"])))
    require(artifact["id"] == baseline["artifact"] and not artifact["expired"]
            and artifact["size_in_bytes"] == baseline["archive_bytes"]
            and artifact["digest"] == "sha256:" + baseline["archive_sha256"]
            and artifact["workflow_run"]["id"] == baseline["run"]
            and artifact["workflow_run"]["head_sha"] == baseline["source"],
            "Original artifact provenance changed")
    data = api("actions/artifacts/" + str(baseline["artifact"]) + "/zip")
    files, identities = admit_baseline_archive(data, baseline)
    target = ROOT / "baseline"
    target.mkdir()
    (target / "original-artifact.zip").write_bytes(data)
    for name, body in files.items():
        (target / name).write_bytes(body)
    write_json(target / "run.json", run)
    write_json(target / "artifact.json", artifact)
    write_json(ROOT / "BASELINE_INVENTORY_ADMISSION.json", {
        **baseline, "methods": len(identities), "archive_crc_passed": True,
        "purpose": "Exact historical method inventory; no historical pass is credited to changed source",
        "prior_results_reused_as_current_pass": False})


def record_toolchain():
    for name, args in (
        ("swift-version.txt", ["swift", "--version"]),
        ("xcode-version.txt", ["xcodebuild", "-version"]),
        ("host-architecture.txt", ["uname", "-m"]),
        ("host-system.txt", ["sw_vers"]),
        ("developer-directory.txt", ["xcode-select", "-p"]),
        ("sdk-version.txt", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        ("sdk-build.txt", ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
    ):
        (ROOT / name).write_bytes(command(args))
    require((ROOT / "host-architecture.txt").read_text().strip() == "x86_64",
            "Expected original Apple Intel qualification host")
    require((ROOT / "swift-version.txt").read_text().startswith("Apple Swift version "),
            "Expected actual Apple Swift toolchain")
    compiler = Path(command(["xcrun", "-f", "swiftc"]).decode().strip()).resolve()
    raw = compiler.read_bytes()
    write_json(ROOT / "COMPILER_IDENTITY.json", {
        "path": str(compiler), "bytes": len(raw), "sha256": sha(raw)})
    write_json(ROOT / "RUN_CONTEXT.json", {
        name: os.environ.get(name) for name in
        ("GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA",
         "GITHUB_REF", "GITHUB_WORKFLOW", "GITHUB_JOB", "RUNNER_ARCH", "RUNNER_OS")})


def prepare(spec):
    ROOT.mkdir(exist_ok=True)
    write_json(ROOT / "SOURCE_BEFORE.json", source_inventory(spec))
    record_toolchain()
    retain_baseline(spec)


def observe_full(spec):
    after = source_inventory(spec)
    write_json(ROOT / "SOURCE_AFTER.json", after)
    require(after == json.loads((ROOT / "SOURCE_BEFORE.json").read_bytes()),
            "Source changed during original SwiftPM execution")
    compiler = json.loads((ROOT / "COMPILER_IDENTITY.json").read_bytes())
    raw = Path(compiler["path"]).read_bytes()
    require(len(raw) == compiler["bytes"] and sha(raw) == compiler["sha256"],
            "Compiler changed during execution")
    require((ROOT / "swift-exit.txt").read_text().strip() == "0",
            "Original swift test did not exit successfully")
    data = (ROOT / "full-suite-swift-testing.xml").read_bytes()
    cases, actual = xml_inventory(data, 4194)
    passed_cases(cases)
    baseline = (ROOT / "baseline/full-suite-swift-testing.xml").read_bytes()
    require(sha(baseline) == spec["baseline"]["xml_sha256"], "Retained inventory changed")
    _, previous = xml_inventory(baseline, 4185)
    added = {tuple(identity) for identity in spec["new_method_identities"]}
    require(len(added) == 9 and not added & previous and actual == previous | added,
            "Original 4185 plus nine reviewed methods did not run exactly once")
    log = (ROOT / "full-suite.log").read_text()
    invocations = {}
    for title, expected in spec["new_parameter_invocations"].items():
        count = sum("Test case passing 1 argument " in line
                    and line.endswith(' to "' + title + '" started.')
                    for line in log.splitlines())
        require(count == expected, "Missing or duplicate parameter invocation: " + title)
        invocations[title] = count
    original_title = '"Completed client tools reach subsequent model steps with original result identities"'
    for reason in (".stop", ".toolCalls"):
        marker = "Test case passing 1 argument reason → " + reason + " to " + original_title + " started."
        require(log.count(marker) == 1, "Original finish-reason continuation coverage changed")
    binaries = list(Path(".build").glob(
        "*-apple-macosx/debug/SwiftAISDKPackageTests.xctest/Contents/MacOS/SwiftAISDKPackageTests"))
    require(len(binaries) == 1, "Expected one actual original SwiftPM XCTest binary")
    binary = binaries[0]
    raw = binary.read_bytes()
    write_json(ROOT / "TEST_BINARY_IDENTITY.json", {
        "path": str(binary), "bytes": len(raw), "sha256": sha(raw)})
    result = {
        "status": "ACTUAL_APPLE_ORIGINAL_PACKAGE_SUITE_PASS",
        "source": after["source"], "tree": after["tree"],
        "actual_logical_methods": 4194, "original_methods_actual": 4185,
        "new_logical_methods_actual": 9, "new_scenario_invocations_actual": 18,
        "new_parameter_invocations": invocations,
        "failed_methods": 0, "errors": 0, "skipped_methods": 0, "not_run_methods": 0,
        "original_method_inventory_exact": True, "source_and_compiler_unchanged": True,
        "xml_sha256": sha(data), "test_binary_sha256": sha(raw),
        "prior_results_reused_as_current_pass": False,
        "live_provider_called": False, "app_native_acceptance_claimed": False
    }
    extra = ROOT / "full-suite.xml"
    if extra.exists():
        additional = list(ET.fromstring(extra.read_bytes()).iter("testcase"))
        passed_cases(additional)
        result["additional_xctest_methods"] = len(additional)
    return result


def index():
    files = []
    for path in sorted(ROOT.rglob("*")):
        if path.is_file() and path != ROOT / "EVIDENCE_INDEX.json":
            data = path.read_bytes()
            files.append({"path": str(path.relative_to(ROOT)),
                          "bytes": len(data), "sha256": sha(data)})
    write_json(ROOT / "EVIDENCE_INDEX.json", {
        "schema": "otzaria.apple-thought-signature-evidence-index/1", "files": files})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("prepare", "finalize", "index", "source"))
    args = parser.parse_args()
    spec = json.loads(SPEC_PATH.read_bytes())
    if args.mode == "prepare":
        prepare(spec)
    elif args.mode == "source":
        print(json.dumps(source_inventory(spec)))
    elif args.mode == "finalize":
        try:
            result = observe_full(spec)
        except Exception as error:
            write_json(ROOT / "QUALIFICATION_RESULT.json", {
                "status": "QUALIFICATION_NOT_PASSED",
                "reason": str(error), "live_provider_called": False})
            raise
        write_json(ROOT / "QUALIFICATION_RESULT.json", result)
        print(json.dumps(result))
    else:
        index()


if __name__ == "__main__":
    main()
