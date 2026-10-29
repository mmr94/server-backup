"""Safety regressions for actual quota accounting and bounded local retention."""
import contextlib
import ftplib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import backup_ftp as backup


class FakeFTP:
    def __init__(self, files):
        self.files = dict(files)
        self.deleted = []
        self.read = []
        self.fail_delete = None

    def voidcmd(self, command):
        return '200 OK'

    def size(self, path):
        return len(self.files[path])

    def retrlines(self, command, callback):
        verb, path = command.split(' ', 1)
        if verb == 'RETR':
            for line in self.files[path].decode().splitlines():
                callback(line)
            return
        assert verb == 'LIST'
        prefix = path.rstrip('/') + '/'
        children = {}
        for filename, content in self.files.items():
            if filename.startswith(prefix):
                name = filename[len(prefix):].split('/')[0]
                children[name] = (False, len(content)) if prefix + name == filename else (True, 0)
        for name, (directory, size) in children.items():
            callback(f'{"d" if directory else "-"}rw------- 1 root root {size} Oct 29 12:00 {name}')

    def retrbinary(self, command, callback, blocksize):
        path = command.removeprefix('RETR ')
        self.read.append(path)
        for offset in range(0, len(self.files[path]), blocksize):
            callback(self.files[path][offset:offset + blocksize])

    def delete(self, path):
        if path == self.fail_delete:
            raise ftplib.error_perm('550 deletion refused')
        self.deleted.append(path)
        del self.files[path]


class QuotaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = {
            'SERVER_NAME': 'core6m', 'FTP_HOST': 'localhost', 'FTP_PORT': '21',
            'FTP_USER': 'fixture', 'FTP_PROTOCOL': 'ftp', 'FTP_BASE_DIR': '/backups',
            'FTP_QUOTA_BYTES': '500', 'FTP_RESERVE_BYTES': '20',
            'KEEP_DAILY': '2', 'KEEP_WEEKLY': '1', 'KEEP_MONTHLY': '1', 'KEEP_YEARLY': '0',
            'KEEP_LOCAL': '1', 'WORK_DIR': str(self.root),
        }
        self.prefix = '/backups/core6m/'

    def name(self, day):
        return f'core6m_2026-10-{day:02d}_031700.tar.zst'

    def archive(self, day, size=80):
        path = self.root / self.name(day)
        path.write_bytes(bytes([day]) * size)
        path.with_name(path.name + '.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '\n')
        return path

    def remote(self, *days, size=80):
        files = {}
        for day in days:
            name = self.prefix + self.name(day)
            content = bytes([day]) * size
            files[name] = content
            files[name + '.sha256'] = (hashlib.sha256(content).hexdigest() + '\n').encode()
        return FakeFTP(files)

    def make_room(self, ftp, local):
        with contextlib.redirect_stdout(io.StringIO()):
            return backup.make_room(ftp, self.config, local)

    def test_real_core_upload_is_allowed_despite_old_growth_projection(self):
        c = dict(self.config, FTP_QUOTA_BYTES='100000000000', FTP_RESERVE_BYTES='10000000000')
        files = {self.prefix + self.name(18): 11558057362, self.prefix + self.name(21): 12385026176, self.prefix + self.name(22): 12391435402}
        files.update({path + '.sha256': 65 for path in list(files)})
        result = backup.capacity(c, files, 17112274890, self.name(28))
        self.assertTrue(result['allowed'])
        self.assertEqual(result['upload_peak_bytes'], 53446794090)
        self.assertEqual(result['delete_before_upload'], [])

    def test_config_quotes_semicolons_and_defaults_are_parsed_without_execution(self):
        config = self.root / 'fixture.conf'
        config.write_text('FTP_HOST="localhost"; FTP_PORT="2121"; FTP_PASS="literal; # secret"\n'
                          'FTP_USER="$(touch should-not-exist)"\n')
        parsed = backup.configuration(config)
        self.assertEqual(parsed['FTP_HOST'], 'localhost')
        self.assertEqual(parsed['FTP_PORT'], '2121')
        self.assertEqual(parsed['FTP_PASS'], 'literal; # secret')
        self.assertEqual(parsed['FTP_USER'], '$(touch should-not-exist)')
        self.assertEqual(parsed['KEEP_DAILY'], '7')
        self.assertFalse((self.root / 'should-not-exist').exists())

    def test_existing_space_never_deletes_a_remote_file(self):
        ftp = self.remote(22)
        local = self.archive(28)
        result = self.make_room(ftp, local)
        self.assertTrue(result['allowed'])
        self.assertEqual(ftp.deleted, [])
        self.assertEqual(ftp.read, [])

    def test_tight_quota_removes_only_the_oldest_pair(self):
        ftp = self.remote(18, 21, 22)
        result = self.make_room(ftp, self.archive(28))
        self.assertEqual(ftp.deleted, [self.prefix + self.name(18), self.prefix + self.name(18) + '.sha256'])
        self.assertEqual(ftp.read, [self.prefix + self.name(22)])
        self.assertTrue(result['allowed'])
        self.assertIn(self.prefix + self.name(22), ftp.files)

    def test_only_remote_backup_is_never_removed(self):
        self.config['FTP_QUOTA_BYTES'] = '250'
        ftp = self.remote(22)
        with self.assertRaisesRegex(RuntimeError, 'nothing deleted'):
            self.make_room(ftp, self.archive(28))
        self.assertEqual(ftp.deleted, [])

    def test_impossible_quota_preserves_all_history(self):
        self.config['FTP_QUOTA_BYTES'] = '200'
        ftp = self.remote(18, 21, 22)
        with self.assertRaisesRegex(RuntimeError, 'nothing deleted'):
            self.make_room(ftp, self.archive(28))
        self.assertEqual(ftp.deleted, [])

    def test_bad_latest_remote_checksum_prevents_all_deletions(self):
        ftp = self.remote(18, 21, 22)
        ftp.files[self.prefix + self.name(22)] = b'X' * 80
        with self.assertRaisesRegex(RuntimeError, 'checksum differs'):
            self.make_room(ftp, self.archive(28))
        self.assertEqual(ftp.deleted, [])

    def test_malformed_sidecar_prevents_all_deletions(self):
        ftp = self.remote(18, 21, 22)
        ftp.files[self.prefix + self.name(22) + '.sha256'] = b'not a checksum\n'
        with self.assertRaisesRegex(RuntimeError, 'malformed'):
            self.make_room(ftp, self.archive(28))
        self.assertEqual(ftp.deleted, [])

    def test_bad_local_checksum_prevents_remote_deletions(self):
        ftp = self.remote(18, 21, 22)
        local = self.archive(28)
        local.write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'Local archive checksum differs'):
            self.make_room(ftp, local)
        self.assertEqual(ftp.deleted, [])

    def test_unknown_files_and_other_servers_are_never_deleted(self):
        ftp = self.remote(18, 21, 22)
        ftp.files['/backups/another/old.tar.zst'] = b'other'
        ftp.files[self.prefix + 'notes.txt'] = b'note'
        self.make_room(ftp, self.archive(28))
        self.assertIn('/backups/another/old.tar.zst', ftp.files)
        self.assertIn(self.prefix + 'notes.txt', ftp.files)
        self.assertEqual(len(ftp.deleted), 2)

    def test_snapshot_archive_is_protected(self):
        ftp = self.remote(18, 21, 22)
        ftp.files[self.prefix + 'core6m_latest.tar.zst'] = b'snapshot'
        self.make_room(ftp, self.archive(28))
        self.assertIn(self.prefix + 'core6m_latest.tar.zst', ftp.files)

    def test_unexpected_delete_failure_keeps_protected_backup(self):
        ftp = self.remote(18, 21, 22)
        ftp.fail_delete = self.prefix + self.name(18)
        with self.assertRaises(ftplib.error_perm):
            self.make_room(ftp, self.archive(28))
        self.assertIn(self.prefix + self.name(22), ftp.files)

    def test_reserve_is_included_in_upload_budget(self):
        result = backup.capacity(self.config, {}, 415)
        self.assertTrue(result['allowed'])
        result = backup.capacity(self.config, {}, 416)
        self.assertFalse(result['allowed'])

    def test_invalid_namespace_is_rejected(self):
        for updates in [{'SERVER_NAME': '..'}, {'FTP_BASE_DIR': '/backups/../other'}]:
            with self.subTest(updates=updates), self.assertRaises(RuntimeError):
                backup.capacity(dict(self.config, **updates), {}, 80)

    def test_verification_failure_does_not_create_receipt(self):
        local = self.archive(28)
        ftp = self.remote(28)
        ftp.files[self.prefix + self.name(28)] = b'X' * 80
        with self.assertRaises(RuntimeError):
            backup.verify(ftp, self.prefix + local.name, local, self.config)
        self.assertFalse((self.root / '.last-verified.json').exists())

    def verified_local(self):
        local = self.archive(22)
        with contextlib.redirect_stdout(io.StringIO()):
            backup.verify(self.remote(22), self.prefix + local.name, local, self.config)
        return local

    def test_failed_upload_local_cleanup_keeps_latest_and_last_verified(self):
        verified = self.verified_local()
        old = self.archive(25)
        pending = self.archive(28)
        result = backup.trim_local_pending(self.config, pending)
        self.assertTrue(verified.exists())
        self.assertTrue(pending.exists())
        self.assertFalse(old.exists())
        self.assertFalse(old.with_name(old.name + '.sha256').exists())
        self.assertEqual(result['local_deleted'], [old.name])

    def test_no_verification_receipt_keeps_all_local_archives(self):
        old = self.archive(25)
        pending = self.archive(28)
        result = backup.trim_local_pending(self.config, pending)
        self.assertTrue(old.exists())
        self.assertEqual(result['local_deleted'], [])

    def test_changed_ftp_account_cannot_trigger_local_cleanup(self):
        self.verified_local()
        old = self.archive(25)
        pending = self.archive(28)
        self.config['FTP_USER'] = 'different'
        with self.assertRaises(RuntimeError):
            backup.trim_local_pending(self.config, pending)
        self.assertTrue(old.exists())

    def test_invalid_pending_archive_cannot_trigger_local_cleanup(self):
        self.verified_local()
        old = self.archive(25)
        pending = self.archive(28)
        pending.write_bytes(b'broken')
        with self.assertRaises(RuntimeError):
            backup.trim_local_pending(self.config, pending)
        self.assertTrue(old.exists())

    def test_symlink_pending_archive_is_rejected(self):
        self.verified_local()
        target = self.archive(28)
        link = self.root / self.name(29)
        link.symlink_to(target)
        with self.assertRaises(RuntimeError):
            backup.trim_local_pending(self.config, link)


if __name__ == '__main__':
    unittest.main(verbosity=2)
