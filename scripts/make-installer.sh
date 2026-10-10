#!/bin/sh
# Builds an installer package that puts LiveTether in /Applications and opens it.
#
# Usage:
#   scripts/make-installer.sh <app> <output.pkg> [--sign <installer identity>] [--notarize <notarytool profile>]
#
# <app> is a signed and notarized LiveTether.app. Signing needs a "Developer ID Installer"
# certificate; notarizing needs a profile created with `xcrun notarytool store-credentials`.
set -eu

if [ $# -lt 2 ]; then
    sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
fi

app=$1
output=$2
shift 2
identity=""
profile=""
while [ $# -gt 0 ]; do
    case $1 in
        --sign) identity=$2; shift 2 ;;
        --notarize) profile=$2; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 64 ;;
    esac
done
if [ -n "$profile" ] && [ -z "$identity" ]; then
    echo "--notarize needs --sign: Apple only notarizes signed packages" >&2
    exit 64
fi

scripts_dir=$(cd "$(dirname "$0")" && pwd)
info="$app/Contents/Info.plist"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/root"
ditto "$app" "$work/root/$(basename "$app")"

# Install to /Applications even when a copy of the app exists elsewhere on the disk.
pkgbuild --analyze --root "$work/root" "$work/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$work/components.plist"

pkgbuild --root "$work/root" --component-plist "$work/components.plist" \
    --scripts "$scripts_dir/package" --identifier "$identifier.pkg" --version "$version" \
    --install-location /Applications "$work/component.pkg"

cat > "$work/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>LiveTether</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="14.1"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" visible="false">
        <pkg-ref id="$identifier.pkg"/>
    </choice>
    <pkg-ref id="$identifier.pkg" version="$version" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
EOF

if [ -n "$identity" ]; then
    productbuild --distribution "$work/distribution.xml" --package-path "$work" \
        --sign "$identity" --timestamp "$output"
else
    productbuild --distribution "$work/distribution.xml" --package-path "$work" "$output"
fi

if [ -n "$profile" ]; then
    xcrun notarytool submit "$output" --keychain-profile "$profile" --wait
    xcrun stapler staple "$output"
fi
echo "$output"
