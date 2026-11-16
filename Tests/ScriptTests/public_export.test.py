import importlib.util
from pathlib import Path
import tempfile
import struct
import zlib
import unittest

module = Path(__file__).resolve().parents[2] / 'scripts/check-public.py'
spec = importlib.util.spec_from_file_location('check_public', module)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
art_spec = importlib.util.spec_from_file_location('strip_artwork', module.with_name('strip-artwork-metadata.py'))
art = importlib.util.module_from_spec(art_spec)
art_spec.loader.exec_module(art)


class PublicBoundary(unittest.TestCase):
    def test_rejects_secrets_private_files_symlinks_and_accepts_key_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'Sources/example.swift'
            source.parent.mkdir()
            source.write_text('let name = "OPENROUTER_API_KEY"\n')
            self.assertEqual(check.inspect(root, 'Sources/example.swift'), [])
            for value in ['sk-' + 'or-v1-' + 'a' * 64, 'gh' + 'p_' + 'a' * 36, 'sk' + '_' + 'a' * 48,
                          '-----BEGIN ' + 'PRIVATE KEY-----', '/Users/' + 'private-user/config']:
                source.write_text(value)
                self.assertTrue(check.inspect(root, 'Sources/example.swift'))
            for name in ['.env.local', '.planning/PLAN.md', 'Resources/account.keychain-db',
                         'Resources/user.wav', 'Design/Koa/koa.blend']:
                self.assertTrue(check.inspect(root, name))
            linked = root / 'Sources/linked.swift'
            linked.symlink_to(source)
            self.assertEqual(check.inspect(root, 'Sources/linked.swift'), [('symlink', 0)])
            self.assertEqual(check.inspect(root, '../outside'), [('unsafe-path', 0)])

    def test_document_fixtures_require_synthetic_identifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / 'Tests/GoogleDocsTests.swift'
            fixture.parent.mkdir()
            fixture.write_text('let id = "' + 'A9_x' * 12 + '"')
            self.assertTrue(check.inspect(root, 'Tests/GoogleDocsTests.swift'))
            fixture.write_text('let id = "synthetic-document-0000000000000001"')
            self.assertEqual(check.inspect(root, 'Tests/GoogleDocsTests.swift'), [])
            fixture.write_text('let url = "https://docs.google.com/document/d/' + 'B7_y' * 12 + '/edit"')
            self.assertTrue(check.inspect(root, 'Tests/GoogleDocsTests.swift'))

    def test_rejects_metadata_in_all_published_media_containers(self):
        def png_chunk(kind, payload):
            return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
        png = b'\x89PNG\r\n\x1a\n' + png_chunk(b'tEXt', b'Author\0Private fixture') + png_chunk(b'IEND', b'')
        self.assertTrue(check.metadata_present(png))
        self.assertFalse(check.metadata_present(b'\x89PNG\r\n\x1a\n' + png_chunk(b'IEND', b'')))
        webp = b'RIFF' + struct.pack('<I', 12) + b'WEBP' + b'EXIF' + struct.pack('<I', 0)
        self.assertTrue(check.metadata_present(webp))
        self.assertTrue(check.metadata_present(b'RIFF' + struct.pack('<I', 100) + b'WEBP' + b'VP8 ' + struct.pack('<I', 200)))
        self.assertTrue(check.metadata_present(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 1000) + b'IDAT' + b'fake'))
        self.assertTrue(check.metadata_present(b'\x89PNG\r\n\x1a\n' + png_chunk(b'tIME', b'fake')))
        icns = b'icns' + struct.pack('>I', len(png) + 16) + b'ic07' + struct.pack('>I', len(png) + 8) + png
        self.assertTrue(check.metadata_present(icns))
        cleaned = art.stripped(icns)
        self.assertFalse(check.metadata_present(cleaned))
        self.assertEqual(art.stripped(art.stripped(png)), art.stripped(png))
        self.assertEqual(art.stripped(png), b'\x89PNG\r\n\x1a\n' + png_chunk(b'IEND', b''))
        mov = struct.pack('>I', 24) + b'moov' + struct.pack('>I', 8) + b'mvhd' + struct.pack('>I', 8) + b'udta'
        self.assertTrue(check.metadata_present(mov))
        self.assertTrue(check.metadata_present(b'icns' + struct.pack('>I', 16) + b'ic07' + struct.pack('>I', 0)))


if __name__ == '__main__':
    unittest.main()
