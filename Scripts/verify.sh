#!/bin/zsh

set -euo pipefail

scriptDirectory=${0:A:h}
projectRoot=${scriptDirectory:h}

cd "$projectRoot"

xcodebuild \
  -project NoteTree.xcodeproj \
  -scheme NoteTree \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-Debug \
  build

xcodebuild \
  -project NoteTree.xcodeproj \
  -scheme NoteTree \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-Release \
  build

xcodebuild \
  -project NoteTree.xcodeproj \
  -scheme NoteTree \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-Test \
  test

