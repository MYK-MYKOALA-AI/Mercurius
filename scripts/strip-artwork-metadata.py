#!/usr/bin/env python3
"""Remove ancillary metadata from PNG artwork/ICNS, preserving compressed pixels."""
import os
import tempfile
import struct
import sys
from pathlib import Path

PNG = b'\x89PNG\r\n\x1a\n'
PRIVATE = {b'caBX', b'tEXt', b'zTXt', b'iTXt', b'eXIf', b'tIME'}


def stripped(data):
    if data.startswith(PNG):
        offset, chunks = 8, []
        while offset < len(data):
            if offset + 12 > len(data):
                raise ValueError('Truncated PNG')
            size = struct.unpack('>I', data[offset:offset + 4])[0]
            if offset + size + 12 > len(data):
                raise ValueError('Invalid PNG chunk')
            if data[offset + 4:offset + 8] not in PRIVATE:
                chunks.append(data[offset:offset + size + 12])
            offset += size + 12
        return PNG + b''.join(chunks)
    if data.startswith(b'icns'):
        offset, chunks = 8, []
        while offset < len(data):
            if offset + 8 > len(data):
                raise ValueError('Truncated ICNS')
            size = struct.unpack('>I', data[offset + 4:offset + 8])[0]
            if size < 8 or offset + size > len(data):
                raise ValueError('Invalid ICNS chunk')
            payload = data[offset + 8:offset + size]
            if payload.startswith(PNG):
                payload = stripped(payload)
            chunks.append(data[offset:offset + 4] + struct.pack('>I', len(payload) + 8) + payload)
            offset += size
        payload = b''.join(chunks)
        return b'icns' + struct.pack('>I', len(payload) + 8) + payload
    raise ValueError('Expected PNG or ICNS')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: strip-artwork-metadata.py <artwork.png|AppIcon.icns>')
    path = Path(sys.argv[1])
    if path.is_symlink() or not path.is_file():
        raise SystemExit('Expected a regular, non-symlink file')
    data = stripped(path.read_bytes())
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
        os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
