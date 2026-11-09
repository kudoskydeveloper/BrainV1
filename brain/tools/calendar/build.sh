#!/bin/zsh
# Builds Brain Calendar.app, the EventKit helper behind the calendar and reminders tools. It is an app so macOS asks for
# Calendar/Reminders access once, for it. Signed with your Apple Development identity when there is one, so the access
# survives rebuilds (an ad-hoc signature changes with every build and macOS forgets the permission).
cd "$(dirname "$0")" || exit 1
mkdir -p "Brain Calendar.app/Contents/MacOS" && cp Info.plist "Brain Calendar.app/Contents/" \
  && swiftc -O main.swift -o "Brain Calendar.app/Contents/MacOS/brain-calendar" || exit 1
id=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign -f -s "${id:--}" "Brain Calendar.app" && echo "built (signed: ${id:-ad-hoc})"
