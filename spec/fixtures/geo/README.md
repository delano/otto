# Geo test fixtures

## `otto-test-country.mmdb`

A tiny (~2 KB) MaxMind-DB (MMDB) country database used by the geo specs to
exercise the real `MaxMind::DB` reader end-to-end (loading in `MODE_MEMORY`,
IPv4/IPv6 lookups, the masked-IP fallback path).

**The data is entirely synthetic and public-domain.** It is authored for these
tests and is **not** derived from any licensed geolocation database (no
GeoLite2 / MaxMind / DB-IP data). The country assignments are chosen only to
make specs deterministic and are not authoritative.

It uses the GeoLite2-Country-compatible record schema
(`{"country" => {"iso_code" => "US", ...}}`), the same interop shape emitted by
production sources such as
[sapics/ip-location-db `geo-whois-asn-country`](https://github.com/sapics/ip-location-db)
(PDDL, public domain).

### Networks

| Network              | Country |
| -------------------- | ------- |
| `81.2.69.0/24`       | GB      |
| `8.8.8.0/24`         | US      |
| `1.1.1.0/24`         | AU      |
| `89.160.20.0/24`     | SE      |
| `203.0.113.0/24`     | JP      |
| `2001:4860:4860::/48`| US      |
| `2a02:6b8::/32`      | RU      |

### Regenerating

The fixture is reproducible from its committed generator:

```bash
pip install mmdb_writer netaddr
python3 spec/fixtures/geo/generate_fixture.py
```
