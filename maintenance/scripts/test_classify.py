#!/usr/bin/env python3
"""Test script: validate process_document.py classify_with_ollama against real PDFs."""
import sys
sys.path.insert(0, "/data/tax-collector/scripts")

from process_document import classify_with_ollama, extract_text

PDFS = [
    "/data/tax-collector/docs/2025-2026/deductions/work-related/19d19665916e3beb_attachment.pdf",
]

for path in PDFS:
    print(f"\n{'='*60}")
    print(f"FILE: {path}")
    text = extract_text(path)
    print(f"Extracted {len(text)} chars")
    result = classify_with_ollama(text)
    import json
    print(json.dumps(result, indent=2))
