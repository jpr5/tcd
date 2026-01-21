# frozen_string_literal: true

module TCD
    # Pure Ruby bit-level I/O for reading arbitrary bit-width integers from a binary stream.
    # TCD files use bit-packing where fields don't align to byte boundaries.
    class BitBuffer
        def initialize(io)
            @io = io
            @buffer = 0          # Accumulated bits (MSB first)
            @bits_available = 0  # Number of valid bits in buffer
        end

        # Read n bits as unsigned integer (1-32 bits supported)
        def read_uint(n)
            raise ArgumentError, "bit count must be 1-32, got #{n}" if n < 1 || n > 32

            # Fill buffer until we have enough bits
            while @bits_available < n
                byte = @io.readbyte
                @buffer = (@buffer << 8) | byte
                @bits_available += 8
            end

            # Extract top n bits
            shift = @bits_available - n
            value = (@buffer >> shift) & ((1 << n) - 1)

            # Remove extracted bits from buffer
            @bits_available = shift
            @buffer &= (1 << shift) - 1

            value
        end

        # Read n bits as signed integer (two's complement)
        def read_int(n)
            value = read_uint(n)
            msb = 1 << (n - 1)
            value >= msb ? value - (1 << n) : value
        end

        # Read n bits and apply scale factor: value / scale
        def read_scaled(n, scale, signed: false)
            raw = signed ? read_int(n) : read_uint(n)
            raw.to_f / scale
        end

        # Read n bits with offset and scale: (raw + offset) / scale
        # Used for constituent speeds where offset shifts the range
        def read_offset_scaled(n, offset, scale)
            raw = read_uint(n)
            (raw.to_f + offset) / scale
        end

        # Discard any partial byte and align to next byte boundary
        def align
            @buffer = 0
            @bits_available = 0
        end

        # Read a null-terminated string
        # Strings in TCD are NOT byte-aligned - they start at the current bit position
        # and are read 8 bits at a time until a null byte is found.
        def read_cstring
            chars = []
            loop do
                byte = read_uint(8)
                break if byte == 0
                chars << byte
            end
            chars.pack("C*").force_encoding("ISO-8859-1").encode("UTF-8")
        end

        # Read fixed-size string, stripping null padding
        def read_fixed_string(size)
            align
            bytes = @io.read(size)
            return "" if bytes.nil? || bytes.empty?
            # Find first null and truncate, handle encoding
            bytes.force_encoding("ISO-8859-1")
            null_pos = bytes.index("\x00")
            str = null_pos ? bytes[0, null_pos] : bytes
            str.encode("UTF-8", invalid: :replace, undef: :replace)
        end

        # Current position in underlying IO
        def pos
            @io.pos
        end

        # Seek to absolute position (clears bit buffer)
        def seek(offset)
            @io.seek(offset)
            align
        end
    end
end
