#!/bin/sh
# Generates TabbyMac.xcodeproj from project.yml and opens it.
set -e
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "Install XcodeGen first: https://github.com/yonaskolb/XcodeGen" >&2
    exit 1
  fi
fi
xcodegen generate
open TabbyMac.xcodeproj
