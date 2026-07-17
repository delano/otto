# spec/support/mmdb_fixture.rb
#
# frozen_string_literal: true

require 'ipaddr'

# Minimal MaxMind DB (.mmdb) encoder for test fixtures.
#
# Produces a valid IPv4 country database (record_size 24, ip_version 4) that the
# real MaxMind::DB reader opens in MODE_MEMORY. This lets the geo specs exercise
# the genuine reader path (open + get + result shape) without vendoring a binary
# or depending on an external database.
#
# Format reference: https://maxmind.github.io/MaxMind-DB/
module MmdbFixture
  MARKER = "\xAB\xCD\xEFMaxMind.com".b
  DATA_SEPARATOR = ("\x00".b * 16)

  module_function

  # Build an IPv4 country database.
  #
  # @param networks [Array<Array(String, Integer, String)>] [ip, prefix, iso_code]
  # @return [String] mmdb bytes (ASCII-8BIT)
  def country_db(networks, database_type: 'Test-Country', build_epoch: 1_600_000_000)
    nodes = [new_node]
    data_bytes = []
    data_index = {}

    networks.each do |ip, prefix, iso|
      idx = (data_index[iso] ||= begin
        data_bytes << country_value(iso)
        data_bytes.length - 1
      end)
      insert(nodes, IPAddr.new(ip).to_i, prefix, idx)
    end

    node_count = nodes.length
    data_section = +''.b
    data_offsets = data_bytes.map do |bytes|
      offset = data_section.bytesize
      data_section << bytes
      offset
    end

    tree = +''.b
    nodes.each do |node|
      tree << record(node[:left], node_count, data_offsets)
      tree << record(node[:right], node_count, data_offsets)
    end

    tree + DATA_SEPARATOR + data_section + MARKER +
      metadata(node_count, database_type, build_epoch)
  end

  # Write a database to a temp file and return its path. The Tempfile is kept
  # alive on the returned path's singleton so it is not GC'd mid-test.
  #
  # @return [String] filesystem path to the .mmdb file
  def country_db_file(networks, **opts)
    require 'tempfile'
    file = Tempfile.new(['otto-geo', '.mmdb'])
    file.binmode
    file.write(country_db(networks, **opts))
    file.close
    path = file.path
    path.define_singleton_method(:__tempfile) { file } # retain
    path
  end

  # --- data-type encoders (return ASCII-8BIT byte strings) ---

  def str(value)
    bytes = value.b
    raise ArgumentError, 'fixture strings must be < 29 bytes' if bytes.bytesize >= 29

    [(0x40 | bytes.bytesize)].pack('C') + bytes # type 2 (UTF-8 string)
  end

  def uint(number, type_num)
    bytes = int_bytes(number)
    if type_num <= 7 # non-extended (uint16=5, uint32=6)
      [((type_num << 5) | bytes.bytesize)].pack('C') + bytes
    else # extended (uint64=9)
      [bytes.bytesize].pack('C') + [type_num - 7].pack('C') + bytes
    end
  end

  def u16(number) = uint(number, 5)
  def u32(number) = uint(number, 6)
  def u64(number) = uint(number, 9)

  def int_bytes(number)
    return ''.b if number.zero?

    bytes = +''.b
    while number.positive?
      bytes.prepend((number & 0xff).chr)
      number >>= 8
    end
    bytes
  end

  def arr(elements)
    [elements.length].pack('C') + [11 - 7].pack('C') + elements.join # type 11 (array), extended
  end

  def map(pairs)
    body = pairs.map { |key, value| str(key) + value }.join
    [(0xE0 | pairs.length)].pack('C') + body # type 7 (map)
  end

  def country_value(iso)
    map([['country', map([['iso_code', str(iso)]])]])
  end

  def metadata(node_count, database_type, build_epoch)
    map([
          ['node_count', u32(node_count)],
          ['record_size', u16(24)],
          ['ip_version', u16(4)],
          ['database_type', str(database_type)],
          ['languages', arr([str('en')])],
          ['binary_format_major_version', u16(2)],
          ['binary_format_minor_version', u16(0)],
          ['build_epoch', u64(build_epoch)],
          ['description', map([['en', str('Otto test country db')]])],
        ])
  end

  # --- search-tree construction ---

  def new_node = { left: :empty, right: :empty }

  def insert(nodes, ip_int, prefix, data_idx)
    node_i = 0
    prefix.times do |depth|
      bit = (ip_int >> (31 - depth)) & 1
      key = bit.zero? ? :left : :right
      if depth == prefix - 1
        nodes[node_i][key] = [:data, data_idx]
      else
        node_i = descend(nodes, node_i, key)
      end
    end
  end

  def descend(nodes, node_i, key)
    rec = nodes[node_i][key]
    case rec
    when :empty
      nodes << new_node
      child = nodes.length - 1
      nodes[node_i][key] = [:node, child]
      child
    when Array
      raise ArgumentError, 'overlapping fixture networks unsupported' unless rec[0] == :node

      rec[1]
    end
  end

  def record(rec, node_count, data_offsets)
    value =
      case rec
      when :empty then node_count
      when Array then rec[0] == :node ? rec[1] : node_count + 16 + data_offsets[rec[1]]
      end
    [value].pack('N')[1, 3] # 24-bit big-endian
  end
end
