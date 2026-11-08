#!/usr/bin/env python3
"""Generate an isolated test PKI using cryptography, never modifying system trust."""
from datetime import datetime, timedelta, timezone
from ipaddress import ip_address
from pathlib import Path
import sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

root = Path(sys.argv[1])
now = datetime.now(timezone.utc)
def key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)
def name(value):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, value)])
def authority(value):
    private = key()
    cert = (x509.CertificateBuilder().subject_name(name(value)).issuer_name(name(value))
            .public_key(private.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=2)).not_valid_after(now + timedelta(days=30))
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
            .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
            .sign(private, hashes.SHA256()))
    return private, cert
ca_key, ca = authority('BasedFTP isolated test CA')
wrong_key, wrong_ca = authority('BasedFTP unrelated test CA')
for filename, cert in [('ca.pem', ca), ('wrong-ca.pem', wrong_ca)]:
    (root / filename).write_bytes(cert.public_bytes(serialization.Encoding.PEM))
for variant, issuer_key, issuer, before, after in [
    ('valid', ca_key, ca, now - timedelta(days=1), now + timedelta(days=7)),
    ('expired', ca_key, ca, now - timedelta(days=7), now - timedelta(days=1)),
    ('bad-data', wrong_key, wrong_ca, now - timedelta(days=1), now + timedelta(days=7)),
]:
    private = key()
    cert = (x509.CertificateBuilder().subject_name(name('127.0.0.1')).issuer_name(issuer.subject)
            .public_key(private.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(before).not_valid_after(after)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ip_address('127.0.0.1'))]), critical=False)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .sign(issuer_key, hashes.SHA256()))
    (root / (variant + '.pem')).write_bytes(cert.public_bytes(serialization.Encoding.PEM) + issuer.public_bytes(serialization.Encoding.PEM))
    target = root / (variant + '.key')
    target.write_bytes(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    target.chmod(0o600)
