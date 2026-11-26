"""Exercise packaging boundaries with fake compiler/signing tools; no app launches."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
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
        shutil.copyfile(REPO / 'scripts/install.sh', root / 'scripts/install.sh')
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
            'uname': '#!/bin/sh\nprintf "%s\\n" "$FIXTURE_ARCH"\n',
            'xcrun': '#!/bin/sh\ncase "$*" in *--show-bin-path*) printf "%s\\n" "$FIXTURE_BIN";; '
                     '*--product*) [ -z "${FIXTURE_SWAP:-}" ] || /usr/bin/plutil -replace CFBundleIdentifier '
                     '-string com.example.other "$HOME/Applications/Mercurius.app/Contents/Info.plist";; esac\n',
            'plutil': '#!/bin/sh\nexit 0\n',
            'codesign': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$FIXTURE_LOG"\n'
                        'case "$*" in --verify*Mercurius-install*) [ -z "${FIXTURE_VERIFY_FAIL:-}" ] || exit 1;; esac\n',
            'mv': '#!/bin/sh\ncase "$1" in */.Mercurius-install.*/Mercurius.app) '
                  '[ -z "${FIXTURE_MV_FAIL:-}" ] || exit 1; '
                  '[ -z "${FIXTURE_MV_INTERRUPT:-}" ] || { kill -TERM "$PPID"; sleep 1; exit 1; };; esac\n'
                  'exec /bin/mv "$@"\n',
            'sw_vers': '#!/bin/sh\nprintf "%s\\n" "${FIXTURE_MACOS:-26.1}"\n',
            'security': '#!/bin/sh\nprintf "%s" "$FIXTURE_IDENTITIES"\n',
            'pgrep': '#!/bin/sh\nexit 1\n',
            'open': '#!/bin/sh\nprintf "open %s\\n" "$*" >> "$FIXTURE_LOG"\n',
        }.items():
            path = tools / name
            path.write_text(text)
            path.chmod(0o755)
        env = {'PATH': str(tools) + os.pathsep + os.environ['PATH'], 'HOME': os.environ['HOME'],
               'FIXTURE_BIN': str(tools), 'FIXTURE_ARCH': 'arm64',
               'MERCURIUS_SIGNING_IDENTITY': 'Fixture identity', 'FIXTURE_LOG': str(parent / 'log'),
               'FIXTURE_IDENTITIES': ''}
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

    def test_invalid_identity_resources_and_host_fail_before_build(self):
        for invalid in ['missing', 'ad-hoc', 'symlink', 'intel']:
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as directory:
                root, env = self.fixture(Path(directory))
                if invalid == 'missing':
                    env.pop('MERCURIUS_SIGNING_IDENTITY')
                elif invalid == 'ad-hoc':
                    env['MERCURIUS_SIGNING_IDENTITY'] = '-'
                elif invalid == 'intel':
                    env['FIXTURE_ARCH'] = 'x86_64'
                else:
                    icon = root / 'Resources/AppIcon.icns'
                    icon.unlink()
                    icon.symlink_to(root / 'Resources/cursus-clip.js')
                result = subprocess.run(['sh', 'scripts/build-app.sh'], cwd=root, env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                expected = {'missing': b'Set your own Apple', 'ad-hoc': b'ad-hoc signing is not supported',
                            'symlink': b'Missing or symlinked resource: AppIcon.icns',
                            'intel': b'Requires an Apple Silicon Mac.'}
                self.assertIn(expected[invalid], result.stderr)
                self.assertFalse((root / 'dist').exists())

    def test_install_finds_one_own_identity_and_trashes_only_the_old_copy(self):
        dev = 'A' * 40
        one = f'  1) {dev} "Apple Development: Fixture Person (TEAM000001)"\n     1 valid identities found\n'
        two = one + f'  2) {"B" * 40} "Apple Development: Fixture Other (TEAM000002)"\n'
        for case in ['one', 'none', 'two', 'explicit', 'old-macos', 'foreign-app', 'symlink', 'verify-fails',
                     'final-move-fails', 'interrupted', 'swapped-during-build', 'locked']:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                parent = Path(directory)
                root, env = self.fixture(parent)
                home = parent / 'home with space'
                old = home / 'Applications/Mercurius.app'
                (old / 'Contents').mkdir(parents=True)
                bundle = 'com.example.other' if case == 'foreign-app' else 'au.com.mykoala.mercurius'
                (old / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle}))
                (old / 'old').write_text('previous build')
                (home / 'Applications/Other.app').mkdir()
                if case == 'symlink':
                    shutil.rmtree(old)
                    old.symlink_to(home / 'Applications/Other.app')
                env['HOME'] = str(home)
                if case != 'explicit':
                    env.pop('MERCURIUS_SIGNING_IDENTITY')
                env['FIXTURE_IDENTITIES'] = two if case == 'two' else ('' if case == 'none' else one)
                if case == 'old-macos':
                    env['FIXTURE_MACOS'] = '15.6'
                if case == 'verify-fails':
                    env['FIXTURE_VERIFY_FAIL'] = '1'
                if case == 'final-move-fails':
                    env['FIXTURE_MV_FAIL'] = '1'
                if case == 'interrupted':
                    env['FIXTURE_MV_INTERRUPT'] = '1'
                if case == 'swapped-during-build':
                    env['FIXTURE_SWAP'] = '1'
                if case == 'locked':
                    (home / 'Applications/.Mercurius-install.lock').mkdir()
                result = subprocess.run(['sh', 'scripts/install.sh'], cwd=root, env=env, capture_output=True, text=True)
                log = (parent / 'log').read_text() if (parent / 'log').exists() else ''
                leftovers = sorted(p.name for p in (home / 'Applications').glob('.Mercurius-install*'))
                self.assertEqual(leftovers, ['.Mercurius-install.lock'] if case == 'locked' else [])
                if case in ['one', 'explicit']:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue((old / 'Contents/MacOS/CursusVox').is_file())
                    self.assertFalse((old / 'old').exists())
                    trashed = list((home / '.Trash').glob('Mercurius *.app'))
                    self.assertEqual(len(trashed), 1)
                    self.assertEqual((trashed[0] / 'old').read_text(), 'previous build')
                    self.assertTrue((home / 'Applications/Other.app').is_dir())
                    self.assertIn('--sign ' + (dev if case == 'one' else 'Fixture identity'), log)
                    self.assertIn('open ' + str(old), log)
                    self.assertEqual(list((root / 'dist').iterdir()), [])
                else:
                    self.assertNotEqual(result.returncode, 0)
                    expected = {'none': 'Manage Certificates', 'two': 'more than one Apple Development',
                                'old-macos': 'macOS 26 or later', 'foreign-app': 'is not a Mercurius build',
                                'symlink': 'is not a Mercurius build', 'verify-fails': '',
                                'final-move-fails': 'previous Mercurius is back where it was',
                                'interrupted': 'previous Mercurius is back where it was',
                                'swapped-during-build': 'is not a Mercurius build',
                                'locked': 'Another Mercurius install is running'}[case]
                    self.assertIn(expected, result.stderr)
                    self.assertFalse((home / '.Trash').exists())
                    if case == 'symlink':
                        self.assertTrue(old.is_symlink())
                    else:
                        self.assertEqual((old / 'old').read_text(), 'previous build')
                    if case not in ['verify-fails', 'final-move-fails', 'interrupted', 'swapped-during-build']:
                        self.assertNotIn('--sign', log)
    def test_install_quits_only_the_installed_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            root, env = self.fixture(parent)
            home = parent / 'home'
            old = home / 'Applications/Mercurius.app'
            (old / 'Contents/MacOS').mkdir(parents=True)
            (old / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'au.com.mykoala.mercurius'}))
            decoy = parent / 'Other.app/Contents/MacOS'
            decoy.mkdir(parents=True)
            for folder in [old / 'Contents/MacOS', decoy]:
                shutil.copyfile('/bin/sleep', folder / 'CursusVox')
                (folder / 'CursusVox').chmod(0o755)
                # A copied system binary must be re-signed or macOS kills it on launch.
                subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(folder / 'CursusVox')],
                               check=True, capture_output=True)
            running = subprocess.Popen([str(old / 'Contents/MacOS/CursusVox'), '60'])
            other = subprocess.Popen([str(decoy / 'CursusVox'), '60'])
            try:
                time.sleep(0.5)
                self.assertIsNone(running.poll())
                self.assertIsNone(other.poll())
                env['HOME'] = str(home)
                result = subprocess.run(['sh', 'scripts/install.sh'], cwd=root, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNotNone(running.wait(timeout=5))
                self.assertIsNone(other.poll())
            finally:
                for process in [running, other]:
                    if process.poll() is None:
                        process.kill()
                        process.wait()


if __name__ == '__main__':
    unittest.main()
