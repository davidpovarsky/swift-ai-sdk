#!/usr/bin/env python3
"""Source-bound continuation evidence. No Swift/native tests are simulated here."""
import hashlib
import io
import json
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(".evidence")
REPOSITORY = "davidpovarsky/swift-ai-sdk"
RED_RUN = 45236601864
RED_SOURCE = "77608e3156175165439eed6dad90581863db43c2"
RED_ARTIFACT = 14849898071
RED_ARCHIVE_SHA256 = "a1d32946fd7e65554319e1e705dbd761af0eacef41970d67362a03929ee55232"
ORIGINAL_SOURCE = "e7bf34111e603ca977becd007dd4e5bb109af857"
ACTOR_PATH = "Sources/SwiftAISDK/GenerateText/StreamTextActor.swift"
TEST_PATH = "Tests/SwiftAISDKTests/GenerateText/StreamTextToolResultContinuationTests.swift"
ACTOR_SHA256 = "f50df181f9fa6c4bf33ab52c76a8a2b5ac07b1965cea5421ad6eafad168c1a1d"
TEST_SHA256 = "fb335df4fd60b0bbf409449ac22957fa1139873b7c4862fe93815721621621a0"
BASELINE_SHA256 = "b9f6de97279affdfea026c1c1a4e4ba2561446d2f852b96bdb787b7648f4debf"
MEMBER_HASHES = {
    "xcode-version.txt": "18730ed2ae28a2c9cf0c2d5db549033a4f07089331391a7133b7b32187454fa9",
    "red-exit.txt": "4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865",
    "baseline-sha256.txt": "550fe83d52972abf11b992ab92234001b8ff7103ae875efaff936b733575bded",
    "candidate-StreamTextActor.swift": "f50df181f9fa6c4bf33ab52c76a8a2b5ac07b1965cea5421ad6eafad168c1a1d",
    "red.log": "5e384805dca2b4296b73e221f4507c39a59eda3df4512fe6191e4fa4dd201437",
    "red-swift-testing.xml": "a56fcd0768bc1928d3912f4d93ce64bdb8bae5ddbe544f5210b601f4b2c847ea",
    "source-sha.txt": "2a4fbf56d8abb17360355c59f9afe8c14647da786b7c43c22973d187b5c51e99",
    "candidate-sha256.txt": "3774d572ec6bd4a4ee2b542ef3267c18dd0c1469c6b88468245539151c10e181",
    "host-system.txt": "65d64dac219c6f8889e5d23ad99d56b412cc9b2d9d82f663de36a69a05c82aa2",
    "host-architecture.txt": "aaf631698ae5160ceb04a97681a14887fdcab47cd6e0f163c87485b3b1340b62",
    "swift-version.txt": "94c4c327428d284bdb4a4e7a36c320e96012abee788ce0e295a0bbda865dde42"
}
METHODS = {
    "twoToolConversation(reason:)", "toolErrorContinuesWithoutReexecution()",
    "budgetStopsContinuation()", "missingToolOutputStopsContinuation()",
    "textCompletionStopsNormally()",
}
RED_FAILED = {"twoToolConversation(reason:)", "toolErrorContinuesWithoutReexecution()"}
CLASS = "SwiftAISDKTests.StreamTextToolResultContinuationTests"

