#!/bin/sh
# Xcode build phase (Xcode/project.yml): copies libssh and the libcrypto it links into
# TabbyMac.app/Contents/Frameworks, points the app's binaries at them through @rpath, and
# signs them, so the app runs on a Mac without Homebrew.
#
# The dylibs are Homebrew's (`brew install libssh`), built for the macOS that Homebrew
# targeted on the build Mac; the app's LSMinimumSystemVersion is raised to match (below).
# See docs/ARCHITECTURE.md ("SSH, phase 3").
set -eu

prefix=$(/opt/homebrew/bin/brew --prefix libssh 2>/dev/null || echo /opt/homebrew/opt/libssh)
source_ssh="$prefix/lib/libssh.4.dylib"
[ -f "$source_ssh" ] || { echo "error: libssh not found at $source_ssh (brew install libssh)"; exit 1; }

frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
macos="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
mkdir -p "$frameworks"

# libssh's own dependencies outside the system (libcrypto from openssl@N).
crypto=$(otool -L "$source_ssh" | awk '/libcrypto/ {print $1}' | head -1)
[ -n "$crypto" ] || { echo "error: libssh does not link libcrypto?"; exit 1; }
crypto_name=$(basename "$crypto")

cp -f "$source_ssh" "$frameworks/libssh.4.dylib"
cp -f "$crypto" "$frameworks/$crypto_name"
chmod u+w "$frameworks/libssh.4.dylib" "$frameworks/$crypto_name"

install_name_tool -id "@rpath/libssh.4.dylib" "$frameworks/libssh.4.dylib"
install_name_tool -id "@rpath/$crypto_name" "$frameworks/$crypto_name"
install_name_tool -change "$crypto" "@rpath/$crypto_name" "$frameworks/libssh.4.dylib"
install_name_tool -add_rpath "@loader_path" "$frameworks/libssh.4.dylib" 2>/dev/null || true

# The app binary (and, in Debug, the dylib Xcode splits it into) link libssh by its
# Homebrew path; switch them to the bundled copy.
for binary in "$macos"/*; do
  [ -f "$binary" ] || continue
  for linked in $(otool -L "$binary" | awk '/libssh\.4\.dylib/ {print $1}'); do
    [ "$linked" = "@rpath/libssh.4.dylib" ] && continue
    install_name_tool -change "$linked" "@rpath/libssh.4.dylib" "$binary"
  done
done

# The bundled libraries' minimum macOS (Homebrew builds for the Mac it runs on) becomes the
# app's, so an older Mac gets macOS's "needs a newer macOS" message instead of a crash.
minos_of() { vtool -show-build "$1" 2>/dev/null | awk '/minos/ {print $2; exit}'; }
newer() { awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) { if ((x[i] + 0) != (y[i] + 0)) { print ((x[i] + 0) > (y[i] + 0)) ? a : b; exit } } print a }'; }
need="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
for lib in "$frameworks/libssh.4.dylib" "$frameworks/$crypto_name"; do
  minos=$(minos_of "$lib")
  [ -n "$minos" ] && need=$(newer "$need" "$minos")
done
if [ "$need" != "${MACOSX_DEPLOYMENT_TARGET:-14.0}" ]; then
  echo "warning: the bundled libssh/libcrypto need macOS $need (Homebrew's build); TabbyMac's minimum is raised to $need. Build libssh for macOS ${MACOSX_DEPLOYMENT_TARGET:-14.0} to support older Macs."
  plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $need" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $need" "$plist"
fi

identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$identity" ] || identity="-"
codesign --force --timestamp=none --sign "$identity" "$frameworks/$crypto_name"
codesign --force --timestamp=none --sign "$identity" "$frameworks/libssh.4.dylib"
