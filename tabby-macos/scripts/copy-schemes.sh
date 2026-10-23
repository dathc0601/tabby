#!/bin/sh
# Re-syncs the bundled colour schemes from Tabby's community scheme package.
set -e
cd "$(dirname "$0")/.."
rm -rf Sources/TabbyCore/Resources/schemes
mkdir -p Sources/TabbyCore/Resources/schemes
cp ../tabby-community-color-schemes/schemes/* Sources/TabbyCore/Resources/schemes/
echo "Copied $(ls Sources/TabbyCore/Resources/schemes | wc -l | tr -d ' ') schemes."
