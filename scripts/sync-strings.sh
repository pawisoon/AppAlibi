#!/bin/zsh
# Pulls new UI strings into the string catalogs after a build.
# The compiler extracts them (SWIFT_EMIT_LOC_STRINGS); xcodebuild does not
# merge them into the .xcstrings files the way Xcode's editor does.
#
#   xcodebuild -project AppAlibi.xcodeproj -scheme AppAlibi -derivedDataPath build/DerivedData build
#   scripts/sync-strings.sh
#
# New keys arrive without a Polish translation. Strings no longer in the code
# are marked stale.
set -euo pipefail
cd "${0:A:h}/.."
objects=build/DerivedData/Build/Intermediates.noindex

sync() {
    local catalog=$1 dir=$2
    local -a args
    for file in $objects/$dir/**/*.stringsdata(N); do args+=(--stringsdata $file); done
    (( ${#args} )) || { print -u2 "No .stringsdata under $objects/$dir. Build first."; exit 1 }
    xcrun xcstringstool sync $catalog $args
}

sync AppAlibi/Localizable.xcstrings AppAlibi.build
sync AlibiKit/Sources/AlibiKit/Resources/Localizable.xcstrings AlibiKit.build

python3 - <<'PY'
import json
for path in ["AppAlibi/Localizable.xcstrings", "AlibiKit/Sources/AlibiKit/Resources/Localizable.xcstrings"]:
    strings = json.load(open(path))["strings"]
    todo = [k for k, v in strings.items()
            if v.get("shouldTranslate", True) and "pl" not in v.get("localizations", {})]
    print(f"{path}: {len(strings)} strings, {len(todo)} without Polish")
    for key in todo:
        print("  ", key)
PY
