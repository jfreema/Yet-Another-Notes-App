"""Temporary, on the thread's branch only. Looks at YANA for iPhone's App Store version and its review through the App
Store Connect API. What it does is the one line in asc_mode.txt: "show" only looks, "notes" puts asc_review_notes.txt
in the version's App Review notes, and "prepare <build number>" also makes that build the version's. It never cancels
or submits a review. It prints ids, states and numbers only."""
import json, os, sys, time
import jwt, requests

APP = "6837471903"
API = "https://api.appstoreconnect.apple.com/v1"
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY",
            "READY_FOR_REVIEW"}


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


def notes(version):
    """Puts asc_review_notes.txt in the version's App Review notes. Never prints the review details, which hold the
    contact's name, phone and email."""
    text = open(os.path.join(os.path.dirname(__file__), "asc_review_notes.txt"), encoding="utf-8").read().strip()
    if len(text) > 4000:
        sys.exit(f"The notes are {len(text)} characters, and 4000 is the most")
    detail = call("GET", f"/appStoreVersions/{version}/appStoreReviewDetail?fields[appStoreReviewDetails]=notes")["data"]
    if (detail["attributes"].get("notes") or "").strip() == text:
        print("review notes already as wanted,", len(text), "characters")
        return
    call("PATCH", f"/appStoreReviewDetails/{detail['id']}", {"data": {
        "type": "appStoreReviewDetails", "id": detail["id"], "attributes": {"notes": text}}})
    print("review notes updated,", len(text), "characters")


def editable():
    live = [(v, b) for v, b in versions() if state(v) in EDITABLE]
    if len(live) != 1:
        sys.exit(f"Expected one editable version, found {[(v['id'], state(v)) for v, _ in versions()]}."
                 " Nothing was changed")
    return live[0]


def prepare(number):
    """Sets the editable version's build and its review notes. It cancels and submits nothing."""
    found = [(b, pre) for b, pre in builds(number) if b["attributes"].get("version") == number]
    if not found:
        sys.exit(f"There is no build {number} yet. Nothing was changed")
    build, pre = found[0]
    a = build["attributes"]
    print("build", build["id"], a.get("version"), "of", pre, a.get("processingState"), "expired", a.get("expired"))
    if a.get("processingState") != "VALID" or a.get("expired"):
        sys.exit("That build isn't ready. Nothing was changed")
    version, current = editable()
    if version["attributes"].get("versionString") != pre:
        sys.exit(f"The build is of {pre} and the version is {version['attributes'].get('versionString')}."
                 " Nothing was changed")
    print("version", version["id"], version["attributes"].get("versionString"), state(version), "has build",
          current and current["attributes"].get("version"))
    if current and current["id"] == build["id"]:
        print("that build is already the version's")
    else:
        call("PATCH", f"/appStoreVersions/{version['id']}/relationships/build",
             {"data": {"type": "builds", "id": build["id"]}})
        print("build set")
    notes(version["id"])


mode = open(os.path.join(os.path.dirname(__file__), "asc_mode.txt"), encoding="utf-8").read().split()
print("mode", mode)
if mode[:1] == ["notes"]:
    notes(editable()[0]["id"])
elif mode[:1] == ["prepare"] and len(mode) == 2:
    prepare(mode[1])
elif mode != ["show"]:
    sys.exit("asc_mode.txt should say show, notes, or prepare <build number>")
show()
