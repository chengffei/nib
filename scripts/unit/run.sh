#!/bin/sh
# Compiles the shell's Foundation-only files together with the checks and runs them; no app build needed.
set -e
cd "$(dirname "$0")/../.."
OUT=.build/unit
mkdir -p "$OUT"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} swiftc -O -o "$OUT/checks" \
  Nib/Pinyin.swift Nib/ImageSizes.swift scripts/unit/main.swift
"$OUT/checks"
