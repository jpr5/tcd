# frozen_string_literal: true

require_relative "tcd/version"
require_relative "tcd/reader"
require_relative "tcd/inference"

module TCD
    class << self
        # Open a TCD file and return a Reader instance
        def open(path)
            reader = Reader.new(path)
            if block_given?
                begin
                    yield reader
                ensure
                    reader.close
                end
            else
                reader
            end
        end
    end
end