GREEN_RUN = 45240893434
GREEN_SOURCE = "06388864fd8fce188c4c8caf64c149ee6561185b"
GREEN_ARTIFACT = 14852982054
GREEN_ARCHIVE_SHA256 = "b74951e270d76c6facf0fb4b3fe275d439365597898629374f9c58c9dc9801c8"
ABORT_TEST_PATH = "Tests/SwiftAISDKTests/GenerateText/GenerateTextTests.swift"
ABORT_TEST_BEFORE_SHA256 = "4dacdd951072847d1708cb33cc01201ec204010f23347b1dff66bd8f8a991595"
ABORT_TEST_AFTER_SHA256 = "b30a57479a330fa9e1e12aa92b9796363bc41926ea3f6094b3d02d8c60f8d319"
GREEN_MEMBER_HASHES = {
    "GREEN_RESULT.json": "742ebde5e9b86c59a37fc0baa42bc1100150a0de003d5b7dce9abc5880728dd2",
    "RED_REUSE.json": "f29175530640eb28990c907cf7ba3aa1d8547153b3e87ff33f3ed33ecb7681d9",
    "candidate-sha256.txt": "3774d572ec6bd4a4ee2b542ef3267c18dd0c1469c6b88468245539151c10e181",
    "full-suite-swift-testing.xml": "6f9c0be2a18eae038b246dc461d23d3549e6ee6fe2c92e32c1a97e159ed14780",
    "full-suite.log": "695517dafb58789383c4723e8c467492523558dedd3ea8a70ebf6de69750e831",
    "green.log": "06d9a404fe7f94a48d8ab0b5641350d99cada53563ed1df2c05dc557e481bb44",
    "host-architecture.txt": "aaf631698ae5160ceb04a97681a14887fdcab47cd6e0f163c87485b3b1340b62",
    "host-system.txt": "65d64dac219c6f8889e5d23ad99d56b412cc9b2d9d82f663de36a69a05c82aa2",
    "green-swift-testing.xml": "2556fb1cae72e66d33db865210e5829f646ed64a7c0eb9b5a8487565b2797236",
    "retained-red/artifact.json": "2fb1dcf0c5251f874783714fafba2c7f817b1ae2f1c8784dfdc57b98d4954780",
    "retained-red/candidate-StreamTextActor.swift": "f50df181f9fa6c4bf33ab52c76a8a2b5ac07b1965cea5421ad6eafad168c1a1d",
    "retained-red/candidate-sha256.txt": "3774d572ec6bd4a4ee2b542ef3267c18dd0c1469c6b88468245539151c10e181",
    "retained-red/host-architecture.txt": "aaf631698ae5160ceb04a97681a14887fdcab47cd6e0f163c87485b3b1340b62",
    "retained-red/host-system.txt": "65d64dac219c6f8889e5d23ad99d56b412cc9b2d9d82f663de36a69a05c82aa2",
    "retained-red/original-artifact.zip": "a1d32946fd7e65554319e1e705dbd761af0eacef41970d67362a03929ee55232",
    "retained-red/red-exit.txt": "4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865",
    "retained-red/red-swift-testing.xml": "a56fcd0768bc1928d3912f4d93ce64bdb8bae5ddbe544f5210b601f4b2c847ea",
    "retained-red/red.log": "5e384805dca2b4296b73e221f4507c39a59eda3df4512fe6191e4fa4dd201437",
    "retained-red/source-sha.txt": "2a4fbf56d8abb17360355c59f9afe8c14647da786b7c43c22973d187b5c51e99",
    "retained-red/run.json": "38bb0d3bd629ffd2c84a9498550b5ac8cbb6f86556692c7bc0ed7a062758915c",
    "retained-red/swift-version.txt": "94c4c327428d284bdb4a4e7a36c320e96012abee788ce0e295a0bbda865dde42",
    "retained-red/xcode-version.txt": "18730ed2ae28a2c9cf0c2d5db549033a4f07089331391a7133b7b32187454fa9",
    "source-sha.txt": "d91b0e9e0bd6b6fa968133461f4c6172efd3c3b892c76feb8ca54994034df555",
    "xcode-version.txt": "18730ed2ae28a2c9cf0c2d5db549033a4f07089331391a7133b7b32187454fa9",
    "retained-red/baseline-sha256.txt": "550fe83d52972abf11b992ab92234001b8ff7103ae875efaff936b733575bded",
    "swift-version.txt": "94c4c327428d284bdb4a4e7a36c320e96012abee788ce0e295a0bbda865dde42"
}

def sha(data):
    return hashlib.sha256(data).hexdigest()

def command(args):
    return subprocess.check_output(args)

