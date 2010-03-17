module ActsAsXapian
  # Search for a query string, returns an array of hashes in result order.
  # Each hash contains the actual Rails object in :model, and other detail
  # about relevancy etc. in other keys.
  class Search < QueryBase
    attr_accessor :query_string

    @@parse_query_flags = Xapian::QueryParser::FLAG_BOOLEAN | Xapian::QueryParser::FLAG_PHRASE |
      Xapian::QueryParser::FLAG_LOVEHATE | Xapian::QueryParser::FLAG_WILDCARD |
      Xapian::QueryParser::FLAG_SPELLING_CORRECTION

    # Note that model_classes is not only sometimes useful here - it's
    # essential to make sure the classes have been loaded, and thus
    # acts_as_xapian called on them, so we know the fields for the query
    # parser.

    # model_classes - model classes to search within, e.g. [PublicBody,
    # User]. Can take a single model class, or you can express the model
    # class names in strings if you like.
    # query_string - user inputed query string, with syntax much like Google Search
    #
    # options include
    # - :limit - limit the number of records returned
    # - :offset - start with this record number
    # - :check_at_least - used for total match estimates. Set higher for greater accuracy at the cost of slower queries. default: 100
    # - :sort_by_prefix - determines which data field to sort by. default: sort by relevance
    # - :sort_by_ascending - determines which direction to sort. default: true (ascending sort)
    # - :collapse_by_prefix - groups the return set by this prefix
    # - :find_options - These options are passed through to the active record find. Be careful if searching against multiple model classes.
    def initialize(model_classes, query_string, options = {})
      # Check parameters, convert to actual array of model classes
      model_classes = Array(model_classes).map do |model_class|
        model_class = model_class.constantize if model_class.instance_of?(String)
        raise "pass in the model class itself, or a string containing its name" unless model_class.instance_of?(Class)
        model_class
      end

      # Set things up
      self.initialize_db(model_classes)

      # Case of a string, searching for a Google-like syntax query
      self.query_string = query_string

      # Construct query which only finds things from specified models
      model_query = Xapian::Query.new(Xapian::Query::OP_OR, model_classes.map {|mc| "M#{mc}" })
      user_query = @index.query_parser.parse_query(self.query_string, @@parse_query_flags)
      self.query = Xapian::Query.new(Xapian::Query::OP_AND, model_query, user_query)

      # Call base class constructor
      self.initialize_query(options)
    end

    # Return just normal words in the query i.e. Not operators, ones in
    # date ranges or similar. Use this for cheap highlighting with
    # TextHelper::highlight, and excerpt.
    def words_to_highlight
      query_nopunc = self.query_string.gsub(/[^\w:\.\/_]/i, " ").gsub(/\s+/, " ")
      # Split on ' ' and remove anything with a :, . or / in it or boolean operators
      query_nopunc.split(" ").reject {|o| o.match(/(:|\.|\/)|^(AND|NOT|OR|XOR)$/) }
    end

    # Text for lines in log file
    def log_description
      "Search: #{self.query_string}"
    end
  end
end
