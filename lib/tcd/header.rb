# frozen_string_literal: true

module TCD
    # Parser for TCD ASCII header section.
    # The header contains [KEY] = VALUE pairs defining all encoding parameters.
    class Header
        REQUIRED_KEYS = %i[
            header_size number_of_records constituents
            start_year number_of_years
        ].freeze

        attr_reader :params

        def initialize(io)
            @params = {}
            parse(io)
            validate!
        end

        # Access header parameters by symbol key
        def [](key)
            @params[key]
        end

        # Check if key exists
        def key?(key)
            @params.key?(key)
        end

        # All parameter keys
        def keys
            @params.keys
        end

        # Convenience accessors for commonly used parameters
        def header_size;       @params[:header_size]; end
        def number_of_records; @params[:number_of_records]; end
        def constituents;      @params[:constituents]; end
        def start_year;        @params[:start_year]; end
        def number_of_years;   @params[:number_of_years]; end
        def version;           @params[:version]; end
        def major_rev;         @params[:major_rev]; end
        def minor_rev;         @params[:minor_rev]; end
        def last_modified;     @params[:last_modified]; end
        def end_of_file;       @params[:end_of_file]; end

        # Bit field parameters
        def speed_bits;        @params[:speed_bits]; end
        def speed_scale;       @params[:speed_scale]; end
        def speed_offset;      @params[:speed_offset]; end
        def equilibrium_bits;  @params[:equilibrium_bits]; end
        def equilibrium_scale; @params[:equilibrium_scale]; end
        def equilibrium_offset; @params[:equilibrium_offset]; end
        def node_bits;         @params[:node_bits]; end
        def node_scale;        @params[:node_scale]; end
        def node_offset;       @params[:node_offset]; end
        def amplitude_bits;    @params[:amplitude_bits]; end
        def amplitude_scale;   @params[:amplitude_scale]; end
        def epoch_bits;        @params[:epoch_bits]; end
        def epoch_scale;       @params[:epoch_scale]; end

        # Record field parameters
        def record_type_bits;  @params[:record_type_bits]; end
        def latitude_bits;     @params[:latitude_bits]; end
        def latitude_scale;    @params[:latitude_scale]; end
        def longitude_bits;    @params[:longitude_bits]; end
        def longitude_scale;   @params[:longitude_scale]; end
        def record_size_bits;  @params[:record_size_bits]; end
        def station_bits;      @params[:station_bits]; end
        def datum_offset_bits; @params[:datum_offset_bits]; end
        def datum_offset_scale; @params[:datum_offset_scale]; end
        def date_bits;         @params[:date_bits]; end
        def months_on_station_bits; @params[:months_on_station_bits]; end
        def confidence_value_bits; @params[:confidence_value_bits]; end
        def time_bits;         @params[:time_bits]; end
        def level_add_bits;    @params[:level_add_bits]; end
        def level_add_scale;   @params[:level_add_scale]; end
        def level_multiply_bits; @params[:level_multiply_bits]; end
        def level_multiply_scale; @params[:level_multiply_scale]; end
        def direction_bits;    @params[:direction_bits]; end

        # Lookup table parameters
        def level_unit_bits;   @params[:level_unit_bits]; end
        def level_unit_types;  @params[:level_unit_types]; end
        def level_unit_size;   @params[:level_unit_size]; end
        def direction_unit_bits; @params[:direction_unit_bits]; end
        def direction_unit_types; @params[:direction_unit_types]; end
        def direction_unit_size; @params[:direction_unit_size]; end
        def restriction_bits;  @params[:restriction_bits]; end
        def restriction_types; @params[:restriction_types]; end
        def restriction_size;  @params[:restriction_size]; end
        def datum_bits;        @params[:datum_bits]; end
        def datum_types;       @params[:datum_types]; end
        def datum_size;        @params[:datum_size]; end
        def legalese_bits;     @params[:legalese_bits]; end
        def legalese_types;    @params[:legalese_types]; end
        def legalese_size;     @params[:legalese_size]; end
        def constituent_bits;  @params[:constituent_bits]; end
        def constituent_size;  @params[:constituent_size]; end
        def tzfile_bits;       @params[:tzfile_bits]; end
        def tzfiles;           @params[:tzfiles]; end
        def tzfile_size;       @params[:tzfile_size]; end
        def country_bits;      @params[:country_bits]; end
        def countries;         @params[:countries]; end
        def country_size;      @params[:country_size]; end

        private

        def parse(io)
            io.rewind
            io.each_line do |line|
                line = line.strip
                break if line == "[END OF ASCII HEADER DATA]"
                next if line.empty?

                if line =~ /^\[(.+?)\]\s*=\s*(.+)$/
                    key = normalize_key($1)
                    value = parse_value($2)
                    @params[key] = value
                end
            end
        end

        def normalize_key(key)
            key.downcase.gsub(/\s+/, "_").to_sym
        end

        def parse_value(value)
            value = value.strip
            case value
            when /^-?\d+$/
                value.to_i
            when /^-?\d+\.\d+$/
                value.to_f
            else
                value
            end
        end

        def validate!
            missing = REQUIRED_KEYS.reject { |k| @params.key?(k) }
            unless missing.empty?
                raise FormatError, "missing required header keys: #{missing.join(', ')}"
            end
        end
    end

    class FormatError < StandardError; end
end
