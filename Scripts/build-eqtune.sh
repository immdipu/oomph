#!/bin/sh
# Builds the eqtune engine from the Vendor/eqtune submodule and bundles it as
# Oomph.app/Contents/Helpers/eqtune, signed with the app's identity, plus its
# licenses. Run by the "Build eqtune engine" phase of the Oomph target.
set -eu

SRC="$SRCROOT/Vendor/eqtune"
CARGO_OUT="$PROJECT_TEMP_DIR/eqtune-cargo"
HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
LICENSES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses"

# rustup installs cargo in ~/.cargo/bin, which isn't on Xcode's PATH, and Homebrew's rustup
# is keg-only, so its cargo isn't in /opt/homebrew/bin either.
PLAIN_PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# A cargo on the caller's PATH comes first: xcodebuild run from a shell, as on CI, whose
# macOS runners keep rustup outside all of the places above.
CARGO=$(command -v cargo || PATH="$PLAIN_PATH" command -v cargo) || {
	echo "error: cargo not found. Oomph builds its audio engine (eqtune) from source: install Rust from https://rustup.rs, then build again."
	exit 1
}
PLAIN_PATH="$(dirname "$CARGO"):$PLAIN_PATH"
if [ ! -f "$SRC/Cargo.toml" ]; then
	echo "error: Vendor/eqtune is empty. Run: git submodule update --init"
	exit 1
fi

# Xcode exports hundreds of build settings and puts its bare toolchain first on PATH;
# both break the Rust build (proc macros, and `cc` without the SDK). Give cargo a plain
# shell environment, on the same Xcode.
env -i HOME="$HOME" USER="${USER:-}" TMPDIR="${TMPDIR:-/tmp}" PATH="$PLAIN_PATH" \
	${DEVELOPER_DIR:+"DEVELOPER_DIR=$DEVELOPER_DIR"} \
	${CARGO_HOME:+"CARGO_HOME=$CARGO_HOME"} ${RUSTUP_HOME:+"RUSTUP_HOME=$RUSTUP_HOME"} \
	cargo build --release --locked --manifest-path "$SRC/Cargo.toml" --target-dir "$CARGO_OUT"

mkdir -p "$HELPERS" "$LICENSES"
cp -f "$CARGO_OUT/release/eqtune" "$HELPERS/eqtune"
cp -f "$SRC/LICENSE-MIT" "$SRC/LICENSE-APACHE" "$LICENSES/"

# Hardened Runtime only loads nested code signed by the app's own identity.
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
	codesign --force --options runtime --timestamp=none --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$HELPERS/eqtune"
fi