def exact_sources():
    assert sha(pathlib.Path(ACTOR_PATH).read_bytes()) == ACTOR_SHA256
    assert sha(pathlib.Path(TEST_PATH).read_bytes()) == TEST_SHA256
    assert sha(pathlib.Path(ABORT_TEST_PATH).read_bytes()) == ABORT_TEST_AFTER_SHA256
    for source in (RED_SOURCE, GREEN_SOURCE):
        before = command(["git", "show", source + ":" + ABORT_TEST_PATH])
        assert sha(before) == ABORT_TEST_BEFORE_SHA256
        # The sole permitted historical test delta has an exact whole-file hash.
        # All product code, focused regressions, other tests and package pins match.
        command(["git", "diff", "--exit-code", source, "--",
                 "Sources", "Tests", "Package.swift", "Package.resolved",
                 ":(exclude)" + ABORT_TEST_PATH])
    baseline = command(["git", "show", ORIGINAL_SOURCE + ":" + ACTOR_PATH])
    assert sha(baseline) == BASELINE_SHA256

def report(data, focused, red=False):
    document = ET.fromstring(data)
    cases = list(document.iter("testcase"))
    assert cases, "No actual test methods in XML"
    failed = [x for x in cases if x.find("failure") is not None or x.find("error") is not None]
    skipped = [x for x in cases if x.find("skipped") is not None]
    error_nodes = sum(len(x.findall("error")) for x in cases)
    issue_nodes = sum(len(x.findall("failure")) for x in cases)
    target = [x for x in cases if x.get("classname") == CLASS]
    if focused:
        assert len(cases) == 5 and len(target) == 5, "Expected exact five logical methods"
    else:
        assert len(cases) > 5, "Original package suite did not run"
    assert len(target) == 5 and {x.get("name") for x in target} == METHODS
    assert not any(x.find("skipped") is not None for x in target)
    if red:
        assert {x.get("name") for x in failed} == RED_FAILED
        assert len(failed) == 2 and issue_nodes == 7 and error_nodes == 0
        assert not skipped
        expected = {"twoToolConversation(reason:)": 4, "toolErrorContinuesWithoutReexecution()": 3}
        assert all(len(x.findall("failure")) == expected[x.get("name")] for x in failed)
    else:
        assert not failed and error_nodes == 0, "Actual unexpected test failure"
    return {
        "logical_test_methods": len(cases), "failed_test_methods": len(failed),
        "expectation_failures": issue_nodes, "errors": error_nodes,
        "skipped_test_methods": len(skipped),
        "focused_logical_test_methods": len(target),
    }

def parameterized_execution(log):
    title = '"Completed client tools reach subsequent model steps with original result identities"'
    for reason in (".stop", ".toolCalls"):
        marker = "Test case passing 1 argument reason → " + reason + " to " + title + " started."
        assert log.count(marker) == 1, "Missing or duplicate actual argument invocation: " + reason
    return {"focused_logical_test_methods": 5, "focused_scenario_invocations": 6,
            "two_tool_argument_invocations": 2}

def admit_archive(data):
    assert sha(data) == RED_ARCHIVE_SHA256, "Original artifact digest mismatch"
    archive = zipfile.ZipFile(io.BytesIO(data))
    names = archive.namelist()
    assert len(names) == len(set(names)) == len(MEMBER_HASHES)
    assert set(names) == set(MEMBER_HASHES)
    assert archive.testzip() is None
    files = {}
    for name in names:
        path = pathlib.PurePosixPath(name)
        assert not path.is_absolute() and ".." not in path.parts
        content = archive.read(name)
        assert sha(content) == MEMBER_HASHES[name]
        files[name] = content
    assert files["source-sha.txt"].decode().strip() == RED_SOURCE
    assert files["red-exit.txt"].decode().strip() == "1"
    assert sha(files["candidate-StreamTextActor.swift"]) == ACTOR_SHA256
    result = report(files["red-swift-testing.xml"], focused=True, red=True)
    result.update(parameterized_execution(files["red.log"].decode()))
    return files, result

