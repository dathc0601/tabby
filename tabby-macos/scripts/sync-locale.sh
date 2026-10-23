#!/bin/sh
# Copies Tabby's translations (../locale/*.po, managed on Crowdin) into TabbyCore's
# resources. Run after pulling new translations into ../locale.
set -eu
cd "$(dirname "$0")/.."
dst=Sources/TabbyCore/Resources/locale/tabby
mkdir -p "${dst:?}"
rm -f "${dst:?}"/*.po
cp ../locale/*.po "${dst:?}"/
echo "$(ls "$dst" | wc -l | tr -d ' ') catalogs in $dst"
