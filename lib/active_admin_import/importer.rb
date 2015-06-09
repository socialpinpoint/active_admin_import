require 'csv'
module ActiveAdminImport
  class Importer

    attr_reader :resource,  :options, :result, :headers, :csv_lines, :model

    def store
      result = @resource.transaction do
        options[:before_batch_import].call(self) if options[:before_batch_import].is_a?(Proc)

        result = resource.import headers.values, csv_lines, {
            validate: options[:validate],
            on_duplicate_key_update: options[:on_duplicate_key_update],
            ignore: options[:ignore],
            timestamps: options[:timestamps]
        }
        options[:after_batch_import].call(self) if options[:after_batch_import].is_a?(Proc)
        result
      end
      {imported: csv_lines.count - result.failed_instances.count, failed: result.failed_instances}
    end

    #
    def prepare_headers(headers)
      @headers = Hash[headers.zip(headers.map { |el| el.underscore.gsub(/\s+/, '_') })]
      @headers.merge!(options[:headers_rewrites])
      @headers
    end

    def initialize(resource, model, options)
      @resource = resource
      @model = model
      @options = {batch_size: 1000, validate: true}.merge(options)
      @headers = model.respond_to?(:csv_headers) ? model.csv_headers : []
      @result= {failed: [], imported: 0}
      if @options.has_key?(:col_sep) || @options.has_key?(:row_sep)
        ActiveSupport::Deprecation.warn "row_sep and col_sep options are deprecated, use csv_options to override default CSV options"
        @csv_options = @options.slice(:col_sep, :row_sep)
      else
        @csv_options = @options[:csv_options] || {}
      end
      #override csv options from model if it respond_to csv_options
      @csv_options =  model.csv_options if model.respond_to?(:csv_options)
      @csv_options.reject! {| key, value | value.blank? }

    end

    def file
      @model.file
    end

    def cycle(lines)
      @csv_lines = CSV.parse(lines.join, @csv_options)
      @result.merge!(self.store) { |key, val1, val2| val1+val2 }
    end

    def batch_replace(header_key, options)
      index = header_index(header_key)
      csv_lines.map! do |line|
        from = line[index]
        line[index] = options[from] if options.has_key?(from)
        line
      end
    end

    def values_at(header_key)
      csv_lines.collect { |line| line[header_index(header_key)] }.uniq
    end

    def header_index(header_key)
      headers.values.index(header_key)
    end

    def import
      options[:before_import].call(self) if options[:before_import].is_a?(Proc)
      lines = []
      batch_size = options[:batch_size].to_i
      File.open(file.path) do |f|
        # capture headers if not exist
        prepare_headers(headers.any? ? headers : CSV.parse(f.readline, @csv_options).first)
        f.each_line do |line|
          lines << line
          if lines.size == batch_size || f.eof?
            cycle lines
            lines = []
          end
        end
      end
      cycle(lines) unless lines.blank?
      options[:after_import].call(self) if options[:after_import].is_a?(Proc)
      result
    end
  end
end