def reuse_red():
    exact_sources()
    def api(path):
        return command(["gh", "api", "repos/" + REPOSITORY + "/" + path])
    metadata = json.loads(api("actions/runs/" + str(RED_RUN)))
    assert metadata["id"] == RED_RUN and metadata["head_sha"] == RED_SOURCE
    assert metadata["run_attempt"] == 1 and metadata["conclusion"] == "failure"
    artifact = json.loads(api("actions/artifacts/" + str(RED_ARTIFACT)))
    assert artifact["id"] == RED_ARTIFACT and not artifact["expired"]
    assert artifact["workflow_run"]["id"] == RED_RUN
    assert artifact["workflow_run"]["head_sha"] == RED_SOURCE
    assert artifact["digest"] == "sha256:" + RED_ARCHIVE_SHA256
    data = api("actions/artifacts/" + str(RED_ARTIFACT) + "/zip")
    files, observed = admit_archive(data)
    # This is continuation of the same actual Apple compiler/runtime evidence.
    for name in ("swift-version.txt", "xcode-version.txt", "host-architecture.txt"):
        assert (ROOT / name).read_bytes() == files[name], "Apple toolchain changed: " + name
    destination = ROOT / "retained-red"
    destination.mkdir()
    for name, content in files.items():
        (destination / name).write_bytes(content)
    (destination / "original-artifact.zip").write_bytes(data)
    (destination / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (destination / "artifact.json").write_text(json.dumps(artifact, indent=2) + "\n")
    observed.update({
        "status": "ACTUAL_ORIGINAL_REGRESSION_REPRODUCED",
        "run": RED_RUN, "source": RED_SOURCE, "artifact": RED_ARTIFACT,
        "archive_sha256": RED_ARCHIVE_SHA256,
        "actual_xml_name": "red-swift-testing.xml",
        "baseline_reexecuted": False,
    })
    (ROOT / "RED_REUSE.json").write_text(json.dumps(observed, indent=2) + "\n")
    print(json.dumps(observed))

def admit_green_archive(data):
    assert sha(data) == GREEN_ARCHIVE_SHA256, "Original green archive digest mismatch"
    archive = zipfile.ZipFile(io.BytesIO(data))
    names = archive.namelist()
    assert len(names) == len(set(names)) == len(GREEN_MEMBER_HASHES)
    assert set(names) == set(GREEN_MEMBER_HASHES)
    assert archive.testzip() is None
    files = {}
    for name in names:
        path = pathlib.PurePosixPath(name)
        assert not path.is_absolute() and ".." not in path.parts
        content = archive.read(name)
        assert sha(content) == GREEN_MEMBER_HASHES[name]
        files[name] = content
    assert files["source-sha.txt"].decode().strip() == GREEN_SOURCE
    observed = report(files["green-swift-testing.xml"], focused=True)
    observed.update(parameterized_execution(files["green.log"].decode()))
    assert json.loads(files["GREEN_RESULT.json"]) == {
        **observed, "status": "ACTUAL_CANDIDATE_FOCUSED_PASS"
    }
    cases = list(ET.fromstring(files["full-suite-swift-testing.xml"]).iter("testcase"))
    assert len(cases) == 4185
    assert not any(x.find("skipped") is not None or x.find("error") is not None for x in cases)
    failed = [x for x in cases if x.find("failure") is not None]
    assert len(failed) == 1 and len(failed[0].findall("failure")) == 1
    assert failed[0].get("classname") == "SwiftAISDKTests.GenerateTextTests"
    assert failed[0].get("name") == "optionsAbortSignalForwardedToToolExecution()"
    return files, observed

def reuse_green():
    exact_sources()
    def api(path):
        return command(["gh", "api", "repos/" + REPOSITORY + "/" + path])
    metadata = json.loads(api("actions/runs/" + str(GREEN_RUN)))
    assert metadata["id"] == GREEN_RUN and metadata["head_sha"] == GREEN_SOURCE
    assert metadata["run_attempt"] == 1 and metadata["conclusion"] == "failure"
    artifact = json.loads(api("actions/artifacts/" + str(GREEN_ARTIFACT)))
    assert artifact["id"] == GREEN_ARTIFACT and not artifact["expired"]
    assert artifact["workflow_run"]["id"] == GREEN_RUN
    assert artifact["workflow_run"]["head_sha"] == GREEN_SOURCE
    assert artifact["digest"] == "sha256:" + GREEN_ARCHIVE_SHA256
    data = api("actions/artifacts/" + str(GREEN_ARTIFACT) + "/zip")
    files, observed = admit_green_archive(data)
    for name in ("swift-version.txt", "xcode-version.txt", "host-architecture.txt"):
        assert (ROOT / name).read_bytes() == files[name], "Apple toolchain changed: " + name
    destination = ROOT / "retained-green"
    destination.mkdir()
    for name, content in files.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    (destination / "original-artifact.zip").write_bytes(data)
    (destination / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (destination / "artifact.json").write_text(json.dumps(artifact, indent=2) + "\n")
    observed.update({
        "status": "ACTUAL_CANDIDATE_FOCUSED_PASS",
        "run": GREEN_RUN, "source": GREEN_SOURCE, "artifact": GREEN_ARTIFACT,
        "archive_sha256": GREEN_ARCHIVE_SHA256,
        "actual_xml_name": "green-swift-testing.xml",
        "focused_reexecuted": False,
        "original_full_suite_methods": 4185,
        "original_full_suite_failed_methods": 1,
    })
    (ROOT / "GREEN_RESULT.json").write_text(json.dumps(observed, indent=2) + "\n")
    print(json.dumps(observed))

def verify_green():
    exact_sources()
    observed = report((ROOT / "green-swift-testing.xml").read_bytes(), focused=True)
    observed.update(parameterized_execution((ROOT / "green.log").read_text()))
    observed["status"] = "ACTUAL_CANDIDATE_FOCUSED_PASS"
    (ROOT / "GREEN_RESULT.json").write_text(json.dumps(observed, indent=2) + "\n")
    print(json.dumps(observed))

def verify_full():
    exact_sources()
    swift = ROOT / "full-suite-swift-testing.xml"
    observed = report(swift.read_bytes(), focused=False)
    actual = list(ET.fromstring(swift.read_bytes()).iter("testcase"))
    prior_path = ROOT / "retained-green" / "full-suite-swift-testing.xml"
    prior = list(ET.fromstring(prior_path.read_bytes()).iter("testcase"))
    identity = lambda rows: sorted((x.get("classname"), x.get("name")) for x in rows)
    assert len(actual) == 4185 and identity(actual) == identity(prior), "Original suite inventory changed"
    assert observed["skipped_test_methods"] == 0, "Original suite contains a skipped method"
    observed.update(parameterized_execution((ROOT / "full-suite.log").read_text()))
    observed["exact_original_method_inventory"] = True
    observed["abort_fixture_event_order_repaired"] = True
    extra = ROOT / "full-suite.xml"
    if extra.exists():
        tree = ET.fromstring(extra.read_bytes())
        cases = list(tree.iter("testcase"))
        assert all(x.find("failure") is None and x.find("error") is None for x in cases)
        observed["xctest_methods"] = len(cases)
        observed["xctest_skipped_methods"] = sum(x.find("skipped") is not None for x in cases)
    observed["status"] = "ACTUAL_ORIGINAL_PACKAGE_SUITE_PASS"
    observed["source"] = command(["git", "rev-parse", "HEAD"]).decode().strip()
    (ROOT / "FULL_SUITE_RESULT.json").write_text(json.dumps(observed, indent=2) + "\n")
    print(json.dumps(observed))

if __name__ == "__main__":
    {"reuse-red": reuse_red, "reuse-green": reuse_green, "green": verify_green, "full": verify_full}[sys.argv[1]]()
