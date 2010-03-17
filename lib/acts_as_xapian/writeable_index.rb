module ActsAsXapian
  class WriteableIndex < Index
    @@writable_db = nil
    @@writable_suffix = nil

    cattr_reader :term_generator

    class << self
      def delete_document(*args)
        @@writable_db.delete_document(*args)
      end

      def replace_document(*args)
        @@writable_db.replace_document(*args)
      end

      def writable_init(suffix = "")
        raise NoXapianRubyBindingsError.new("Xapian Ruby bindings not installed") unless ActsAsXapian.bindings_available
        raise "acts_as_xapian hasn't been called in any models" if @@init_values.empty?

        # if DB is not nil, then we're already initialised, so don't do it again
        return unless @@writable_db.nil?

        prepare_environment

        new_path = @@db_path + suffix
        raise "writable_suffix/suffix inconsistency" if @@writable_suffix && @@writable_suffix != suffix

        # for indexing
        @@writable_db = Xapian::WritableDatabase.new(new_path, Xapian::DB_CREATE_OR_OPEN)
        @@term_generator = Xapian::TermGenerator.new()
        @@term_generator.set_flags(Xapian::TermGenerator::FLAG_SPELLING, 0)
        @@term_generator.database = @@writable_db
        @@term_generator.stemmer = @@stemmer
        @@writable_suffix = suffix
      end

      ######################################################################
      # Index

      # Update index with any changes needed, call this offline. Only call it
      # from a script that exits - otherwise Xapian's writable database won't
      # flush your changes. Specifying flush will reduce performance, but
      # make sure that each index update is definitely saved to disk before
      # logging in the database that it has been.
      def update_index(flush = false, verbose = false)
        # puts "start of self.update_index" if verbose

        # Before calling writable_init we have to make sure every model class has been initialized.
        # i.e. has had its class code loaded, so acts_as_xapian has been called inside it, and
        # we have the info from acts_as_xapian.
        model_classes = ActsAsXapianJob.find(:all, :select => 'model', :group => 'model').map {|a| a.model.constantize }
        # If there are no models in the queue, then nothing to do
        return if model_classes.empty?

        self.writable_init

        ids_to_refresh = ActsAsXapianJob.find(:all, :select => 'id').map { |i| i.id }
        ids_to_refresh.each do |id|
          begin
            ActsAsXapianJob.transaction do
              job = ActsAsXapianJob.find(id, :lock =>true)
              puts "ActsAsXapian::WriteableIndex.update_index #{job.action} #{job.model} #{job.model_id.to_s}" if verbose
              begin
                case job.action
                when 'update'
                  # XXX Index functions may reference other models, so we could eager load here too?
                  model = job.model.constantize.find(job.model_id) # :include => cls.constantize.xapian_options[:include]
                  model.xapian_index
                when 'destroy'
                  # Make dummy model with right id, just for destruction
                  model = job.model.constantize.new
                  model.id = job.model_id
                  model.xapian_destroy
                else
                  raise "unknown ActsAsXapianJob action '#{job.action}'"
                end
              rescue ActiveRecord::RecordNotFound => e
                job.action = 'destroy'
                retry
              end
              job.destroy

              @@writable_db.flush if flush
            end
          rescue => detail
            # print any error, and carry on so other things are indexed
            # XXX If item is later deleted, this should give up, and it
            # won't. It will keep trying (assuming update_index called from
            # regular cron job) and mayhap cause trouble.
            STDERR.puts("#{detail.backtrace.join("\n")}\nFAILED ActsAsXapian::WriteableIndex.update_index job #{id} #{$!}")
          end
        end
      end

      # You must specify *all* the models here, this totally rebuilds the Xapian database.
      # You'll want any readers to reopen the database after this.
      def rebuild_index(model_classes, verbose = false)
        raise "when rebuilding all, please call as first and only thing done in process / task" unless @@writable_db.nil?

        prepare_environment

        # Delete any existing .new database, and open a new one
        new_path = "#{self.db_path}.new"
        if File.exist?(new_path)
          raise "found existing #{new_path} which is not Xapian flint database, please delete for me" unless File.exist?(File.join(new_path, "iamflint"))
          FileUtils.rm_r(new_path)
        end
        self.writable_init(".new")

        # Index everything

        most_recent_job = ActsAsXapianJob.find(:first, :order => 'id DESC')
        batch_size = 1000
        model_classes.each do |model_class|
          all_ids = model_class.find(:all, :select => model_class.primary_key, :order => model_class.primary_key).map {|i| i.id }
          all_ids.each_slice(batch_size) do |ids|
            puts "ActsAsXapian::WriteableIndex: New batch. Including ids #{ids.first} to #{ids.last}" if verbose
            models = model_class.find(:all, :conditions => {model_class.primary_key => ids})
            models.each do |model|
              puts "ActsAsXapian::WriteableIndex.rebuild_index #{model_class} #{model.id}" if verbose
              model.xapian_index
            end
          end
        end

        @@writable_db.flush

        # Rename into place
        old_path = self.db_path
        temp_path = "#{old_path}.tmp"
        if File.exist?(temp_path)
          raise "temporary database found #{temp_path} which is not Xapian flint database, please delete for me" unless File.exist?(File.join(temp_path, "iamflint"))
          FileUtils.rm_r(temp_path)
        end
        FileUtils.mv(old_path, temp_path) if File.exist?(old_path)
        FileUtils.mv(new_path, old_path)

        # Delete old database
        if File.exist?(temp_path)
          raise "old database now at #{temp_path} is not Xapian flint database, please delete for me" unless File.exist?(File.join(temp_path, "iamflint"))
          FileUtils.rm_r(temp_path)
        end

        ActsAsXapianJob.delete_all ['id <= ?', most_recent_job.id] if most_recent_job

        # You'll want to restart your FastCGI or Mongrel processes after this,
        # so they get the new db
      end
    end
  end
end
