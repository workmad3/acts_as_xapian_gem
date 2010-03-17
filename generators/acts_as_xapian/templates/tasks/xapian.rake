
namespace :xapian do
  
    # Parameters - specify "flush=true" to save changes to the Xapian database
    # after each model that is updated. This is safer, but slower. Specify
    # "verbose=true" to print model name as it is run.
    desc 'Updates Xapian search index with changes to models since last call'
    task :update_index => :environment do
        ActsAsXapian::WriteableIndex.update_index(ENV['flush'] ? true : false, ENV['verbose'] ? true : false)
    end

    desc 'Pulls all the xapian models from either the params or the project itself'
    task :retrieve_models => :environment do 
      @models = (ENV['models'] || ENV['m']) && (ENV['models'] || ENV['m']).split(" ").map{|m| m.constantize} || ActiveRecord::Base.send(:subclasses).select{|klazz| klazz.respond_to?(:xapian?)}
      STDOUT.puts("Found Xapian Models: #{@models.map(&:name).join(', ')}")
    end
    # Parameters - specify 'models="PublicBody User"' to say which models
    # you index with Xapian.
    # This totally rebuilds the database, so you will want to restart any
    # web server afterwards to make sure it gets the changes, rather than
    # still pointing to the old deleted database. Specify "verbose=true" to
    # print model name as it is run.
    desc 'Completely rebuilds Xapian search index (must specify all models)'
    task :rebuild_index => :retrieve_models do
        ActsAsXapian::WriteableIndex.rebuild_index(@models, ENV['verbose'] ? true : false)
    end

    # Parameters - are models, query, offset, limit, sort_by_prefix,
    # collapse_by_prefix
    desc 'Run a query, return YAML of results'
    task :query => :retrieve_models do
        raise "specify query=\"your terms\" as parameter" if (ENV['query'] || ENV['q']).nil?
        s = ActsAsXapian::Search.new(@models, 
            (ENV['query'] || ENV['q']),
            :offset => (ENV['offset'] || 0), :limit => (ENV['limit'] || 10),
            :sort_by_prefix => (ENV['sort_by_prefix'] || nil), 
            :collapse_by_prefix => (ENV['collapse_by_prefix'] || nil)
        )
        STDOUT.puts(s.results.to_yaml)
    end
end

