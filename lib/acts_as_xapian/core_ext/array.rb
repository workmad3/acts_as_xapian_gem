module ActsAsXapian
  module ArrayExt
    # Creates a ActsAsXapian::Similar search passing through the options to the search
    #
    # The model classes to search are automatically generated off the classes of the
    # entries in the array. If you want more control over which models to search,
    # specify option :models and it will override the default behavior
    def search_similar(options = {})
      raise "All entries must be xapian models" unless all? {|i| i.class.respond_to?(:xapian?) && i.class.xapian? }
      models = options.delete(:models)
      ActsAsXapian::Similar.new(models || map {|i| i.class }.uniq, self, options)
    end

    # Runs a ActsAsXapian::Similar search passing back the returned models instead of the
    # search object. Takes all the same options as search_similar
    def find_similar(options = {})
      search_similar(options).results.map {|x| x[:model] }
    end
  end
end

Array.class_eval do
  include ActsAsXapian::ArrayExt
end
