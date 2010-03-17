module ActsAsXapian
  # Search for models which contain theimportant terms taken from a specified
  # list of models. i.e. Use to find documents similar to one (or more)
  # documents, or use to refine searches.
  class Similar < QueryBase
    attr_accessor :query_models
    attr_accessor :important_terms

    # model_classes - model classes to search within, e.g. [PublicBody, User]
    # query_models - list of models you want to find things similar to
    def initialize(model_classes, query_models, options = {})
      self.initialize_db(model_classes)

      self.runtime += Benchmark::realtime do
        # Case of an array, searching for models similar to those models in the array
        self.query_models = query_models

        # Find the documents by their unique term
        input_models_query = Xapian::Query.new(Xapian::Query::OP_OR, query_models.map {|m| "I#{m.xapian_document_term}" })
        begin
          @index.enquire.query = input_models_query

          # Get set of relevant terms for those documents
          selection = Xapian::RSet.new()
          @index.enquire.mset(0, 100, 100).matches.each {|m| selection.add_document(m.docid) } # XXX so this whole method will only work with 100 docs

          # Bit weird that the function to make esets is part of the enquire
          # object. This explains what exactly it does, which is to exclude
          # terms in the existing query.
          # http://thread.gmane.org/gmane.comp.search.xapian.general/3673/focus=3681
          #
          # Do main search for them
          self.important_terms = @index.enquire.eset(40, selection).terms.map {|e| e.name }
        rescue IOError => e
          if @retried.nil? && /DatabaseModifiedError/.match(e.message.to_s)
            @retried = true
            @index.reset_enquire!
            retry
          end
          raise e
        end

        similar_query = Xapian::Query.new(Xapian::Query::OP_OR, self.important_terms)
        # Exclude original
        combined_query = Xapian::Query.new(Xapian::Query::OP_AND_NOT, similar_query, input_models_query)

        # Restrain to model classes
        model_query = Xapian::Query.new(Xapian::Query::OP_OR, model_classes.map {|mc| "M#{mc}" })
        self.query = Xapian::Query.new(Xapian::Query::OP_AND, model_query, combined_query)
      end

      # Call base class constructor
      self.initialize_query(options)
    end

    # Text for lines in log file
    def log_description
      "Similar: #{self.query_models}"
    end
  end
end
