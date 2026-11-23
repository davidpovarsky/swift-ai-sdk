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



def admit_previous_archive(data, spec):
    previous = spec["continuation"]["previous"]
    require(len(data) == previous["archive_bytes"] and sha(data) == previous["archive_sha256"],
            "Previous actual full-suite archive changed")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)) and all(not PurePosixPath(n).is_absolute()
                and ".." not in PurePosixPath(n).parts for n in names), "Unsafe previous archive")
        require(archive.testzip() is None, "Previous archive CRC failed")
        files = {name: archive.read(name) for name in names}
    index_data = files["EVIDENCE_INDEX.json"]
    require(sha(index_data) == previous["index_sha256"], "Previous original index changed")
    rows = json.loads(index_data)["files"]
    require(len(rows) == 25 and len({r["path"] for r in rows}) == 25
            and {r["path"] for r in rows} == set(files) - {"EVIDENCE_INDEX.json"},
            "Previous evidence index is incomplete")
    for row in rows:
        body = files[row["path"]]
        require(len(body) == row["bytes"] and sha(body) == row["sha256"],
                "Previous evidence member changed: " + row["path"])
    context = json.loads(files["RUN_CONTEXT.json"])
    require(context["GITHUB_REPOSITORY"] == REPOSITORY
            and context["GITHUB_SHA"] == previous["source"]
            and context["GITHUB_RUN_ID"] == str(previous["run"])
            and context["GITHUB_RUN_ATTEMPT"] == "1", "Previous execution identity changed")
    require(files["SOURCE_BEFORE.json"] == files["SOURCE_AFTER.json"]
            and sha(files["SOURCE_BEFORE.json"]) == previous["source_index_sha256"],
            "Previous source changed before/after its actual execution")
    source = json.loads(files["SOURCE_BEFORE.json"])
    require(source["source"] == previous["source"] and source["tree"] == previous["tree"]
            and len(source["files"]) == 1401, "Previous exact source identity changed")
    require(files["swift-exit.txt"].strip() == b"1"
            and json.loads(files["QUALIFICATION_RESULT.json"])["status"] == "QUALIFICATION_NOT_PASSED",
            "The historical aggregate failure must remain a failure")
    require(sha(files["full-suite-swift-testing.xml"]) == previous["xml_sha256"],
            "Previous actual XML changed")
    cases, identities = xml_inventory(files["full-suite-swift-testing.xml"], 4194)
    _, original = xml_inventory(files["baseline/full-suite-swift-testing.xml"], 4185)
    require(sha(files["baseline/full-suite-swift-testing.xml"]) == spec["baseline"]["xml_sha256"]
            and identities == original | {tuple(x) for x in spec["new_method_identities"]},
            "Previous method identity closure changed")
    failed = [x for x in cases if x.find("failure") is not None]
    selected = tuple(spec["continuation"]["selected_identity"])
    require(len(failed) == 1 and (failed[0].get("classname"), failed[0].get("name")) == selected
            and len(failed[0].findall("failure")) == 2
            and not any(x.find("error") is not None or x.find("skipped") is not None for x in cases),
            "Only the exact known new fixture expectation may have failed")
    passed_cases([x for x in cases if x is not failed[0]])
    log = files["full-suite.log"].decode()
    for title, expected in spec["new_parameter_invocations"].items():
        count = sum("Test case passing 1 argument " in line
                    and line.endswith(' to "' + title + '" started.') for line in log.splitlines())
        require(count == expected, "Previous parameter coverage changed: " + title)
    for reason in (".stop", ".toolCalls"):
        marker = "Test case passing 1 argument reason → " + reason + \
            ' to "Completed client tools reach subsequent model steps with original result identities" started.'
        require(log.count(marker) == 1, "Previous finish-reason vector changed")
    return files, source, identities - {selected}


