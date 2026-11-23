"""TEMPORARY, on the thread's branch only, never for main. Puts a new version of YANA for iPhone on the App Store
through the App Store Connect API. What it does is the line in asc_mode.txt:
  show                          looks only
  prepare <version> <build>     makes the version if it isn't there (released automatically once approved), gives it
                                the build and asc_whats_new.txt as What's New, and checks it has App Review details
  submit <version>              sends that version to App Review
The repo is public and so are its logs: it prints ids, states and numbers only, never the review contact details."""
import json, os, sys, time
import jwt, requests

APP = "6837471903"
API = "https://api.appstoreconnect.apple.com/v1"
HERE = os.path.dirname(__file__)


def headers():
    now = int(time.time())
    token = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600,
                        "aud": "appstoreconnect-v1"}, os.environ["ASC_KEY"], algorithm="ES256",
                       headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def call(method, path, body=None):
    r = requests.request(method, API + path, headers=headers(), data=json.dumps(body) if body else None, timeout=60)
    if r.status_code >= 400:
        try:
            errors = [(e.get("status"), e.get("code"), e.get("title"), e.get("detail")) for e in r.json()["errors"]]
        except Exception:
            errors = [(r.status_code, "no error list")]
        sys.exit(f"{method} {path.split('?')[0]} -> {r.status_code}: {errors}")
    return r.json() if r.text else {}


def state(v):
    a = v["attributes"]
    return a.get("appVersionState") or a.get("appStoreState")


def versions():
    got = call("GET", f"/apps/{APP}/appStoreVersions?filter[platform]=IOS&include=build&limit=10")
    builds = {b["id"]: b for b in got.get("included", []) if b["type"] == "builds"}
    return [(v, builds.get((v.get("relationships", {}).get("build", {}).get("data") or {}).get("id")))
            for v in got["data"]]


def version(number):
    found = [v for v, _ in versions() if v["attributes"].get("versionString") == number]
    return found[0] if found else None


def store():
    """Whether the app is on the US App Store, as anyone sees it"""
    print("== On the App Store")
    got = requests.get(f"https://itunes.apple.com/lookup?id={APP}&country=us", timeout=30).json()
    for r in got.get("results", []):
        print("  lookup:", r.get("trackName"), "version", r.get("version"), "released", r.get("currentVersionReleaseDate"),
              "url", r.get("trackViewUrl"))
    print("  lookup results:", got.get("resultCount"))
    page = requests.get(f"https://apps.apple.com/us/app/id{APP}", timeout=30, allow_redirects=True)
    print("  page:", page.status_code, page.url)


def show():
    store()
    print("== Versions")
    for v, b in versions():
        a = v["attributes"]
        print(" ", v["id"], a.get("versionString"), "state", state(v), "release", a.get("releaseType"), "build",
              b and b["attributes"].get("version"))
    print("== Review submissions")
    got = call("GET", f"/reviewSubmissions?filter[app]={APP}&filter[platform]=IOS&include=items&limit=10")
    for s in got["data"]:
        a = s["attributes"]
        print(" ", s["id"], a.get("state"), "submitted", a.get("submittedDate"))
    print("== Builds")
    got = call("GET", f"/builds?filter[app]={APP}&sort=-uploadedDate&limit=6&include=preReleaseVersion")
    pre = {p["id"]: p["attributes"].get("version") for p in got.get("included", []) if p["type"] == "preReleaseVersions"}
    for b in got["data"]:
        a = b["attributes"]
        p = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
        print(" ", b["id"], "build", a.get("version"), "of", pre.get(p), a.get("processingState"), "uploaded",
              a.get("uploadedDate"))


def review_detail(vid):
    got = call("GET", f"/appStoreVersions/{vid}/appStoreReviewDetail")
    return got.get("data")


