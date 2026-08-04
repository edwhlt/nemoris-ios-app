#!/bin/bash
# Patch embedded onnxruntime.framework MinimumOSVersion to match the app's
# IPHONEOS_DEPLOYMENT_TARGET, then re-sign the framework.
#
# Workaround for App Store Connect validator error 90208:
#   "Invalid Bundle. The bundle Nemoris.app/Frameworks/onnxruntime.framework
#    does not support the minimum OS Version specified in the Info.plist."
#
# Apple's validator (since late 2024) requires embedded frameworks' Info.plist
# MinimumOSVersion to be >= the app's MinimumOSVersion. Microsoft ships
# onnxruntime-swift-package-manager with MinimumOSVersion = 15.1 to maximize
# device compatibility, which trips the validator when the host app targets
# iOS 18+.
#
# This script only touches the Info.plist string; the underlying binary
# remains compatible with iOS 15.1+, so nothing changes at runtime.

set -euo pipefail

FRAMEWORK="${TARGET_BUILD_DIR}/${PRODUCT_NAME}.app/Frameworks/onnxruntime.framework"

if [ ! -d "$FRAMEWORK" ]; then
    echo "[patch-onnx] onnxruntime.framework not found in app bundle — skipping (this is normal for simulator builds without embed)"
    exit 0
fi

INFO_PLIST="$FRAMEWORK/Info.plist"
CURRENT=$(plutil -extract MinimumOSVersion raw "$INFO_PLIST" 2>/dev/null || echo "")
TARGET="${IPHONEOS_DEPLOYMENT_TARGET}"

echo "[patch-onnx] current MinimumOSVersion = '$CURRENT', target = '$TARGET'"

if [ "$CURRENT" = "$TARGET" ]; then
    echo "[patch-onnx] already matches, nothing to do"
    exit 0
fi

plutil -replace MinimumOSVersion -string "$TARGET" "$INFO_PLIST"
echo "[patch-onnx] Info.plist MinimumOSVersion set to $TARGET"

# Re-sign the framework. Required after any modification inside the bundle —
# without this, the existing signature is invalidated and the upload fails
# differently. EXPANDED_CODE_SIGN_IDENTITY is provided by Xcode during signed
# builds (Archive, device builds). For simulator/unsigned builds it may be
# empty, in which case we leave the framework unsigned (it's not uploaded).
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    # Strip extended attributes (e.g. com.apple.provenance) that make codesign
    # abort with "resource fork, Finder information, or similar detritus not
    # allowed" — seen when signing with an older Xcode than the host macOS.
    xattr -cr "$FRAMEWORK"
    codesign --force \
             --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
             --preserve-metadata=identifier,entitlements \
             "$FRAMEWORK"
    echo "[patch-onnx] re-signed framework with identity $EXPANDED_CODE_SIGN_IDENTITY"
else
    echo "[patch-onnx] no signing identity in env — leaving framework unsigned"
fi
