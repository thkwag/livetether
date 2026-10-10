#!/usr/bin/env python3
"""Checks that every user-facing string is translated into every supported language.

For each string table directory, the English table is the reference: Korean and Japanese must
carry exactly its keys, with the same format specifiers. For the app, every localized literal in
the Swift sources must have an English entry, and English entries no source uses are reported.

Exit status 0 means no errors; warnings do not fail the check.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANGUAGES = ("en", "ko", "ja")
REFERENCE = "en"

# (directory holding <language>.lproj folders, table name, Swift sources whose literals use the table)
TABLES = [
    (ROOT / "App", "Localizable.strings", ROOT / "App"),
    (ROOT / "App", "InfoPlist.strings", None),
    (ROOT / "CameraExtension", "InfoPlist.strings", None),
    (ROOT / "Packages/LumixKit/Sources/LumixVirtualCamera/Resources", "Localizable.strings", None),
]

ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
FORMAT_SPECIFIER = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|lf|f|s)")
# SwiftUI initializers and the app's own views that take a LocalizedStringKey, `String(localized:)`,
# and `title:` arguments.
LOCALIZED_LITERAL = re.compile(
    r'(?:\b(?:Text|Button|Label|Toggle|Picker|Section|LabeledContent|TextField|SecureField|Window|Menu|Link|SettingsGroup|SettingsNote)\(\s*'
    r'|\bString\(localized:\s*|\btitle:\s*)"((?:[^"\\]|\\.)*)"'
)


def read_table(path):
    entries = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("/*") or stripped.startswith("//"):
            continue
        match = ENTRY.match(line)
        if not match:
            raise SystemExit(f"error: {path}:{number}: unreadable line: {line}")
        entries[match.group(1)] = match.group(2)
    return entries


def key_of_literal(literal):
    """Turns a Swift literal into its table key: each interpolation becomes %@."""
    key, index = [], 0
    while index < len(literal):
        if literal.startswith("\\(", index):
            depth, index = 1, index + 2
            while index < len(literal) and depth:
                depth += {"(": 1, ")": -1}.get(literal[index], 0)
                index += 1
            key.append("%@")
        else:
            key.append(literal[index])
            index += 1
    return "".join(key)


def literals_in(sources):
    found = {}
    for path in sorted(sources.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in LOCALIZED_LITERAL.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            found.setdefault(key_of_literal(match.group(1)), f"{path.relative_to(ROOT)}:{line}")
    return found


def main():
    errors, warnings = [], []
    for directory, table, sources in TABLES:
        tables = {}
        for language in LANGUAGES:
            path = directory / f"{language}.lproj" / table
            if not path.exists():
                errors.append(f"{path.relative_to(ROOT)} is missing")
                continue
            tables[language] = read_table(path)
        reference = tables.get(REFERENCE, {})
        for language, entries in tables.items():
            if language == REFERENCE:
                continue
            label = f"{directory.relative_to(ROOT)}/{language}.lproj/{table}"
            for key in reference.keys() - entries.keys():
                errors.append(f"{label} lacks {key!r}")
            for key in entries.keys() - reference.keys():
                errors.append(f"{label} has {key!r}, which English does not")
            for key in reference.keys() & entries.keys():
                if sorted(FORMAT_SPECIFIER.findall(reference[key])) != sorted(FORMAT_SPECIFIER.findall(entries[key])):
                    errors.append(f"{label}: format specifiers of {key!r} differ from English")
        if sources is not None:
            used = literals_in(sources)
            for key, where in sorted(used.items()):
                if key not in reference:
                    errors.append(f"{where}: {key!r} has no English entry in {directory.relative_to(ROOT)}/{REFERENCE}.lproj/{table}")
            for key in sorted(reference.keys() - used.keys()):
                warnings.append(f"{directory.relative_to(ROOT)}/{REFERENCE}.lproj/{table}: {key!r} is not used by any source")
    for warning in warnings:
        print(f"warning: {warning}")
    for error in errors:
        print(f"error: {error}")
    print(f"{len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