def prepare(number, build_number):
    got = call("GET", f"/builds?filter[app]={APP}&filter[version]={build_number}"
                      f"&filter[preReleaseVersion.version]={number}&limit=5")
    builds = [b for b in got["data"] if b["attributes"].get("version") == build_number]
    if not builds:
        sys.exit(f"No build {build_number} of {number} yet. Nothing was changed")
    build = builds[0]
    if build["attributes"].get("processingState") != "VALID" or build["attributes"].get("expired"):
        sys.exit(f"Build {build_number} is {build['attributes'].get('processingState')}. Nothing was changed")
    print("build", build["id"], build_number, "VALID")

    v = version(number)
    if v is None:
        v = call("POST", "/appStoreVersions", {"data": {"type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": number, "releaseType": "AFTER_APPROVAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}},
                              "build": {"data": {"type": "builds", "id": build["id"]}}}}})["data"]
        print("made version", v["id"], number, state(v))
    else:
        print("version", v["id"], number, state(v), "is there")
        if v["attributes"].get("releaseType") != "AFTER_APPROVAL":
            call("PATCH", f"/appStoreVersions/{v['id']}", {"data": {"type": "appStoreVersions", "id": v["id"],
                 "attributes": {"releaseType": "AFTER_APPROVAL"}}})
            print("set to release automatically once approved")
        call("PATCH", f"/appStoreVersions/{v['id']}/relationships/build", {"data": {"type": "builds", "id": build["id"]}})
        print("build set")

    whats_new = open(os.path.join(HERE, "asc_whats_new.txt"), encoding="utf-8").read().strip()
    locs = call("GET", f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]
    for loc in locs:
        call("PATCH", f"/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations",
             "id": loc["id"], "attributes": {"whatsNew": whats_new}}})
        a = loc["attributes"]
        print("localization", loc["attributes"].get("locale"), "What's New set;", "description",
              bool(a.get("description")), "keywords", bool(a.get("keywords")), "support URL", bool(a.get("supportUrl")))

    detail = review_detail(v["id"])
    fields = ["contactFirstName", "contactLastName", "contactPhone", "contactEmail"]
    if detail:
        print("review details there; filled:", {f: bool(detail["attributes"].get(f)) for f in fields},
              "notes", len(detail["attributes"].get("notes") or ""), "characters")
    else:
        # Copy the contact from the version before, without printing it
        older = [o for o, _ in versions() if o["id"] != v["id"]]
        old = older and review_detail(older[0]["id"])
        if not old:
            sys.exit("No App Review details here or on the version before")
        attrs = {f: old["attributes"].get(f) for f in fields + ["demoAccountRequired", "notes"]}
        call("POST", "/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
             "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
        print("review details copied from", older[0]["attributes"].get("versionString"))


def submit(number):
    v = version(number)
    if v is None or state(v) not in {"PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED", "REJECTED",
                                     "METADATA_REJECTED"}:
        sys.exit(f"Version {number} is {v and state(v)}, not ready to send. Nothing was changed")
    got = call("GET", f"/reviewSubmissions?filter[app]={APP}&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW")
    if got["data"]:
        sub = got["data"][0]
        print("using open submission", sub["id"])
    else:
        sub = call("POST", "/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                   "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
        print("made submission", sub["id"])
    items = call("GET", f"/reviewSubmissions/{sub['id']}/items?include=appStoreVersion")
    has = any((i.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id") == v["id"]
              for i in items["data"])
    if not has:
        call("POST", "/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
             "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
             "appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
        print("version added to the submission")
    done = call("PATCH", f"/reviewSubmissions/{sub['id']}", {"data": {"type": "reviewSubmissions", "id": sub["id"],
                "attributes": {"submitted": True}}})["data"]
    print("submitted:", done["id"], done["attributes"].get("state"))


mode = open(os.path.join(HERE, "asc_mode.txt"), encoding="utf-8").read().split()
print("mode", mode)
if mode[:1] == ["prepare"] and len(mode) == 3:
    prepare(mode[1], mode[2])
elif mode[:1] == ["submit"] and len(mode) == 2:
    submit(mode[1])
elif mode != ["show"]:
    sys.exit("asc_mode.txt should say show, prepare <version> <build>, or submit <version>")
show()
