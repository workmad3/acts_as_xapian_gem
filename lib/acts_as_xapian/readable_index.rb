module ActsAsXapian
  class ReadableIndex < Index
    @@available_indicies = {}

    attr_reader :enquire, :query_parser, :values_by_prefix

    # Takes an array of model classes and returns an index object to be
    # used for searching across the given models
    #
    # Prevents query parser interaction across multiple models unless
    # performing a multi model search
    def self.index_for(models)
      index_key = models.map {|m| m.to_s }.sort.join('---')
      if @@available_indicies.key?(index_key)
        index = @@available_indicies[index_key]
        index.reset_enquire!
        index
      else
        index = self.new(models)
        @@available_indicies[index_key] = index
        index
      end
    end

    # Opens the db for reading and builds the query parser
    def initialize(models)
      raise NoXapianRubyBindingsError.new("Xapian Ruby bindings not installed") unless ActsAsXapian.bindings_available
      raise "acts_as_xapian hasn't been called in any models" if @@init_values.empty?

      self.class.prepare_environment

      # basic Xapian objects
      begin
        @db = Xapian::Database.new(@@db_path)
        @enquire = Xapian::Enquire.new(@db)
      rescue IOError
        raise "Xapian database not opened; have you built it with rake xapian:rebuild_index ?"
      end

      init_query_parser(models)
    end

    # Creates a new search session
    def reset_enquire!
      @db.reopen # This grabs the latest db updates
      @enquire = Xapian::Enquire.new(@db)
    rescue IOError
      raise "Xapian database not opened; have you built it with rake xapian:rebuild_index ?"
    end

    protected

    # Make a new query parser
    def init_query_parser(models)
      # for queries
      @query_parser = Xapian::QueryParser.new
      @query_parser.stemmer = @@stemmer
      @query_parser.stemming_strategy = Xapian::QueryParser::STEM_SOME
      @query_parser.database = @db
      @query_parser.default_op = Xapian::Query::OP_AND

      @terms_by_capital = {}
      @values_by_number = {}
      @values_by_prefix = {}
      @value_ranges_store = []

      models.each do |klass|
        options = klass.xapian_options
        # go through the various field types, and tell query parser about them,
        # and error check them - i.e. check for consistency between models
        @query_parser.add_boolean_prefix("model", "M")
        @query_parser.add_boolean_prefix("modelid", "I")
        (options[:terms] || []).each do |term|
          raise "Use up to 3 single capital letters for term code" unless term[1].match(/^[A-Z]{1,3}$/)
          raise "M and I are reserved for use as the model/id term" if term[1] == "M" || term[1] == "I"
          raise "model and modelid are reserved for use as the model/id prefixes" if term[2] == "model" || term[2] == "modelid"
          raise "Z is reserved for stemming terms" if term[1] == "Z"
          raise "Already have code '#{term[1]}' in another model but with different prefix '#{@terms_by_capital[term[1]]}'" if @terms_by_capital.key?(term[1]) && @terms_by_capital[term[1]] != term[2]
          @terms_by_capital[term[1]] = term[2]
          @query_parser.add_prefix(term[2], term[1])
        end
        values = (options[:values] || [])
        values = values.select {|i| i[3] == :number } + values.reject {|i| i[3] == :number }
        values.each do |value|
          raise "Value index '#{value[1]}' must be an integer, is #{value[1].class}" unless value[1].instance_of?(Fixnum)
          raise "Already have value index '#{value[1]}' in another model but with different prefix '#{@values_by_number[value[1]]}'" if @values_by_number.key?(value[1]) && @values_by_number[value[1]] != value[2]
          raise "Already have value prefix '#{value[2]}' in another model but with different index '#{@values_by_prefix[value[2]]}'" if value[3] == :number && @values_by_prefix.key?(value[2]) && @values_by_prefix[value[2]] != value[1]

          # date types are special, mark them so the first model they're seen for
          if !@values_by_number.key?(value[1])
            value_range = case value[3]
            when :date
              Xapian::DateValueRangeProcessor.new(value[1])
            when :string
              Xapian::StringValueRangeProcessor.new(value[1])
            when :number
              Xapian::NumberValueRangeProcessor.new(value[1],"#{value[2]}:",true)
            else
              raise "Unknown value type '#{value[3]}'"
            end

            @query_parser.add_valuerangeprocessor(value_range)

            # stop it being garbage collected, as
            # add_valuerangeprocessor ref is outside Ruby's GC
            @value_ranges_store.push(value_range)
          end

          @values_by_number[value[1]] = value[2]
          @values_by_prefix[value[2]] = value[1]
        end
      end
      
      @values_by_prefix.freeze # This can be read outside the instance. Make sure it can't be changed there
    end
  end
end
