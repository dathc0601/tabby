#!/bin/sh
# Rewrites TabbyMac's catalog template (Sources/TabbyCore/Resources/locale/tabbymac/
# tabbymac.pot) from the L("…") keys in Sources/ that Tabby's catalogs don't have. The
# extractor is CatalogTests; without TABBYMAC_WRITE_POT it checks the template instead.
set -eu
cd "$(dirname "$0")/.."
TABBYMAC_WRITE_POT=1 swift test --filter CatalogTests/testTheAppCatalogTemplateIsCurrent
cat Sources/TabbyCore/Resources/locale/tabbymac/tabbymac.pot
