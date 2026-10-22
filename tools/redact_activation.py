#!/usr/bin/env python3
"""Offline redaction of a locally captured Albert response. No network requests.
Input may contain secrets: never commit it or paste it in chat. Output is a
closed schema with fixed labels, HTTP status and booleans only.
"""
import argparse
import json
import plistlib
import re
import sys

MAX_BYTES = 1024 * 1024


def summarize(raw: bytes, http_status: int) -> dict:
    if not 100 <= http_status <= 599:
        raise ValueError('HTTP status must be between 100 and 599')
    if len(raw) > MAX_BYTES:
        raise ValueError('Response exceeds the one MiB input limit')
    text = raw.decode('utf-8', errors='replace')
    rejection = 'unclassified'
    if 'DEVICE_INFO_INTEGRITY_FAILED' in text:
        rejection = 'device-info-integrity-failed'
    elif 'Device Unknown' in text or 'DEVICE_UNKNOWN' in text:
        rejection = 'device-unknown'
    match = re.search(r'<Protocol>(.*?)</Protocol>', text, re.DOTALL)
    valid = False
    certificate = False
    if match:
        try:
            parsed = plistlib.loads(match[1].strip().encode('utf-8'))
            if isinstance(parsed, dict):
                valid = True
                record = parsed.get('device-activation', {})
                record = record.get('activation-record', {}) if isinstance(record, dict) else {}
                cert = record.get('DeviceCertificate') if isinstance(record, dict) else None
                certificate = isinstance(cert, bytes) and bool(cert)
        except (ValueError, TypeError, plistlib.InvalidFileException):
            pass
    return {
        'stage': 'apple-activation', 'http_status': http_status,
        'protocol_present': bool(match), 'plist_valid': valid,
        'device_certificate_present': certificate,
        'rejection_class': rejection, 'response_body': 'omitted',
        'action': 'inspect-registration-result' if certificate and http_status < 400 and rejection == 'unclassified' else 'stop-and-investigate',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--http-status', required=True, type=int)
    args = parser.parse_args()
    try:
        report = summarize(sys.stdin.buffer.read(MAX_BYTES + 1), args.http_status)
    except (ValueError, TypeError):
        print('Cannot summarize: invalid status, oversized input or invalid response.', file=sys.stderr)
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
