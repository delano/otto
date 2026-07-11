#!/usr/bin/env ruby
# frozen_string_literal: true

# Refresh the local geo-country MMDB database.
#
# Otto vendors no geolocation database — country data goes stale, so you keep a
# public-domain file fresh on your own schedule. This helper downloads the
# `geo-whois-asn-country` MMDB from sapics/ip-location-db (PDDL v1.0, public
# domain, no attribution) and writes it atomically to a target path.
#
# Usage:
#   ruby examples/update_geo_database.rb [target_path]
#
# Environment:
#   OTTO_GEO_DB_PATH  target path (default: data/geo-whois-asn-country.mmdb)
#   OTTO_GEO_DB_URL   source URL (default: sapics latest IPv4+IPv6 release)
#
# Point Otto at the result:
#   otto.configure_ip_privacy(geo_db_path: 'data/geo-whois-asn-country.mmdb')
#
# Cron example (daily refresh; the datafile rebuilds daily upstream):
#   17 4 * * *  cd /srv/app && ruby examples/update_geo_database.rb >> log/geo.log 2>&1

require 'open-uri'
require 'fileutils'
require 'tempfile'

DEFAULT_URL =
  'https://github.com/sapics/ip-location-db/releases/download/latest/geo-whois-asn-country.mmdb'

target = ARGV[0] || ENV['OTTO_GEO_DB_PATH'] || 'data/geo-whois-asn-country.mmdb'
url    = ENV['OTTO_GEO_DB_URL'] || DEFAULT_URL

FileUtils.mkdir_p(File.dirname(target))

puts "Downloading #{url}"
data = URI.parse(url).open('rb', &:read)

if data.nil? || data.empty?
  warn 'Download failed: empty response'
  exit 1
end

# Write atomically so a partial download never replaces a working database.
dir = File.dirname(File.expand_path(target))
tmp = Tempfile.create(['geo-country', '.mmdb'], dir)
begin
  tmp.binmode
  tmp.write(data)
  tmp.close
  File.rename(tmp.path, target)
ensure
  File.unlink(tmp.path) if File.exist?(tmp.path)
end

puts "Wrote #{data.bytesize} bytes to #{target}"
