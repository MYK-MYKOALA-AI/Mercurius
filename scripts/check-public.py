#!/usr/bin/env python3
"""Check tracked/unignored publication files without printing matched secret values."""
import os
import re
import unicodedata
import struct
import subprocess
import sys
from pathlib import Path

TOP = {'.gitignore', '.gitattributes', 'README.md', 'LICENSE', 'LICENSE-ARTWORK.md', 'THIRD-PARTY-NOTICES.md',
       'CONTRIBUTING.md', 'SECURITY.md', 'Package.swift', 'AGENTS.md'}
ROOTS = {'Sources', 'Tests', 'Resources', 'Design', 'scripts', 'assets', 'apps', 'ThirdParty', '.github'}
FORBIDDEN = {'.planning', '.artifacts', '.build', 'dist', 'node_modules', 'Fixtures', '__pycache__'}
RULES = {
    'private-key': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'provider-key': rb'\bsk-(?:or-v1-|proj-|ant-)?[A-Za-z0-9_-]{24,}',
    'elevenlabs-key': rb'\bsk_[a-fA-F0-9]{32,}',
    'google-document-url': rb'https?://docs\.google\.com/(?:document|spreadsheets|presentation)/(?:u/[0-9]+/)?d/(?!synthetic-)[A-Za-z0-9_-]{20,}',
    'github-token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})',
    'aws-key': rb'\bAKIA[A-Z0-9]{16}\b',
    'slack-token': rb'\bxox[baprs]-[A-Za-z0-9-]{15,}',
    'personal-home-path': rb'/Users/[A-Za-z0-9._-]{2,}/|/home/[A-Za-z0-9._-]{2,}/',
    'internal-ticket': rb'\bMYK-[0-9]+',
    # A person's name, full name or list of names beside a date, after a comment marker or bracket.
    # Common past-tense verbs ("Measured 2026-10-12") are allowed; names like Fred and Ted are not.
    'dated-person-note': rb'(?://|#|\(|\[)[ \t]*(?!(?:Measured|Checked|Updated|Added|Changed|Verified|Tested|Fixed|Released|Withdrawn|Seen|Noted|Since|Until|Before|After)\b)[A-Z][a-z]+(?: [A-Z][a-z]+)?(?:(?:,| and|, and) [A-Z][a-z]+)*,? \(?[0-9]{4}-[0-9]{2}-[0-9]{2}',
    'review-round-note': rb'(?i:\breview round\b)|\b(?:Sol|Haiku|Opus|Sonnet|Astra|Neon|Gemini|Codex|Muse|Terra|DeepSeek) (?:r|round )[0-9]+\b'
                         rb'|\bagy\b|\breview r[0-9]+\b|\(round [0-9]+\)|\bPR #[0-9]+ (?:review|branch)\b'
                         rb'|\((?:Sol|Haiku|Opus|Sonnet|Astra|Neon|Codex|Muse|Terra|DeepSeek)(?:(?:,| and|, and) [A-Z][A-Za-z]+)*[,)]',
    'private-path-reference': rb'(?<![A-Za-z0-9_])\.(?:artifacts|planning)/(?=[A-Za-z0-9_.-])',
    'literal-credential': rb'(?i)(?:api[_-]?key|password|secret)\s*[:=]\s*[\x22\x27][A-Za-z0-9_/-]{24,}[\x22\x27]',
}


def metadata_present(data, depth=0, atoms=False):
    if depth > 8:
        return True
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        offset = 8
        while offset + 12 <= len(data):
            size = struct.unpack('>I', data[offset:offset + 4])[0]
            if offset + size + 12 > len(data):
                return True
            if data[offset + 4:offset + 8] in {b'caBX', b'tEXt', b'zTXt', b'iTXt', b'eXIf', b'tIME'}:
                return True
            offset += size + 12
        if offset != len(data):
            return True
    elif data.startswith(b'RIFF') and data[8:12] == b'WEBP':
        offset = 12
        while offset + 8 <= len(data):
            size = struct.unpack('<I', data[offset + 4:offset + 8])[0]
            if offset + size + 8 + (size % 2) > len(data):
                return True
            if data[offset:offset + 4] in {b'EXIF', b'XMP '}:
                return True
            offset += 8 + size + (size % 2)
        if offset != len(data):
            return True
    elif data.startswith(b'icns'):
        offset = 8
        while offset + 8 <= len(data):
            size = struct.unpack('>I', data[offset + 4:offset + 8])[0]
            if size < 8 or offset + size > len(data):
                return True
            if metadata_present(data[offset + 8:offset + size], depth + 1):
                return True
            offset += size
    elif atoms or data[4:8] in {b'ftyp', b'moov', b'trak', b'mdia', b'minf', b'stbl', b'edts', b'dinf', b'wide', b'mdat', b'udta', b'meta', b'uuid'}:
        offset = 0
        while offset + 8 <= len(data):
            size = struct.unpack('>I', data[offset:offset + 4])[0]
            kind = data[offset + 4:offset + 8]
            header = 8
            if size == 1:
                if offset + 16 > len(data):
                    return True
                size = struct.unpack('>Q', data[offset + 8:offset + 16])[0]
                header = 16
            if size == 0:
                size = len(data) - offset
            if size < header or offset + size > len(data):
                return True
            if kind in {b'udta', b'meta', b'uuid'}:
                return True
            if kind in {b'moov', b'trak', b'mdia', b'minf', b'stbl', b'edts', b'dinf'} and metadata_present(data[offset + header:offset + size], depth + 1, True):
                return True
            offset += size
    return False


