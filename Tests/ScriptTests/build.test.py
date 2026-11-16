"""Exercise packaging boundaries with fake compiler/signing tools; no app launches."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
RESOURCES = ['PrivacyInfo.xcprivacy', 'AppIcon.icns', 'Licences.txt', 'cursus-clip.js', 'Koa/pop_in.mov',
             'Koa/listen_calm.mov', 'Koa/listen_loud.mov', 'Koa/think.mov', 'Koa/happy.mov',
             'Koa/oops.mov', 'Koa/shrug.mov']


class BuildBoundary(unittest.TestCase):
    def fixture(self, parent):
        root = parent / 'source'
        (root / 'scripts').mkdir(parents=True)
        shutil.copyfile(REPO / 'scripts/build-app.sh', root / 'scripts/build-app.sh')
        (root / 'Resources/Koa').mkdir(parents=True)
        (root / '.gitignore').write_text('dist/\n')
        (root / 'Package.swift').write_text('// synthetic manifest fixture')
        for name in RESOURCES:
            (root / 'Resources' / name).write_bytes(b'fixture')
        (root / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'test.mercurius'}))
        tools = parent / 'tools'
        tools.mkdir()
        binary = tools / 'CursusVox'
        binary.write_text('fixture executable')
        for name, text in {
            'xcrun': '#!/bin/sh\ncase "$*" in *--show-bin-path*) printf "%s\\n" "$FIXTURE_BIN";; esac\n',
            'plutil': '#!/bin/sh\nexit 0\n',
            'codesign': '#!/bin/sh\nexit 0\n',
        }.items():
            path = tools / name
            path.write_text(text)
            path.chmod(0o755)
        env = {'PATH': str(tools) + os.pathsep + os.environ['PATH'], 'HOME': os.environ['HOME'],
               'FIXTURE_BIN': str(tools), 'MERCURIUS_SIGNING_IDENTITY': 'Fixture identity'}
        return root, env

    def test_source_archive_and_git_clone_have_honest_source_stamps(self):
        for mode in ['archive', 'clean-clone', 'untracked-source', 'modified-manifest']:
            cloned = mode != 'archive'
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                parent = Path(directory)
                root, env = self.fixture(parent)
                subprocess.run(['git', 'init', '-q', str(root if cloned else parent)], check=True)
                if cloned:
                    subprocess.run(['git', 'add', '.gitignore', 'scripts', 'Resources', 'Package.swift'], cwd=root, check=True)
                    subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
                                    'commit', '-qm', 'fixture'], cwd=root, check=True)
                    if mode == 'untracked-source':
                        (root / 'Sources').mkdir()
                        (root / 'Sources/uncommitted.swift').write_text('// fixture')
                    elif mode == 'modified-manifest':
                        (root / 'Package.swift').write_text('// modified manifest fixture')
                result = subprocess.run(['sh', 'scripts/build-app.sh'], cwd=root, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                app = Path(result.stdout.splitlines()[-1])
                info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
                if mode in ['untracked-source', 'modified-manifest']:
                    self.assertTrue(info['CursusSourceRevision'].endswith('-dirty'))
                elif cloned:
                    expected = subprocess.check_output(['git', 'rev-parse', '--short=12', 'HEAD'], cwd=root, text=True).strip()
                    self.assertEqual(info['CursusSourceRevision'], expected)
                else:
                    self.assertEqual(info['CursusSourceRevision'], 'source-archive')

    def test_missing_identity_ad_hoc_and_symlinked_resources_fail_before_build(self):
        for invalid in ['missing', 'ad-hoc', 'symlink']:
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as directory:
                root, env = self.fixture(Path(directory))
                if invalid == 'missing':
                    env.pop('MERCURIUS_SIGNING_IDENTITY')
                elif invalid == 'ad-hoc':
                    env['MERCURIUS_SIGNING_IDENTITY'] = '-'
                else:
                    icon = root / 'Resources/AppIcon.icns'
                    icon.unlink()
                    icon.symlink_to(root / 'Resources/cursus-clip.js')
                result = subprocess.run(['sh', 'scripts/build-app.sh'], cwd=root, env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / 'dist').exists())


if __name__ == '__main__':
    unittest.main()
