#!/usr/bin/env python3
"""Regenerate spec/fixtures/geo/otto-test-country.mmdb.

This is the reproducible source for Otto's geo test fixture. The fixture is a
tiny, GeoLite2-Country-compatible MMDB whose data is entirely SYNTHETIC and
authored for Otto's specs — it is not derived from any licensed geolocation
database (no GeoLite2/MaxMind/DB-IP data). The country assignments below are
chosen only to exercise the reader integration and are not authoritative.

Requires (dev-only, not a runtime or gem dependency):
    pip install mmdb_writer netaddr

Usage:
    python3 spec/fixtures/geo/generate_fixture.py
"""
from mmdb_writer import MMDBWriter
from netaddr import IPSet

# GeoLite2-Country compatible record: {"country": {"iso_code": ..., "names": {...}}}
def country(code, name):
    return {"country": {"iso_code": code, "names": {"en": name}}}

# Synthetic network -> country map. /24s so a /24-masked IP resolves identically.
NETWORKS = {
    "81.2.69.0/24": country("GB", "United Kingdom"),
    "8.8.8.0/24": country("US", "United States"),
    "1.1.1.0/24": country("AU", "Australia"),
    "89.160.20.0/24": country("SE", "Sweden"),
    "203.0.113.0/24": country("JP", "Japan"),
    # IPv6 (masked IPv6 keeps the leading network bits, so a /32 network matches)
    "2001:4860:4860::/48": country("US", "United States"),
    "2a02:6b8::/32": country("RU", "Russia"),
}

writer = MMDBWriter(
    ip_version=6,
    database_type="otto-test-country",
    languages=["en"],
    ipv4_compatible=True,
    description={"en": "Otto synthetic country fixture (test-only, public domain)"},
)

for cidr, record in NETWORKS.items():
    writer.insert_network(IPSet([cidr]), record)

out = "spec/fixtures/geo/otto-test-country.mmdb"
writer.to_db_file(out)
print(f"wrote {out}")
