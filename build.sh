#!/usr/bin/env bash
# build.sh - Build and packaging script for MacHost iPadOS container (.ipa)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

BUILD_DIR="build"
PAYLOAD_DIR="${BUILD_DIR}/Payload"
APP_NAME="HostApp"
APP_DIR="${PAYLOAD_DIR}/${APP_NAME}.app"
FRAMEWORKS_DIR="${APP_DIR}/Frameworks"
IPA_NAME="MacHost.ipa"

echo "=========================================================="
echo " MacHost: Native macOS Binary Execution Container for iPadOS"
echo "=========================================================="

# 1. Clean & Prepare Directories
mkdir -p "${BUILD_DIR}"
mkdir -p "${PAYLOAD_DIR}"
mkdir -p "${APP_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"
mkdir -p "${FRAMEWORKS_DIR}/AppKitShim.framework/Headers"

# 2. Detect Platform & Toolchain
IS_DARWIN=0
if [[ "$(uname -s)" == "Darwin" ]]; then
    IS_DARWIN=1
fi

if [[ ${IS_DARWIN} -eq 1 ]]; then
    echo "[+] Detected macOS host. Resolving iOS SDK..."
    SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
    CC="xcrun -sdk iphoneos clang"
    HOST_CC="clang"
    TARGET_FLAGS="-target arm64-apple-ios14.0 -isysroot ${SDK_PATH}"
else
    echo "[!] Non-Darwin host. Using standard clang / cross-compilation flags..."
    CC="clang"
    HOST_CC="clang"
    TARGET_FLAGS="-target arm64-apple-ios14.0"
fi

CFLAGS="-O2 -Wall -Wextra -fobjc-arc ${TARGET_FLAGS}"
INCLUDES="-I MachOPatcher -I DyldInterpose -I AppKitShim -I HostHarness"
LDFLAGS="-framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore -framework Metal"

# 3. Build Host MachOPatcher Tool
echo "[+] Compiling host machopatch utility..."
${HOST_CC} -O2 -Wall -Wextra -I MachOPatcher \
    MachOPatcher/MachOPatcher.c MachOPatcher/machopatch_cli.c \
    -o "${BUILD_DIR}/machopatch" || echo "[!] Notice: Host machopatch build skipped (compiler unavailable)."

# 4. Build DyldInterpose Dynamic Library
echo "[+] Compiling libDyldInterpose.dylib..."
${CC} ${CFLAGS} -dynamiclib \
    -install_name @rpath/libDyldInterpose.dylib \
    DyldInterpose/DyldInterpose.c \
    -o "${FRAMEWORKS_DIR}/libDyldInterpose.dylib"

# 5. Build AppKitShim Framework
echo "[+] Compiling AppKitShim.framework..."
${CC} ${CFLAGS} ${INCLUDES} -dynamiclib \
    -install_name @rpath/AppKitShim.framework/AppKitShim \
    -framework Foundation -framework CoreGraphics -framework QuartzCore -framework Metal -framework UIKit \
    AppKitShim/AppKitShim.m AppKitShim/MetalPresenter.m \
    -o "${FRAMEWORKS_DIR}/AppKitShim.framework/AppKitShim"

cp AppKitShim/AppKitShim.h "${FRAMEWORKS_DIR}/AppKitShim.framework/Headers/"
cp AppKitShim/MetalPresenter.h "${FRAMEWORKS_DIR}/AppKitShim.framework/Headers/"
cp AppKitShim/Info.plist "${FRAMEWORKS_DIR}/AppKitShim.framework/Info.plist"

# 6. Build HostApp Executable
echo "[+] Compiling HostApp executable..."
${CC} ${CFLAGS} ${INCLUDES} \
    MachOPatcher/MachOPatcher.c \
    HostHarness/JITHelper.m \
    HostHarness/ContainerViewController.m \
    HostHarness/AppDelegate.m \
    HostHarness/main.m \
    -L"${FRAMEWORKS_DIR}" -lDyldInterpose \
    -F"${FRAMEWORKS_DIR}" -framework AppKitShim \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    ${LDFLAGS} \
    -o "${APP_DIR}/${APP_NAME}"

# 7. Copy App Bundle Resources
echo "[+] Copying bundle resources and plists..."
cp HostHarness/Info.plist "${APP_DIR}/Info.plist"

# 8. Code Signing with Entitlements
echo "[+] Signing application bundle..."
if command -v ldid >/dev/null 2>&1; then
    echo "    Using ldid with HostHarness/Entitlements.plist..."
    ldid -S "${FRAMEWORKS_DIR}/libDyldInterpose.dylib"
    ldid -S "${FRAMEWORKS_DIR}/AppKitShim.framework/AppKitShim"
    ldid -SHostHarness/Entitlements.plist "${APP_DIR}/${APP_NAME}"
elif command -v codesign >/dev/null 2>&1; then
    echo "    Using codesign with ad-hoc signature..."
    codesign -s - --force "${FRAMEWORKS_DIR}/libDyldInterpose.dylib"
    codesign -s - --force "${FRAMEWORKS_DIR}/AppKitShim.framework"
    codesign -s - --entitlements HostHarness/Entitlements.plist --force "${APP_DIR}/${APP_NAME}"
else
    echo "    [!] Neither ldid nor codesign found; bundle assembled without signature."
fi

# 9. Package into .ipa
echo "[+] Packaging into sideloadable ${IPA_NAME}..."
(
    cd "${BUILD_DIR}"
    if command -v zip >/dev/null 2>&1; then
        zip -qry "${IPA_NAME}" Payload
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import zipfile, os; z = zipfile.ZipFile('${IPA_NAME}', 'w', zipfile.ZIP_DEFLATED); [z.write(os.path.join(root, f), os.path.relpath(os.path.join(root, f), '.')) for root, dirs, files in os.walk('Payload') for f in files]; z.close()"
    elif command -v python >/dev/null 2>&1; then
        python -c "import zipfile, os; z = zipfile.ZipFile('${IPA_NAME}', 'w', zipfile.ZIP_DEFLATED); [z.write(os.path.join(root, f), os.path.relpath(os.path.join(root, f), '.')) for root, dirs, files in os.walk('Payload') for f in files]; z.close()"
    fi
)

echo "=========================================================="
echo " BUILD COMPLETE: ${BUILD_DIR}/${IPA_NAME}"
echo " Ready for sideloading via SideStore, AltStore, TrollStore, or Xcode."
echo "=========================================================="
