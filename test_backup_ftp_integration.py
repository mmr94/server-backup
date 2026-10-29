"""Real FTP / shell pipeline tests; bind only to an ephemeral loopback port."""
import hashlib
import json
import logging
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer


SCRIPT = Path(__file__).with_name('server-backup.sh')


class BackupFTPIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='unisoft-quota-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ftp_root = self.root / 'ftp'
        self.ftp_root.mkdir()
        self.work = self.root / 'work'
        self.work.mkdir()
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'config.txt').write_text('isolated backup fixture\n')
        self.name = 'quota-fixture'
        self.events = []
        self.corrupt_reads = False
        authorizer = DummyAuthorizer()
        authorizer.add_user('fixture', 'fixture-only-password', str(self.ftp_root), perm='elradfmwMT')
        owner = self

        class Handler(FTPHandler):
            def ftp_DELE(self, file):
                owner.events.append(('delete', Path(file).name))
                return super().ftp_DELE(file)

            def ftp_RETR(self, file):
                owner.events.append(('read', Path(file).name))
                if owner.corrupt_reads and file.endswith('.tar.zst'):
                    path = Path(file)
                    data = path.read_bytes()
                    path.write_bytes(bytes([data[0] ^ 255]) + data[1:])
                return super().ftp_RETR(file)

        Handler.authorizer = authorizer
        Handler.banner = 'isolated test'
        logging.getLogger('pyftpdlib').setLevel(logging.ERROR)
        self.server = FTPServer(('127.0.0.1', 0), Handler)
        logging.getLogger('pyftpdlib').setLevel(logging.ERROR)
        self.port = self.server.socket.getsockname()[1]
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={'timeout': 0.05, 'blocking': True, 'handle_exit': False}, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.config = self.root / 'backup.conf'
        self.settings = {
            'SERVER_NAME': self.name, 'FTP_HOST': '127.0.0.1', 'FTP_PORT': str(self.port),
            'FTP_USER': 'fixture', 'FTP_PASS': 'fixture-only-password', 'FTP_PROTOCOL': 'ftp',
            'FTP_BASE_DIR': '/backups', 'INCLUDE_PATHS': str(self.source), 'EXCLUDE_PATTERNS': '*.log',
            'WORK_DIR': str(self.work), 'LOG_FILE': str(self.root / 'backup.log'),
            'CAPTURE_SYSTEM_STATE': 'no', 'EXCLUDE_SECRETS': 'no', 'BACKUP_MODE': 'history',
            'TIMEOUT_SECONDS': '0', 'ONE_FILE_SYSTEM': 'no', 'FTP_QUOTA_BYTES': '10000000',
            'FTP_RESERVE_BYTES': '1000', 'BACKUP_VERIFY_REMOTE': 'yes', 'KEEP_LOCAL': '1',
            'KEEP_DAILY': '1', 'KEEP_WEEKLY': '0', 'KEEP_MONTHLY': '0', 'KEEP_YEARLY': '0',
        }
        self.write_config()

    def stop_server(self):
        # Close the selector on its own thread (kqueue rejects cross-thread
        # close while polling on macOS).
        self.server.ioloop.call_later(0, self.server.close_all)
        self.thread.join(timeout=3)
        if self.thread.is_alive():
            raise RuntimeError('Isolated FTP server did not stop')

    def write_config(self):
        self.config.write_text(''.join(key + '=' + json.dumps(value) + '\n' for key, value in self.settings.items()))
        self.config.chmod(0o600)

    def remote_archive(self, day, size=100):
        directory = self.ftp_root / 'backups' / self.name
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f'{self.name}_2026-10-{day:02d}_031700.tar.zst'
        path.write_bytes(bytes([day]) * size)
        path.with_name(path.name + '.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '\n')
        return path

    def invoke(self, *args):
        result = subprocess.run(['bash', str(SCRIPT), '--config', str(self.config), *map(str, args)],
                                capture_output=True, text=True, timeout=90)
        (self.root / 'last-run.log').write_text(result.stdout + result.stderr)
        return result

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_upload_verification_precedes_remote_and_local_rotation(self):
        old = self.remote_archive(21)
        self.remote_archive(22)
        local_old = self.work / old.name
        local_old.write_bytes(old.read_bytes())
        local_old.with_name(local_old.name + '.sha256').write_text(old.with_name(old.name + '.sha256').read_text())
        result = self.invoke()
        self.assert_success(result)
        receipt = json.loads((self.work / '.last-verified.json').read_text())
        remote = self.ftp_root / 'backups' / self.name
        self.assertEqual([p.name for p in remote.glob('*.tar.zst')], [receipt['archive']])
        self.assertEqual([p.name for p in self.work.glob('*.tar.zst')], [receipt['archive']])
        verified_read = self.events.index(('read', receipt['archive']))
        deletions = [i for i, event in enumerate(self.events) if event[0] == 'delete']
        self.assertTrue(deletions)
        self.assertTrue(all(i > verified_read for i in deletions))
        self.assertTrue(receipt['sha256_match'])

    def test_large_retention_forecast_does_not_block_fitting_upload(self):
        self.settings['KEEP_DAILY'] = '10000'
        self.settings['FTP_QUOTA_BYTES'] = '100000'
        self.write_config()
        self.remote_archive(21)
        self.remote_archive(22)
        result = self.invoke()
        self.assert_success(result)
        self.assertFalse(any(event[0] == 'delete' for event in self.events))

    def test_minimal_pre_upload_cleanup_preserves_latest_verified_backup(self):
        self.assert_success(self.invoke('--prepare-only'))
        local = next(self.work.glob('*.tar.zst'))
        first = self.remote_archive(20, size=5000)
        second = self.remote_archive(21, size=5000)
        latest = self.remote_archive(22, size=5000)
        self.settings['KEEP_DAILY'] = '10'
        total = sum(p.stat().st_size for p in first.parent.iterdir())
        self.settings['FTP_QUOTA_BYTES'] = str(total + local.stat().st_size + 65 + 1000 - 100)
        self.write_config()
        self.assert_success(self.invoke('--upload-existing', local))
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())
        self.assertTrue(latest.exists())
        self.assertIn(('read', latest.name), self.events)
        self.assertNotIn(('delete', latest.name), self.events)

    def test_corrupted_upload_never_rotates_previous_remote_archives(self):
        first = self.remote_archive(21)
        latest = self.remote_archive(22)
        self.corrupt_reads = True
        result = self.invoke()
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertTrue(first.exists())
        self.assertTrue(latest.exists())
        self.assertFalse(any(event[0] == 'delete' for event in self.events))
        self.assertFalse((self.work / '.last-verified.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
