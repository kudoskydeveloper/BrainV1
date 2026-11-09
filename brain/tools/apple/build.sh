#!/bin/zsh
# Builds Brain Apple.app, the helper behind the Photos and Maps tools (PhotoKit, Vision, MapKit). It is an app so macOS asks
# for Photos access once, for it. Signed with your Apple Development identity when there is one, so the access survives rebuilds.
cd "$(dirname "$0")" || exit 1
mkdir -p "Brain Apple.app/Contents/MacOS" && cp Info.plist "Brain Apple.app/Contents/" \
  && swiftc -O -parse-as-library main.swift -o "Brain Apple.app/Contents/MacOS/brain-apple" || exit 1
id=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign -f -s "${id:--}" "Brain Apple.app" && echo "built (signed: ${id:-ad-hoc})"