def nfc(text):
    """Composed and decomposed accents compare equal."""
    return unicodedata.normalize('NFC', text)


def private_terms():
    """Maintainer-only words (names, machines) from a file kept outside the repository."""
    location = os.environ.get('MERCURIUS_PRIVATE_TERMS')
    if not location:
        return []
    lines = nfc(Path(location).read_text(encoding='utf-8')).splitlines()
    return [re.compile(r'(?<!\w)' + re.escape(line.strip()) + r'(?!\w)', re.IGNORECASE)
            for line in lines if line.strip() and not line.lstrip().startswith('#')]


def has_private_term(text, terms):
    text = nfc(text)
    return any(term.search(text) for term in terms)


def inspect(root, relative, terms=()):
    path = Path(relative)
    if has_private_term(relative, terms):
        return [('private-term-in-path', 0)]
    if path.is_absolute() or '..' in path.parts or not path.parts:
        return [('unsafe-path', 0)]
    if any(part in FORBIDDEN for part in path.parts):
        return [('private-directory', 0)]
    if (len(path.parts) == 1 and relative not in TOP) or (len(path.parts) > 1 and path.parts[0] not in ROOTS):
        return [('not-in-public-allowlist', 0)]
    if path.name.startswith('.env') or re.search(r'\.(?:p12|p8|pem|key|keychain(?:-db)?|sqlite\w*|db|wav|jsonl|pyc|blend\d*)$', path.name, re.I):
        return [('private-or-generated-file', 0)]
    for parent in [root / path, *(root / path).parents]:
        if parent == root:
            break
        if parent.is_symlink():
            return [('symlink', 0)]
    source = root / path
    if not source.is_file():
        return [('not-a-regular-file', 0)]
    data = source.read_bytes()
    found = [(name, data[:m.start()].count(b'\n') + 1)
             for name, pattern in RULES.items() for m in re.finditer(pattern, data)]
    if terms:
        text = nfc(data.decode('utf-8', 'replace'))
        found += [('private-term', text[:m.start()].count('\n') + 1) for term in terms for m in term.finditer(text)]
    if path.name.endswith('Tests.swift'):
        for match in re.finditer(rb'\b(?:let|var)\s+(?:id|documentID|docID|spreadsheetID|presentationID)\s*=\s*"([A-Za-z0-9_-]{25,})"', data):
            value = match.group(1)
            if not value.startswith(b'synthetic-') and not re.fullmatch(rb'[a-fA-F0-9]{32,}', value):
                found.append(('non-synthetic-fixture-identifier', data[:match.start()].count(b'\n') + 1))
    if metadata_present(data):
        found.append(('embedded-media-metadata', 0))
    return found


def main():
    root = Path(__file__).resolve().parent.parent
    result = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                            cwd=root, check=True, capture_output=True)
    paths = sorted(set(result.stdout.decode().rstrip('\0').split('\0')) - {''})
    if not paths:
        raise SystemExit('No publication files found; refusing an empty scan.')
    terms = private_terms()
    findings = [(path, rule, line) for path in paths for rule, line in inspect(root, path, terms)]
    for path, rule, line in findings:
        shown = '<path with a private term>' if has_private_term(path, terms) else path
        print(f'{shown}:{line}: {rule}')
    scope = f' and {len(terms)} private terms' if terms else ''
    print(f'Checked {len(paths)} publication files{scope}; {len(findings)} findings. Matched values are never printed.')
    return int(bool(findings))


if __name__ == '__main__':
    sys.exit(main())
