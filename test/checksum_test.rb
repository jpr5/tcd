# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# libtcd stores a CRC-32 of the padded ASCII header right after it, and refuses
# a file whose header does not match. The reader checks it the same way.
class ChecksumTest < Minitest::Test
    FIXTURE = File.expand_path("fixtures/unaligned-11.tcd", __dir__)

    def with_copy(path)
        Dir.mktmpdir do |dir|
            copy = File.join(dir, File.basename(path))
            File.binwrite(copy, File.binread(path))
            yield copy
        end
    end

    def flip_byte(path, offset)
        File.open(path, "r+b") do |f|
            f.seek(offset)
            byte = f.readbyte
            f.seek(offset)
            f.write((byte ^ 0x01).chr)
        end
    end

    def test_valid_files_open
        [FIXTURE, TCD_TEST_FILE].each do |path|
            TCD.open(path) { |db| assert db.constituent_count > 0 }
        end
    end

    def test_fixture_checksum_value
        File.open(FIXTURE, "rb") do |io|
            header = TCD::Header.new(io)
            stored = File.binread(FIXTURE, 4, header.header_size).unpack1("N")
            assert_equal stored, header.stored_checksum(io)
            assert_equal stored, header.compute_checksum(io)
        end
    end

    def test_flipped_header_byte_raises
        with_copy(FIXTURE) do |copy|
            flip_byte(copy, 30)
            err = assert_raises(TCD::ChecksumError) { TCD.open(copy) }
            assert_match(/header checksum mismatch/, err.message)
        end
    end

    def test_flipped_header_padding_byte_raises
        with_copy(FIXTURE) do |copy|
            flip_byte(copy, 4000)
            assert_raises(TCD::ChecksumError) { TCD.open(copy) }
        end
    end

    def test_flipped_stored_checksum_raises
        with_copy(FIXTURE) do |copy|
            size = File.open(copy, "rb") { |io| TCD::Header.new(io).header_size }
            flip_byte(copy, size + 3)
            assert_raises(TCD::ChecksumError) { TCD.open(copy) }
        end
    end

    def test_checksum_error_is_a_format_error
        assert_operator TCD::ChecksumError, :<, TCD::FormatError
    end

    def test_verification_can_be_skipped_explicitly
        with_copy(FIXTURE) do |copy|
            flip_byte(copy, 4000)
            reader = TCD::Reader.new(copy, verify_checksum: false)
            assert_equal 11, reader.constituent_count
            reader.close
        end
    end
end
