"""Temporary, on the thread's branch only. Looks at YANA for iPhone's App Store version and its review through the App
Store Connect API. With "swap <build number>" it puts that build in the review in place of the one there: it cancels
the submission that's waiting, sets the build, and submits again. It prints ids, states and numbers only."""
import json, os, sys, time
import jwt, requests

APP = "6837471903"
API = "https://api.appstoreconnect.apple.com/v1"
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY",
            "READY_FOR_REVIEW"}
IN_REVIEW = {"WAITING_FOR_REVIEW", "IN_REVIEW"}
OPEN = {"WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}


def headers():
    now = int(time.time())
    token = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600,
                        "aud": "appstoreconnect-v1"}, os.environ["ASC_KEY"], algorithm="ES256",
                       headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


class Refused(Exception):
    pass


def call(method, path, body=None, soft=False):
    r = requests.request(method, API + path, headers=headers(), data=json.dumps(body) if body else None, timeout=60)
    if r.status_code >= 400:
        # Only what the error is, never a whole body
        try:
            errors = [(e.get("status"), e.get("code"), e.get("title"), e.get("detail")) for e in r.json()["errors"]]
        except Exception:
            errors = [(r.status_code, "no error list")]
        text = f"{method} {path.split('?')[0]} -> {r.status_code}: {errors}"
        if soft:
            raise Refused(text)
        sys.exit(text)
    return r.json() if r.text else {}


def state(version):
    a = version["attributes"]
    return a.get("appVersionState") or a.get("appStoreState")


def versions():
    got = call("GET", f"/apps/{APP}/appStoreVersions?filter[platform]=IOS&include=build&limit=10")
    builds = {b["id"]: b for b in got.get("included", []) if b["type"] == "builds"}
    out = []
    for v in got["data"]:
        b = (v.get("relationships", {}).get("build", {}).get("data") or {}).get("id")
        out.append((v, builds.get(b)))
    return out


def submissions():
    got = call("GET", f"/reviewSubmissions?filter[app]={APP}&filter[platform]=IOS&include=items&limit=20")
    items = {i["id"]: i for i in got.get("included", []) if i["type"] == "reviewSubmissionItems"}
    out = []
    for s in got["data"]:
        mine = [items[i["id"]] for i in (s.get("relationships", {}).get("items", {}).get("data") or []) if i["id"] in items]
        out.append((s, mine))
    return out


def builds(number=None):
    q = f"/builds?filter[app]={APP}&sort=-uploadedDate&limit=12&include=preReleaseVersion"
    if number:
        q += f"&filter[version]={number}"
    got = call("GET", q)
    pre = {p["id"]: p["attributes"].get("version") for p in got.get("included", []) if p["type"] == "preReleaseVersions"}
    out = []
    for b in got["data"]:
        p = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
        out.append((b, pre.get(p)))
    return out


def show():
    print("== Versions")
    for v, b in versions():
        a = v["attributes"]
        print(" ", v["id"], a.get("versionString"), "appStoreState", a.get("appStoreState"), "appVersionState",
              a.get("appVersionState"), "release", a.get("releaseType"), "build",
              b and (b["id"], b["attributes"].get("version")))
    print("== Review submissions")
    for s, items in submissions():
        a = s["attributes"]
        print(" ", s["id"], a.get("state"), "submitted", a.get("submittedDate"), "items",
              [(i["id"], i["attributes"].get("state")) for i in items])
    print("== Builds")
    for b, pre in builds():
        a = b["attributes"]
        print(" ", b["id"], "build", a.get("version"), "of", pre, a.get("processingState"), "expired", a.get("expired"),
              "uploaded", a.get("uploadedDate"), "encryption", a.get("usesNonExemptEncryption"))


def swap(number):
    found = [(b, pre) for b, pre in builds(number) if b["attributes"].get("version") == number]
    if not found:
        sys.exit(f"There is no build {number} yet")
    build, pre = found[0]
    a = build["attributes"]
    print("build", build["id"], a.get("version"), "of", pre, a.get("processingState"), "expired", a.get("expired"))
    if a.get("processingState") != "VALID" or a.get("expired"):
        sys.exit("That build isn't ready, so nothing was changed")

    live = [(v, b) for v, b in versions() if state(v) in EDITABLE | IN_REVIEW]
    if len(live) != 1:
        sys.exit(f"Expected one version that's editable or in review, found {[(v['id'], state(v)) for v, _ in live]}."
                 " Nothing was changed")
    version, current = live[0]
    if version["attributes"].get("versionString") != pre:
        sys.exit(f"The build is of {pre} and the version is {version['attributes'].get('versionString')}."
                 " Nothing was changed")
    print("version", version["id"], version["attributes"].get("versionString"), state(version), "has build",
          current and current["attributes"].get("version"))
    if current and current["id"] == build["id"] and state(version) in IN_REVIEW:
        print("That build is already the one in review")
        return

    for s, _ in submissions():
        if s["attributes"].get("state") in OPEN:
            print("cancelling submission", s["id"], s["attributes"].get("state"))
            call("PATCH", f"/reviewSubmissions/{s['id']}", {"data": {
                "type": "reviewSubmissions", "id": s["id"], "attributes": {"canceled": True}}})

    for _ in range(40):
        version = next(v for v, _ in versions() if v["id"] == version["id"])
        states = [s["attributes"].get("state") for s, _ in submissions()]
        print("  version", state(version), "submissions", states)
        if state(version) in EDITABLE and not any(s in OPEN | {"CANCELING"} for s in states):
            break
        time.sleep(15)
    else:
        sys.exit("The version didn't become editable after the cancel. Run this again to carry on")

    call("PATCH", f"/appStoreVersions/{version['id']}/relationships/build",
         {"data": {"type": "builds", "id": build["id"]}})
    print("build set")
    describe(version["id"])

    ready = [(s, items) for s, items in submissions() if s["attributes"].get("state") == "READY_FOR_REVIEW"]
    if ready:
        submission, items = ready[0]
        print("using submission", submission["id"], "items", [(i["id"], i["attributes"].get("state")) for i in items])
    else:
        submission = call("POST", "/reviewSubmissions", {"data": {
            "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
        items = []
        print("new submission", submission["id"])
    if not items:
        call("POST", "/reviewSubmissionItems", {"data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
        print("version added to the submission")
    for attempt in range(10):
        try:
            call("PATCH", f"/reviewSubmissions/{submission['id']}", {"data": {
                "type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}}, soft=True)
            break
        except Refused as refused:
            print("  not yet:", refused)
            time.sleep(20)
    else:
        sys.exit("It couldn't be submitted. Run this again to carry on")
    print("submitted")
    time.sleep(10)


def describe(version):
    """Puts the listing's description in step with asc_description.txt, if that file is here"""
    path = os.path.join(os.path.dirname(__file__), "asc_description.txt")
    if not os.path.exists(path):
        return
    text = open(path, encoding="utf-8").read().strip()
    for loc in call("GET", f"/appStoreVersions/{version}/appStoreVersionLocalizations")["data"]:
        if loc["attributes"].get("locale") == "en-US" and (loc["attributes"].get("description") or "").strip() != text:
            call("PATCH", f"/appStoreVersionLocalizations/{loc['id']}", {"data": {
                "type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"description": text}}})
            print("description updated,", len(text), "characters")


if len(sys.argv) > 2 and sys.argv[1] == "swap":
    swap(sys.argv[2])
show()
