import importlib.util
import json
from pathlib import Path
import plistlib
import unittest

spec = importlib.util.spec_from_file_location('redactor', Path(__file__).parents[1] / 'tools/redact_activation.py')
redactor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(redactor)


class DiagnosticTests(unittest.TestCase):
    def test_no_untrusted_values_exported(self):
        # Deliberately fake sentinels, never real credentials or identifiers.
        marker = 'SENSITIVE_FIXTURE_SENTINEL'
        raw = ('<html>' + marker + ' Device Unknown</html>').encode()
        result = redactor.summarize(raw, 403)
        output = json.dumps(result)
        self.assertNotIn(marker, output)
        self.assertEqual(result['rejection_class'], 'device-unknown')
        self.assertEqual(result['action'], 'stop-and-investigate')

    def test_integrity_failure(self):
        result = redactor.summarize(b'DEVICE_INFO_INTEGRITY_FAILED', 200)
        self.assertEqual(result['rejection_class'], 'device-info-integrity-failed')
        self.assertEqual(result['action'], 'stop-and-investigate')

    def test_certificate_presence_is_not_registration_success(self):
        body = plistlib.dumps({'device-activation': {'activation-record': {'DeviceCertificate': b'fixture-not-a-real-certificate'}}})
        result = redactor.summarize(b'<Protocol>\n' + body + b'\n</Protocol>', 200)
        self.assertTrue(result['device_certificate_present'])
        self.assertEqual(result['action'], 'inspect-registration-result')
        self.assertNotIn('fixture-not-a-real-certificate', json.dumps(result))

    def test_malformed_protocol(self):
        result = redactor.summarize(b'<Protocol>not plist</Protocol>', 200)
        self.assertTrue(result['protocol_present'])
        self.assertFalse(result['plist_valid'])
        self.assertEqual(result['action'], 'stop-and-investigate')

    def test_bad_nested_schema(self):
        body = plistlib.dumps({'device-activation': ['unexpected']})
        result = redactor.summarize(b'<Protocol>' + body + b'</Protocol>', 200)
        self.assertFalse(result['device_certificate_present'])

    def test_empty_and_invalid_utf8(self):
        for raw in [b'', b'\xff\xfe', b'login@example.invalid SECRET_FIXTURE']:
            with self.subTest(raw=raw):
                result = redactor.summarize(raw, 503)
                self.assertEqual(result['action'], 'stop-and-investigate')
                self.assertNotIn('SECRET_FIXTURE', json.dumps(result))

    def test_limits(self):
        with self.assertRaises(ValueError): redactor.summarize(b'x' * (redactor.MAX_BYTES + 1), 200)
        with self.assertRaises(ValueError): redactor.summarize(b'', 999)

    def test_http_failure_even_with_cert(self):
        body = plistlib.dumps({'device-activation': {'activation-record': {'DeviceCertificate': b'fake'}}})
        result = redactor.summarize(b'<Protocol>' + body + b'</Protocol>', 403)
        self.assertEqual(result['action'], 'stop-and-investigate')


if __name__ == '__main__': unittest.main()
