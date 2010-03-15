# acts_as_xapian/lib/acts_as_xapian.rb:
# Xapian full text search in Ruby on Rails.
#
# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#
# Documentation
# =============
#
# See ../README.txt foocumentation. Please update that file if you edit
# code.

# Make it so if Xapian isn't installed, the Rails app doesn't fail completely,
# just when somebody does a search.
begin
  require 'xapian'
  $acts_as_xapian_bindings_available = true
rescue LoadError
  STDERR.puts "acts_as_xapian: No Ruby bindings for Xapian installed"
  $acts_as_xapian_bindings_available = false
end

module ActsAsXapian
  class NoXapianRubyBindingsError < StandardError; end

  # Offline indexing job queue model, create with migration made
  # using "script/generate acts_as_xapian" as described in ../README.txt
  class ActsAsXapianJob < ActiveRecord::Base; end

  ######################################################################
  # Module level variables
  # XXX must be some kind of cattr_accessor that can do this better
  def self.bindings_available
    $acts_as_xapian_bindings_available
  end

  ######################################################################
  # Main entry point, add acts_as_xapian to your model.

  module ActsMethods
    # See top of this file for docs
    def acts_as_xapian(options)
      # Give error only on queries if bindings not available
      return unless ActsAsXapian.bindings_available

      include InstanceMethods
      extend ClassMethods

      class_eval('def xapian_boost(term_type, term); 1; end') unless self.instance_methods.include?('xapian_boost')

      # extend has_many && has_many_and_belongs_to associations with our ProxyFinder to get scoped results
      # I've written a small report in the discussion group why this is the proper way of doing this.
      # see here: XXX - write it you lazy douche bag!
      self.reflections.each do |association_name, r|
        # skip if the associated model isn't indexed by acts_as_xapian
        next unless r.klass.respond_to?(:xapian?) && r.klass.xapian?
        # skip all associations except ham and habtm
        next unless [:has_many, :has_many_and_belongs_to_many].include?(r.macro)

        # XXX todo:
        # extend the associated model xapian options with this term:
        # [proxy_reflection.primary_key_name.to_sym, <magically find a free capital letter>, proxy_reflection.primary_key_name]
        # otherways this assumes that the associated & indexed model indexes this kind of term

        # but before you do the above, rewrite the options syntax... wich imho is actually very ugly

        # XXX test this nifty feature on habtm!

        if r.options[:extend].nil?
          r.options[:extend] = [ProxyFinder]
        elsif !r.options[:extend].include?(ProxyFinder)
          r.options[:extend] << ProxyFinder
        end
      end

      cattr_accessor :xapian_options
      self.xapian_options = options

      ActsAsXapian::Index.init(self.class.to_s, options)

      after_save :xapian_mark_needs_index
      after_destroy :xapian_mark_needs_destroy
    end
  end

  module ClassMethods
    # Model.find_with_xapian("Search Term OR Phrase")
    # => Array of Records
    #
    # this can be used through association proxies /!\ DANGEROUS MAGIC /!\
    # example:
    # @document = Document.find(params[:id])
    # @document_pages = @document.pages.find_with_xapian("Search Term OR Phrase").compact # NOTE THE compact wich removes nil objects from the array
    #
    # as seen here: http://pastie.org/270114
    def find_with_xapian(search_term, options = {})
      search_with_xapian(search_term, options).results.map {|x| x[:model] }
    end

    def search_with_xapian(search_term, options = {})
      ActsAsXapian::Search.new([self], search_term, options)
    end

    def with_xapian_scope(ids)
      with_scope(:find => {:conditions => {"#{self.table_name}.#{self.primary_key}" => ids}, :include => self.xapian_options[:eager_load]}) { yield }
    end

    #this method should return true if the integration of xapian on self is complete
    def xapian?
      self.included_modules.include?(InstanceMethods) && self.extended_by.include?(ClassMethods)
    end
  end

  ######################################################################
  # Instance methods that get injected into your model.

  module InstanceMethods
    # Used internally
    def xapian_document_term
      "#{self.class}-#{self.id}"
    end

    # Extract value of a field from the model
    def xapian_value(field, type = nil)
      value = self.respond_to?(field) ? self.send(field) : self[field] # Give preference to method if it exists
      case type
      when :date
        value = value.to_time if value.kind_of?(Date)
        raise "Only Time or Date types supported by acts_as_xapian for :date fields, got #{value.class}" unless value.kind_of?(Time)
        value.utc.strftime("%Y%m%d")
      when :boolean
        value ? true : false
      when :number
        value.nil? ? "" : Xapian::sortable_serialise(value.to_f)
      else
        value.to_s
      end
    end

    # Store record in the Xapian database
    def xapian_index
      # if we have a conditional function for indexing, call it and destory object if failed
      if self.class.xapian_options.key?(:if) && !xapian_value(self.class.xapian_options[:if], :boolean)
        self.xapian_destroy
        return
      end

      # otherwise (re)write the Xapian record for the object
      doc = Xapian::Document.new
      WriteableIndex.term_generator.document = doc

      doc.data = self.xapian_document_term

      doc.add_term("M#{self.class}")
      doc.add_term("I#{doc.data}")
      (self.xapian_options[:terms] || []).each do |term|
        WriteableIndex.term_generator.increase_termpos # stop phrases spanning different text fields
        WriteableIndex.term_generator.index_text(xapian_value(term[0]), self.xapian_boost(:term, term[0]), term[1])
      end
      (self.xapian_options[:values] || []).each {|value| doc.add_value(value[1], xapian_value(value[0], value[3])) }
      (self.xapian_options[:texts] || []).each do |text|
        WriteableIndex.term_generator.increase_termpos # stop phrases spanning different text fields
        WriteableIndex.term_generator.index_text(xapian_value(text), self.xapian_boost(:text, text))
      end

      WriteableIndex.replace_document("I#{doc.data}", doc)
    end

    # Delete record from the Xapian database
    def xapian_destroy
      WriteableIndex.delete_document("I#{self.xapian_document_term}")
    end

    # Used to mark changes needed by batch indexer
    def xapian_mark_needs_index
      model = self.class.base_class.to_s
      model_id = self.id
      return false unless model_id # After save gets called even if save fails
      ActiveRecord::Base.transaction do
        found = ActsAsXapianJob.delete_all(["model = ? and model_id = ?", model, model_id])
        job = ActsAsXapianJob.new
        job.model = model
        job.model_id = model_id
        job.action = 'update'
        job.save!
      end
    end

    def xapian_mark_needs_destroy
      model = self.class.base_class.to_s
      model_id = self.id
      ActiveRecord::Base.transaction do
        found = ActsAsXapianJob.delete_all(["model = ? and model_id = ?", model, model_id])
        job = ActsAsXapianJob.new
        job.model = model
        job.model_id = model_id
        job.action = 'destroy'
        job.save!
      end
    end
  end

  module ProxyFinder
    def find_with_xapian(search_term, options = {})
      search_with_xapian(search_term, options).results.map {|x| x[:model] }
    end

    def search_with_xapian(search_term, options = {})
      ActsAsXapian::Search.new([proxy_reflection.klass], "#{proxy_reflection.primary_key_name}:#{proxy_owner.id} #{search_term}", options)
    end
  end
end

# Reopen ActiveRecord and include the acts_as_xapian method
ActiveRecord::Base.extend ActsAsXapian::ActsMethods
