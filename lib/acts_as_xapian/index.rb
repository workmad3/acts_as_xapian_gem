module ActsAsXapian
  class Index
    @@db_path = nil
    @@init_values = []

    cattr_reader :config, :db_path, :stemmer

    class <<self
      ######################################################################
      # Initialisation
      def init(classname = nil, options = nil)
        # store class and options for use later, when we open the db in readable_init
        @@init_values.push([classname,options]) unless classname.nil?
      end

      # Reads the config file (if any) and sets up the path to the database we'll be using
      def prepare_environment
        return unless @@db_path.nil?

        # barf if we can't figure out the environment
        environment = (ENV['RAILS_ENV'] || RAILS_ENV)
        raise "Set RAILS_ENV, so acts_as_xapian can find the right Xapian database" unless environment

        # check for a config file
        config_file = File.join(RAILS_ROOT, 'config', 'xapian.yml')
        @@config = File.exists?(config_file) ? YAML.load_file(config_file)[environment] : {}
        # figure out where the DBs should go
        if config['base_db_path']
          db_parent_path = File.join(RAILS_ROOT, config['base_db_path'])
        else
          db_parent_path = File.join(RAILS_ROOT, 'db', 'xapiandbs')
        end

        # make the directory for the xapian databases to go in
        Dir.mkdir(db_parent_path) unless File.exists?(db_parent_path)

        @@db_path = File.join(db_parent_path, environment)

        # make some things that don't depend on the db
        # XXX this gets made once for each acts_as_xapian. Oh well.
        @@stemmer = Xapian::Stem.new('english')
      end
    end
  end
end
