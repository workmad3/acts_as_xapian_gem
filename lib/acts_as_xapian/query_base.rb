module ActsAsXapian
  # Base class for Search and Similar below
  class QueryBase
    attr_accessor :offset, :limit, :query, :query_models, :runtime, :cached_results
    @@unlimited = 1000000

    # Return a description of the query
    def description
      self.query.description
    end

    # Returns the mset for the query
    def matches(reload = false)
      return @matches unless @matches.nil? || reload

      begin
        self.runtime += Benchmark::realtime do
          # If using find_options conditions have Xapian return the entire match set
          # TODO Revisit. This is extremely inefficient for large indices
          @matches = @index.enquire.mset(@postpone_limit ? 0 : @offset, @postpone_limit ? @@unlimited : @limit, @check_at_least)
        end
        @matches
      rescue IOError => e
        if @retried.nil? && /DatabaseModifiedError/.match(e.message.to_s)
          @retried = true
          @index.reset_enquire!
          initialize_enquire
          retry
        end
        raise e
      end
    end

    # Estimate total number of results
    # Note: Unreliable if using find_options with conditions or joins
    def matches_estimated
      @matches_estimated || self.matches.matches_estimated
    end

    # Return query string with spelling correction
    def spelling_correction
      correction = @index.query_parser.get_corrected_query_string
      correction.empty? ? nil : correction
    end

    # Return array of models found
    def results
      # If they've already pulled out the results, just return them.
      return self.cached_results unless self.cached_results.nil?

      docs = nil
      self.runtime += Benchmark::realtime do
        # Pull out all the results
        docs = self.matches.matches.map {|doc| {:data => doc.document.data, :percent => doc.percent, :weight => doc.weight, :collapse_count => doc.collapse_count} }
      end

      # Log time taken, excluding database lookups below which will be displayed separately by ActiveRecord
      ActiveRecord::Base.logger.debug("  Xapian query (%.5fs) #{self.log_description.gsub('%','%%')}" % self.runtime) if ActiveRecord::Base.logger

      # Group the ids by the model they belong to
      lhash = docs.inject({}) do |s,doc|
        model_name, id = doc[:data].split('-')
        (s[model_name] ||= []) << id
        s
      end

      if @postpone_limit
        found = lhash.map do |(class_name, ids)|
          model = class_name.constantize # constantize is expensive do once
          model.with_xapian_scope(ids) { model.find(:all, @find_options.merge(:select => "#{model.table_name}.#{model.primary_key}")) }.map {|m| m.xapian_document_term }
        end.flatten

        self.runtime += Benchmark::realtime do
          found = found.inject({}) {|s,i| s[i] = true; s } # hash key searching is MUCH faster than an array sequential scan
          docs.delete_if {|doc| !found.delete(doc[:data]) }

          @matches_estimated = docs.size

          docs = docs[@offset,@limit] || []

          lhash = docs.inject({}) do |s,doc|
            model_name, id = doc[:data].split('-')
            (s[model_name] ||= []) << id
            s
          end
        end
      end

      # for each class, look up the associated ids
      chash = lhash.inject({}) do |out, (class_name, ids)|
        model = class_name.constantize # constantize is expensive do once
        found = model.with_xapian_scope(ids) { model.find(:all, @find_options) }
        out[class_name] = found.inject({}) {|s,f| s[f.id] = f; s }
        out
      end

      # add the model to each doc
      docs.each do |doc|
        model_name, id = doc[:data].split('-')
        doc[:model] = chash[model_name][id.to_i]
      end

      self.cached_results = docs
    end

    protected

    def initialize_db(models)
      self.runtime = 0.0

      @index = ReadableIndex.index_for(models)

      raise "ActsAsXapian::ReadableIndex not initialized" if @index.nil?
    end

    # Set self.query before calling this
    def initialize_query(options)
      self.runtime += Benchmark::realtime do
        @offset = options[:offset].to_i
        @limit = (options[:limit] || @@unlimited).to_i
        @check_at_least = (options[:check_at_least] || 100).to_i
        @sort_by_prefix = options[:sort_by_prefix]
        @sort_by_ascending = options[:sort_by_ascending].nil? ? true : options[:sort_by_ascending]
        @collapse_by_prefix = options[:collapse_by_prefix]
        @find_options = options[:find_options]
        @postpone_limit = !(@find_options.blank? || (@find_options[:conditions].blank? && @find_options[:joins].blank?))

        self.cached_results = nil
      end

      initialize_enquire
    end

    def initialize_enquire
      self.runtime += Benchmark::realtime do
        @index.enquire.query = self.query

        if @sort_by_prefix.nil?
          @index.enquire.sort_by_relevance!
        else
          value = @index.values_by_prefix[@sort_by_prefix]
          raise "couldn't find prefix '#{@sort_by_prefix}'" if value.nil?
          # Xapian has inverted the meaning of ascending order to handle relevence sorting
          # "keys which sort higher by string compare are better"
          @index.enquire.sort_by_value_then_relevance!(value, !@sort_by_ascending)
        end

        if @collapse_by_prefix.nil?
          @index.enquire.collapse_key = Xapian.BAD_VALUENO
        else
          value = @index.values_by_prefix[@collapse_by_prefix]
          raise "couldn't find prefix '#{@collapse_by_prefix}'" if value.nil?
          @index.enquire.collapse_key = value
        end
      end
      true
    end
  end
end
