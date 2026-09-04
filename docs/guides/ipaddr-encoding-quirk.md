# IPAddr#to_s Encoding Quirk in Ruby 3

Ruby's `IPAddr#to_s` returns inconsistent encodings: IPv4 addresses use US-ASCII, IPv6 addresses use UTF-8.

## Behavior

```ruby
IPAddr.new('192.168.1.1').to_s.encoding  # => #<Encoding:US-ASCII>
IPAddr.new('::1').to_s.encoding          # => #<Encoding:UTF-8>
```

## Cause

Different string construction in IPAddr's `_to_string` method:

- **IPv4**: `Array#join('.')` → US-ASCII optimization
- **IPv6**: `String#%` → UTF-8 default

## Impact

- Rack expects UTF-8 strings
- Mixed encodings cause `Encoding::CompatibilityError`
- String operations fail on encoding mismatches

## Solution

Use `force_encoding('UTF-8')` instead of `encode('UTF-8')`:

- IP addresses contain only ASCII characters
- ASCII bytes are identical in US-ASCII and UTF-8
- `force_encoding` changes label only (O(1))
- `encode` creates new string (O(n))

This ensures consistent UTF-8 encoding across all IP strings.
