# frozen_string_literal: true

require_relative "test_helper"

class BitBufferTest < Minitest::Test
    def setup
        # Create test data with known bit patterns
        @test_data = StringIO.new([
            0b11001010,  # byte 0
            0b10110011,  # byte 1
            0b00001111,  # byte 2
            0b11110000,  # byte 3
            0b01010101,  # byte 4
            0x00,        # null terminator
            0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00  # "Hello\0"
        ].pack("C*"))
    end

    def test_read_uint_8_bits
        bit = TCD::BitBuffer.new(@test_data)
        assert_equal 0b11001010, bit.read_uint(8)
        assert_equal 0b10110011, bit.read_uint(8)
    end

    def test_read_uint_4_bits
        bit = TCD::BitBuffer.new(@test_data)
        # First byte: 11001010
        assert_equal 0b1100, bit.read_uint(4)
        assert_equal 0b1010, bit.read_uint(4)
        # Second byte: 10110011
        assert_equal 0b1011, bit.read_uint(4)
        assert_equal 0b0011, bit.read_uint(4)
    end

    def test_read_uint_12_bits_across_bytes
        bit = TCD::BitBuffer.new(@test_data)
        # First 12 bits: 11001010 1011
        assert_equal 0b110010101011, bit.read_uint(12)
        # Next 12 bits: 0011 00001111
        assert_equal 0b001100001111, bit.read_uint(12)
    end

    def test_read_uint_odd_bits
        bit = TCD::BitBuffer.new(@test_data)
        # 5 bits: 11001
        assert_equal 0b11001, bit.read_uint(5)
        # 7 bits: 0101011 (crosses byte boundary)
        assert_equal 0b0101011, bit.read_uint(7)
    end

    def test_read_uint_32_bits
        data = StringIO.new([0xDE, 0xAD, 0xBE, 0xEF].pack("C*"))
        bit = TCD::BitBuffer.new(data)
        assert_equal 0xDEADBEEF, bit.read_uint(32)
    end

    def test_read_int_positive
        bit = TCD::BitBuffer.new(@test_data)
        # 8 bits signed: 01001010 = 74 (MSB is 0, so positive)
        # But our data is 11001010 = -54 in signed 8-bit
        result = bit.read_int(8)
        assert_equal(-54, result)
    end

    def test_read_int_negative
        # Create data with a negative value: -100 in 8-bit = 156 = 0b10011100
        data = StringIO.new([0b10011100].pack("C*"))
        bit = TCD::BitBuffer.new(data)
        assert_equal(-100, bit.read_int(8))
    end

    def test_read_int_16_bits
        # -1000 in 16-bit two's complement = 0xFC18
        data = StringIO.new([0xFC, 0x18].pack("C*"))
        bit = TCD::BitBuffer.new(data)
        assert_equal(-1000, bit.read_int(16))
    end

    def test_read_scaled
        data = StringIO.new([0x00, 0x64].pack("C*"))  # 100 in 16-bit
        bit = TCD::BitBuffer.new(data)
        result = bit.read_scaled(16, 10)
        assert_in_delta 10.0, result, 0.001
    end

    def test_read_offset_scaled
        data = StringIO.new([0x00, 0x64].pack("C*"))  # 100 in 16-bit
        bit = TCD::BitBuffer.new(data)
        # (100 + 50) / 10 = 15.0
        result = bit.read_offset_scaled(16, 50, 10)
        assert_in_delta 15.0, result, 0.001
    end

    def test_read_cstring
        # Skip to the "Hello" string (after 6 bytes)
        @test_data.seek(6)
        bit = TCD::BitBuffer.new(@test_data)
        assert_equal "Hello", bit.read_cstring
    end

    def test_read_cstring_from_bit_position
        # Test that read_cstring works when not byte-aligned
        # Create data: 4 bits of padding + "Hi\0"
        # After 4 bits (1111), we need: 'H' (0x48) = 01001000, 'i' (0x69) = 01101001, '\0' = 00000000
        # Full bit stream: 1111 01001000 01101001 00000000
        # = 11110100 10000110 10010000 00 (need more for null terminator)
        # Re-encoding: 1111 0100 1000 0110 1001 0000 0000
        #            = F    4    8    6    9    0    0
        # So bytes are: 0xF4, 0x86, 0x90, 0x00
        data = StringIO.new([0xF4, 0x86, 0x90, 0x00].pack("C*"))
        bit = TCD::BitBuffer.new(data)
        bit.read_uint(4)  # Read 4 bits of padding (1111)
        assert_equal "Hi", bit.read_cstring
    end

    def test_align
        bit = TCD::BitBuffer.new(@test_data)
        bit.read_uint(5)  # Read 5 bits
        bit.align
        # After align, the buffer should be cleared
        # Next read should start fresh from current file position
        assert_equal 0b10110011, bit.read_uint(8)  # Second byte
    end

    def test_seek
        bit = TCD::BitBuffer.new(@test_data)
        bit.read_uint(8)  # Read first byte
        bit.seek(0)       # Seek back to start
        assert_equal 0b11001010, bit.read_uint(8)  # Should read first byte again
    end

    def test_pos
        bit = TCD::BitBuffer.new(@test_data)
        assert_equal 0, bit.pos
        bit.read_uint(8)
        assert_equal 1, bit.pos
        bit.read_uint(8)
        assert_equal 2, bit.pos
    end

    def test_invalid_bit_count
        bit = TCD::BitBuffer.new(@test_data)
        assert_raises(ArgumentError) { bit.read_uint(0) }
        assert_raises(ArgumentError) { bit.read_uint(33) }
        assert_raises(ArgumentError) { bit.read_uint(-1) }
    end
end
