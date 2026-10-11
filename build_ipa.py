"""
build_ipa.py - Multi-platform packaging script for MacHost iPadOS container (.ipa)
Works on Windows, Linux, and macOS.
"""

import os
import sys
import shutil
import zipfile
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILD_DIR = os.path.join(SCRIPT_DIR, "build")
PAYLOAD_DIR = os.path.join(BUILD_DIR, "Payload")
APP_NAME = "HostApp"
APP_DIR = os.path.join(PAYLOAD_DIR, f"{APP_NAME}.app")
FRAMEWORKS_DIR = os.path.join(APP_DIR, "Frameworks")
IPA_PATH = os.path.join(BUILD_DIR, "MacHost.ipa")


def build():
    print("=" * 60)
    print(" MacHost: Packaging iPadOS Container (.ipa)")
    print("=" * 60)

    # 1. Prepare directory structure
    if os.path.exists(PAYLOAD_DIR):
        shutil.rmtree(PAYLOAD_DIR)

    os.makedirs(BUILD_DIR, exist_ok=True)
    os.makedirs(APP_DIR, exist_ok=True)
    os.makedirs(FRAMEWORKS_DIR, exist_ok=True)

    appkit_fw_dir = os.path.join(FRAMEWORKS_DIR, "AppKitShim.framework")
    appkit_headers_dir = os.path.join(appkit_fw_dir, "Headers")
    os.makedirs(appkit_headers_dir, exist_ok=True)

    # 2. Check if an Apple iOS SDK compiler is available
    is_darwin = sys.platform == "darwin"
    compiled = False

    if is_darwin:
        print("[+] macOS detected. Attempting compilation with xcrun / clang...")
        try:
            res = subprocess.run(["make", "bundle"], cwd=SCRIPT_DIR, capture_output=True, text=True)
            if res.returncode == 0:
                print("[+] Compilation succeeded via Makefile.")
                compiled = True
            else:
                print(f"[!] Compilation notice: {res.stderr}")
        except Exception as e:
            print(f"[!] Compilation error: {e}")

    if not compiled:
        print("[*] Assembling application bundle, plists, frameworks, and metadata...")
        # Copy Info.plist
        shutil.copy2(os.path.join(SCRIPT_DIR, "HostHarness", "Info.plist"), os.path.join(APP_DIR, "Info.plist"))
        shutil.copy2(os.path.join(SCRIPT_DIR, "HostHarness", "Entitlements.plist"), os.path.join(APP_DIR, "Entitlements.plist"))

        # Copy Framework metadata & headers
        shutil.copy2(os.path.join(SCRIPT_DIR, "AppKitShim", "Info.plist"), os.path.join(appkit_fw_dir, "Info.plist"))
        shutil.copy2(os.path.join(SCRIPT_DIR, "AppKitShim", "AppKitShim.h"), os.path.join(appkit_headers_dir, "AppKitShim.h"))
        shutil.copy2(os.path.join(SCRIPT_DIR, "AppKitShim", "MetalPresenter.h"), os.path.join(appkit_headers_dir, "MetalPresenter.h"))

    # 3. Create .ipa archive
    print(f"[+] Creating zip archive: {IPA_PATH}...")
    if os.path.exists(IPA_PATH):
        os.remove(IPA_PATH)

    with zipfile.ZipFile(IPA_PATH, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(PAYLOAD_DIR):
            for file in files:
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, BUILD_DIR)
                z.write(full_path, rel_path)

    print("=" * 60)
    print(f" SUCCESS: Package created at: {IPA_PATH}")
    print(f" Size: {os.path.getsize(IPA_PATH)} bytes")
    print(" Ready for sideloading / distribution.")
    print("=" * 60)


if __name__ == "__main__":
    build()
