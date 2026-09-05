# Implementation note: `IPAddr#to_s` string encoding

This note documents why Otto normalizes IP strings produced by its masking
helpers. It is an implementation detail, not a claim about every Ruby 3 release
or every version of the `ipaddr` default gem.

## Verified behavior

Otto's blocking compatibility targets are Ruby 3.2, 3.3, and 3.4. The following
behavior was reproduced locally with representative installed patch releases:

| Ruby | `ipaddr` | IPv4 `IPAddr#to_s` | IPv6 `IPAddr#to_s` |
| --- | --- | --- | --- |
| 3.2.4 | 1.2.5 | `US-ASCII` | `UTF-8` |
| 3.3.5 | 1.2.7 | `US-ASCII` | `UTF-8` |
| 3.4.10 | 1.2.7 | `US-ASCII` | `UTF-8` |

Ruby 4.0.6 with `ipaddr` 1.2.8 showed the same result, but Ruby 4.0 is a
provisional, non-blocking Otto target. See the
[runtime and dependency security policy](../reference/runtime-and-dependency-security.md)
for the current support matrix.

You can check the active runtime directly:

```ruby
require 'ipaddr'

puts RUBY_DESCRIPTION
puts IPAddr::VERSION if defined?(IPAddr::VERSION)
p IPAddr.new('192.168.1.1').to_s.encoding
p IPAddr.new('::1').to_s.encoding
```

The result comes from the `ipaddr` implementation's separate IPv4 and IPv6
formatting paths. Treat it as version-specific behavior and rerun the check when
changing Ruby or overriding the default `ipaddr` gem.

## Otto's normalization

An IP address string contains only ASCII bytes, so relabeling a generated
`US-ASCII` address as `UTF-8` does not change its bytes. Otto uses this at the
boundary where `IPPrivacy.mask_ip` creates IPv4 and IPv6 strings:

```ruby
IPAddr.new(masked_integer, address_family).to_s.force_encoding(Encoding::UTF_8)
```

This gives downstream Rack code one encoding for Otto-generated masked
addresses. A `US-ASCII` string is normally compatible with UTF-8 text; the
encoding difference alone does not imply an error. Normalization prevents code
that requires an explicit UTF-8 label from receiving different labels for IPv4
and IPv6.

Use `force_encoding` here only because Otto constructed the value from an IP
address and therefore knows every byte is ASCII. Do not apply the same operation
to arbitrary external bytes without validating or transcoding them first.
