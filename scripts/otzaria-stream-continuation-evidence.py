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

def sha(data):
    return hashlib.sha256(data).hexdigest()

def command(args):
    return subprocess.check_output(args)

def exact_sources():
    assert sha(pathlib.Path(ACTOR_PATH).read_bytes()) == ACTOR_SHA256
    assert sha(pathlib.Path(TEST_PATH).read_bytes()) == TEST_SHA256
    command(["git", "diff", "--exit-code", RED_SOURCE, "--",
             "Sources", "Tests", "Package.swift", "Package.resolved"])
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
    observed.update(parameterized_execution((ROOT / "full-suite.log").read_text()))
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
    {"reuse-red": reuse_red, "green": verify_green, "full": verify_full}[sys.argv[1]]()