def continuation_source_binding(spec, previous_source, current_source):
    continuation = spec["continuation"]
    previous = continuation["previous"]
    allowed = {SELF_PATH, str(SPEC_PATH), WORKFLOW_PATH, continuation["test_path"]}
    require(set(command(["git", "diff", "--name-only", previous["source"], "HEAD"])
                .decode().splitlines()) == allowed, "Continuation changed more than its four owned paths")
    require(command(["git", "rev-parse", "HEAD^"]).decode().strip() == previous["source"],
            "Continuation is not an immediate child of the actual full-suite source")
    old = {r["path"]: r for r in previous_source["files"]}
    new = {r["path"]: r for r in current_source["files"]}
    require(len(old) == 1401 and set(old) == set(new), "Execution input closure changed")
    require(all(old[p] == new[p] for p in old if p not in allowed),
            "A retained passing test or its product/dependency inputs changed")
    require(command(["git", "rev-parse", previous["source"] + "^{tree}"])
            .decode().strip() == previous["tree"], "Previous Git tree disagrees with retained proof")
    object_ids = "".join(r["git_blob"] + "\n" for r in previous_source["files"]).encode()
    batch = subprocess.check_output(["git", "cat-file", "--batch"], input=object_ids, timeout=120)
    offset = 0
    for row in previous_source["files"]:
        end = batch.index(b"\n", offset)
        oid, kind, size = batch[offset:end].decode().split()
        body = batch[end + 1:end + 1 + int(size)]
        offset = end + 2 + int(size)
        require(oid == row["git_blob"] and kind == "blob"
                and len(body) == row["bytes"] and sha(body) == row["sha256"],
                "Retained original Git blob disagrees: " + row["path"])
    require(offset == len(batch), "Unexpected retained Git object data")
    listing = command(["git", "ls-tree", "-rz", previous["source"], "--",
                       "Sources", "Tests", "Package.swift", "Package.resolved", str(SPEC_PATH),
                       SELF_PATH, WORKFLOW_PATH, "plan/design-decisions.md"])
    mapped = {}
    for item in listing.split(b"\0"):
        if item:
            info, path = item.split(b"\t", 1)
            mode, kind, oid = info.decode().split()
            require(kind == "blob", "Unexpected previous source object")
            mapped[os.fsdecode(path)] = (mode, oid)
    require(mapped == {p: (r["mode"], r["git_blob"]) for p, r in old.items()},
            "Retained source inventory is not the complete original Git tree closure")
    before = command(["git", "show", previous["source"] + ":" + continuation["test_path"]])
    expected = before
    for change in continuation["literal_corrections"]:
        source, target = change["before"].encode(), change["after"].encode()
        require(expected.count(source) == change["count"], "Unexpected fixture literal multiplicity")
        expected = expected.replace(source, target)
    require(Path(continuation["test_path"]).read_bytes() == expected,
            "The test changed beyond three exact original text-result expectations")
    for item in continuation["original_contract"]:
        body = Path(item["path"]).read_bytes()
        require(len(body) == item["bytes"] and sha(body) == item["sha256"],
                "Original text serialization contract changed")
    return {"same_input_paths": len(old), "unchanged_inputs": len(old) - len(allowed),
            "changed_inputs": sorted(allowed), "product_and_all_retained_tests_unchanged": True,
            "only_three_expected_text_literals_changed": True}


def check_same_toolchain(files):
    for name in ("swift-version.txt", "xcode-version.txt", "host-architecture.txt",
                 "host-system.txt", "developer-directory.txt", "sdk-version.txt", "sdk-build.txt",
                 "COMPILER_IDENTITY.json"):
        require((ROOT / name).read_bytes() == files[name],
                "Retained results cannot be reused with a different compiler/environment: " + name)


def retain_previous(spec):
    previous = spec["continuation"]["previous"]
    def api(path):
        return command(["gh", "api", "repos/" + REPOSITORY + "/" + path])
    run = json.loads(api("actions/runs/" + str(previous["run"])))
    artifact = json.loads(api("actions/artifacts/" + str(previous["artifact"])))
    require(run["id"] == previous["run"] and run["head_sha"] == previous["source"]
            and run["run_attempt"] == 1 and run["status"] == "completed"
            and run["conclusion"] == "failure", "Previous run provenance changed")
    require(artifact["id"] == previous["artifact"] and not artifact["expired"]
            and artifact["size_in_bytes"] == previous["archive_bytes"]
            and artifact["digest"] == "sha256:" + previous["archive_sha256"]
            and artifact["workflow_run"]["id"] == previous["run"]
            and artifact["workflow_run"]["head_sha"] == previous["source"],
            "Previous artifact provenance changed")
    data = api("actions/artifacts/" + str(previous["artifact"]) + "/zip")
    files, source, passed = admit_previous_archive(data, spec)
    binding = continuation_source_binding(spec, source,
                                          json.loads((ROOT / "SOURCE_BEFORE.json").read_bytes()))
    check_same_toolchain(files)
    target = ROOT / "previous"
    target.mkdir()
    (target / "actual-full-suite.zip").write_bytes(data)
    write_json(target / "run.json", run)
    write_json(target / "artifact.json", artifact)
    write_json(ROOT / "RETAINED_PASS_ADMISSION.json", {
        **previous, "actual_previous_methods": 4194, "retained_passing_methods": len(passed),
        "previous_failed_methods": 1, "previous_failure_preserved": True, "source_binding": binding,
        "compiler_and_environment_equal": True, "previous_test_binary_hash_retained": False,
        "previous_test_binary_hash_absence": "Original finalizer stopped at swift exit 1.",
        "replay_of_retained_methods_permitted": False})


