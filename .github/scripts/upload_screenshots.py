"""Temporary: uploads screens-store/*.png as the 6.9-inch iPhone screenshots of the app's editable App Store version,
through the App Store Connect API, replacing any already there."""
import glob, hashlib, json, os, sys, time
import jwt, requests

APP = "6837471903"
API = "https://api.appstoreconnect.apple.com/v1"
token = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 1200,
                    "aud": "appstoreconnect-v1"}, os.environ["ASC_KEY"], algorithm="ES256",
                   headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
H = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def call(method, path, body=None):
    r = requests.request(method, path if path.startswith("http") else API + path, headers=H,
                         data=json.dumps(body) if body else None)
    if r.status_code >= 400:
        sys.exit(f"{method} {path} -> {r.status_code}: {r.text[:2000]}")
    return r.json() if r.text else {}

versions = call("GET", f"/apps/{APP}/appStoreVersions?filter[platform]=IOS")["data"]
version = next(v for v in versions if v["attributes"]["appStoreState"] in
               ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"))
print("version", version["attributes"]["versionString"], version["attributes"]["appStoreState"])
locs = call("GET", f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
loc = next(l for l in locs if l["attributes"]["locale"] == "en-US")
sets = call("GET", f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
print("existing sets", [s["attributes"]["screenshotDisplayType"] for s in sets])
shot_set = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_IPHONE_67"), None)
if shot_set:
    for old in call("GET", f"/appScreenshotSets/{shot_set['id']}/appScreenshots")["data"]:
        call("DELETE", f"/appScreenshots/{old['id']}")
else:
    shot_set = call("POST", "/appScreenshotSets", {"data": {
        "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations",
                                                                   "id": loc["id"]}}}}})["data"]

ids = []
for path in sorted(glob.glob("screens-store/*.png")):
    data = open(path, "rb").read()
    shot = call("POST", "/appScreenshots", {"data": {
        "type": "appScreenshots", "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": shot_set["id"]}}}}})["data"]
    for op in shot["attributes"]["uploadOperations"]:
        part = data[op["offset"]:op["offset"] + op["length"]]
        r = requests.request(op["method"], op["url"], data=part,
                             headers={h["name"]: h["value"] for h in op["requestHeaders"]})
        r.raise_for_status()
    call("PATCH", f"/appScreenshots/{shot['id']}", {"data": {
        "type": "appScreenshots", "id": shot["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    ids.append((path, shot["id"]))
    print("uploaded", path)

for _ in range(30):
    states = {p: call("GET", f"/appScreenshots/{i}")["data"]["attributes"]["assetDeliveryState"] for p, i in ids}
    print(json.dumps(states))
    if all(s["state"] in ("COMPLETE", "FAILED") for s in states.values()):
        break
    time.sleep(10)
if any(s["state"] != "COMPLETE" for s in states.values()):
    sys.exit("Not all screenshots finished processing")
print("All screenshots are in")
