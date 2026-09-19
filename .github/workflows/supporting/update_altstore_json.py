import json
import re
import requests
import zipfile
import plistlib
import io
import os
import tempfile
from pathlib import Path
from datetime import datetime

bundle_id = "app.aidoku.Aidoku"
minimum_ios_version = "15.0"
json_file_name = ".github/workflows/supporting/altstore/apps.json"
github_repo = "Aidoku/Aidoku"

def fetch_latest_release(repo):
    api_url = f"https://api.github.com/repos/{repo}/releases"
    headers = {
        "Accept": "application/vnd.github+json",
    }
    try:
        response = requests.get(api_url, headers=headers, timeout=(10, 60))
        response.raise_for_status()
        releases = response.json()
        if len(releases) == 0:
            raise ValueError("No release found.")

        stable = [release for release in releases
                  if not release.get("draft", False) and not release.get("prerelease", False)
                  and release.get("published_at")]
        if not stable:
            raise ValueError("No published stable release found.")
        return max(stable, key=lambda release: datetime.strptime(
            release["published_at"], "%Y-%m-%dT%H:%M:%SZ"))
    except requests.RequestException as e:
        print(f"Error fetching releases: {e}")
        raise

def markdown_to_plain_text(text):
    # AltStore renders localizedDescription as plain text, so convert the
    # GitHub release markdown into something readable without markup.
    text = text.replace('\r\n', '\n')
    # Links: keep the label and the destination, dropping any <> around the URL.
    text = re.sub(r'\[([^\]]+)\]\(<?([^)>\s]+)>?\)', r'\1 (\2)', text)
    # Bare autolinks written as <https://...>.
    text = re.sub(r'<(https?://[^>\s]+)>', r'\1', text)
    text = re.sub(r'<[^<>]+?>', '', text)
    # Heading and list markers only count at the start of a line.
    text = re.sub(r'^\s{0,3}#{1,6}\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'^(\s*)[-*+]\s+', r'\1• ', text, flags=re.MULTILINE)
    # Emphasis, strikethrough, and inline code.
    text = re.sub(r'(\*\*|__)(.+?)\1', r'\2', text)
    text = re.sub(r'(?<!\w)[*_](\S(?:.*?\S)?)[*_](?!\w)', r'\1', text)
    text = re.sub(r'~~(.+?)~~', r'\1', text)
    text = text.replace('`', '"')
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()

def get_ipa_version_and_build(ipa_path):
    with zipfile.ZipFile(ipa_path, 'r') as ipa:
        info_plist_path = None
        # find info.plist in root of .app
        for name in ipa.namelist():
            if (
                name.startswith('Payload/') and
                name.count('/') == 2 and
                name.endswith('.app/Info.plist')
            ):
                info_plist_path = name
                break
        if not info_plist_path:
            raise FileNotFoundError("Info.plist not found in IPA")

        with ipa.open(info_plist_path) as plist_file:
            plist_data = plist_file.read()
            plist = plistlib.load(io.BytesIO(plist_data))

        version = plist.get('CFBundleShortVersionString')
        build = plist.get('CFBundleVersion')
        return version, build

def update_json_file(json_file, repo):
    latest_release = fetch_latest_release(repo)
    source = Path(json_file)
    with source.open(encoding="utf-8") as file:
        data = json.load(file)
    apps = data.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ValueError("AltStore source has no apps.")
    app = next((item for item in apps if item.get("bundleIdentifier") == bundle_id), None)
    if app is None:
        if len(apps) != 1:
            raise ValueError("Aidoku app is absent from the source.")
        app = apps[0]
    assets = latest_release.get("assets", [])
    asset = next((item for item in assets if item.get("name", "").endswith(".ipa")), None)
    if asset is None:
        raise ValueError("Release has no IPA asset.")

    # Read the bundle version, rather than guessing identity from the release tag.
    # A disk-backed temporary file keeps large archives out of resident memory.
    with tempfile.TemporaryFile() as ipa:
        with requests.get(asset["browser_download_url"], stream=True, timeout=(10, 60)) as response:
            response.raise_for_status()
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    ipa.write(chunk)
        ipa.seek(0)
        version, build = get_ipa_version_and_build(ipa)
    if not isinstance(version, str) or not version or not isinstance(build, str) or not build:
        raise ValueError("IPA is missing its version or build number.")
    versions = app.setdefault("versions", [])
    if any(item.get("version") == version and item.get("buildVersion") == build for item in versions):
        print("No need to update JSON")
        return
    description = latest_release.get("body") or ""
    phrase = "Aidoku Release Information"
    if phrase in description:
        description = description.split(phrase, 1)[1].strip()
    date = datetime.strptime(latest_release["published_at"], "%Y-%m-%dT%H:%M:%SZ")
    data["featuredApps"] = [bundle_id]
    app["bundleIdentifier"] = bundle_id
    versions.insert(0, {
        "version": version,
        "date": date.strftime("%Y-%m-%d"),
        "localizedDescription": markdown_to_plain_text(description),
        "downloadURL": asset["browser_download_url"],
        "size": asset["size"],
        "minOSVersion": minimum_ios_version,
        "buildVersion": build,
    })
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=source.parent,
                                         prefix=".altstore-", suffix=".json", delete=False) as file:
            temporary = file.name
            json.dump(data, file, indent=2)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, source)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)
    print("JSON file updated successfully.")

def main():
    try:
        update_json_file(json_file_name, github_repo)
    except Exception as e:
        print(f"An error occurred: {e}")
        raise

if __name__ == "__main__":
    main()
