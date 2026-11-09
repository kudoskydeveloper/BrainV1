#!/bin/zsh
# Builds the local PDF/OCR extractor used by read_file.
cd "$(dirname "$0")" && swiftc -O main.swift -o brain-extract && echo built