def observe_continuation(spec):
    after = source_inventory(spec)
    write_json(ROOT / "SOURCE_AFTER.json", after)
    require(after == json.loads((ROOT / "SOURCE_BEFORE.json").read_bytes()),
            "Source changed during focused execution")
    files, previous_source, retained = admit_previous_archive(
        (ROOT / "previous/actual-full-suite.zip").read_bytes(), spec)
    binding = continuation_source_binding(spec, previous_source, after)
    check_same_toolchain(files)
    compiler = json.loads((ROOT / "COMPILER_IDENTITY.json").read_bytes())
    body = Path(compiler["path"]).read_bytes()
    require(len(body) == compiler["bytes"] and sha(body) == compiler["sha256"],
            "Compiler changed during focused execution")
    binaries = list(Path(".build").glob(
        "*-apple-macosx/debug/SwiftAISDKPackageTests.xctest/Contents/MacOS/SwiftAISDKPackageTests"))
    require(len(binaries) == 1, "Expected the actual complete package test binary")
    binary = binaries[0]
    body = binary.read_bytes()
    binary_sha = sha(body)
    write_json(ROOT / "TEST_BINARY_IDENTITY.json", {
        "path": str(binary), "bytes": len(body), "sha256": binary_sha})
    require((ROOT / "swift-exit.txt").read_text().strip() == "0",
            "Original focused swift test did not exit successfully")
    data = (ROOT / "focused-suite-swift-testing.xml").read_bytes()
    cases, actual = xml_inventory(data, 1)
    passed_cases(cases)
    require(actual == {tuple(spec["continuation"]["selected_identity"])} and not actual & retained,
            "A retained test was replayed or the failed test was not executed")
    log = (ROOT / "focused-suite.log").read_text()
    title = '"Original streamText sends exact signatures and tool results on both later requests after finish stop"'
    require(sum(line.strip() == "◇ Test " + title + " started." for line in log.splitlines()) == 1,
            "Expected exactly one actual selected Swift Testing invocation")
    extra = ROOT / "focused-suite.xml"
    if extra.exists():
        require(not list(ET.fromstring(extra.read_bytes()).iter("testcase")),
                "An unselected XCTest method was replayed")
    require(len(retained | actual) == 4194, "The complete logical coverage is not 4194")
    return {
        "status": "ACTUAL_APPLE_PACKAGE_QUALIFIED_WITH_RETAINED_PASSES",
        "source": after["source"], "tree": after["tree"],
        "actual_focused_methods": 1, "retained_actual_passing_methods": 4193,
        "qualified_logical_methods": 4194, "new_logical_methods_qualified": 9,
        "new_scenarios_qualified": 18, "failed_methods": 0, "errors": 0,
        "skipped_methods": 0, "not_run_obligations": 0,
        "previous_run": spec["continuation"]["previous"]["run"],
        "previous_aggregate_conclusion": "failure", "previous_failure_preserved": True,
        "source_binding": binding, "source_and_compiler_unchanged": True,
        "xml_sha256": sha(data), "test_binary_sha256": binary_sha,
        "retained_tests_replayed": 0, "live_provider_called": False,
        "app_native_acceptance_claimed": False}



def prepare(spec):
    ROOT.mkdir(exist_ok=True)
    write_json(ROOT / "SOURCE_BEFORE.json", source_inventory(spec))
    record_toolchain()
    retain_baseline(spec)
    if "continuation" in spec:
        retain_previous(spec)


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
            result = observe_continuation(spec) if "continuation" in spec else observe_full(spec)
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
