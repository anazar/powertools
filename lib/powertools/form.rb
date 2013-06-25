class Powertools::Form
  include ActiveModel::Model
  include Hooks

  define_hooks :initialize, :before_submit, :before_forms_save, :before_save, :after_save

  attr_accessor :store

  def store
    self.class.store ||= {}
  end

  def initialize model = false, options = {}
    # This is so simple form knows how to set the correct name
    # for the submit button. i.e. create or edit
    @persisted = (model.respond_to?(:id) && model.id) ? :edit : false

    # Do things with the parent class
    if self.class.superclass.name != 'PowertoolsForm'
      # We need to merge the parent classes store
      parent_store  = self.class.superclass.store
      # Loop through the parent store and merge in the store
      parent_store.each do |key, data|
        if store.key?(key) && store[key][:type] == :model
          store[key][:fields].concat(data[:fields]).uniq!
        else
          store[key] = data
        end
      end
    end

    # Load data into models if any is sent
    store.each do |store_key, current_store|
      case current_store[:type]
      when :model
        if model && current_store[:class] == model.class.name
          add_method model
        else
          model = Object::const_get(current_store[:class]).new
          add_method model
        end
      when :form
        if model && model.respond_to?(store_key)
          form = Object::const_get(current_store[:class]).new model.send(store_key)
          add_method form, store_key
        end
      end
    end

    run_hook :initialize
  end

  def persisted?
    @persisted
  end

  def add_method method_object, method_name = false
    method_name = method_object.class.name.to_s.underscore unless method_name

    singleton_class.class_eval do; attr_accessor method_name; end
    send("#{method_name}=", method_object)
  end

  def submit params
    @params = params

    run_hook :before_submit
    # Set all the values
    set_params @params

    # Check if everything in the store is valid
    is_valid = true
    store.each do |store_name, store_data|
      is_valid &= send(store_name).valid?
    end

    # Check to see if the root form is valid
    is_valid &= valid?

    # Call save command
    if is_valid
      save!
    end
  end

  def save!
    model_name_sym = self.class.model_name.to_s.underscore.to_sym
    run_hook :before_forms_save
    # Save the forms
    store.each do |store_key, current_store|
      if store_key != model_name_sym && current_store[:type] == :form
        send(store_key).save!
      end
    end
    run_hook :before_save
    send(model_name_sym).save!
    run_hook :after_save
  end

  def set_params params, params_key = false
    # Set the current store if we have the params key
    current_store = store[params_key.to_sym] if params_key
    if  (!current_store and !params_key) or (current_store and current_store[:type] == :model)
      params.each do |key, value|
        key = key.to_sym unless key.kind_of? Symbol

        if value.kind_of? Hash
          set_params value, key
        else
          if current_store
            # Only save fields we have listed
            if current_store[:fields].include? key
              # Grab the model
              current_model = send(params_key)

              # Make sure we haven't override the save method before
              # setting the value on the model
              if not respond_to? "#{key}="
                current_model.send("#{key}=", params[key])
              # Use our own override method
              else
                send("#{key}=", params[key])
              end
            end
          else
            if respond_to? "#{key}="
              send("#{key}=", value)
            end
          end
        end
      end
    elsif current_store && current_store[:type] == :form
      # This is if we are adding _form methods
      # current_form = send(current_store[:form_name])
      current_form = send(params_key)
      current_form.set_params params, current_store[:model_name]
    else
      if respond_to? "#{params_key}="
        send("#{params_key}=", params)
      end
    end
  end

  class << self
    attr_accessor :store

    def store
      @store ||= {}
    end

    def delegate *fields
      options = fields.extract_options!
      # Handle the model passed
      if options.key? :to_model
        # Grab the model sym
        model_sym   = options.delete(:to_model)
        # Set the class name
        model_class = model_sym.to_s.classify
        # Set the model
        model = Object::const_get(model_class)
        # Add the option for the default rails delegate method
        options[:to] = model_sym
        # Call te default delegate method
        super(*fields, options)
        # initiate the defaults
        store[model_sym] ||= {
          type: :model,
          class: model_class,
          fields: []
        }
        # Add the fields
        store[model_sym][:fields].concat(fields).uniq!

        inherit_validation model_sym
        inherit_presence_validators model, fields
      elsif options.key? :to_form
        # Grab the form sym
        form_sym = options.delete(:to_form)
        # Model name
        form_model_name_sym = fields.first
        # Set form class name
        form_class = form_sym.to_s.classify
        # Set form object
        form = Object::const_get(form_class)
        # initiate the defaults
        store[form_model_name_sym] ||= {
          type: :form,
          class: form_class,
          form_name: form_sym,
          model_name: form.new.class.model_name.to_s.underscore.to_sym
        }
      else
        super(*fields, options)
      end
    end

    def inherit_validation model_sym
      validate do
        # Validate the model
        model = send(model_sym)
        if !model.valid?
          model.errors.messages.each do |field, model_errors|
            model_errors.each do |model_error|
              errors.add field, model_error
            end
          end
        end

        # Make sure all nested forms are valid and add the errors
        store.each do |store_key, current_store|
          if current_store[:type] == :form
            model = send(store_key)
            if !model.valid?
              model.errors.messages.each do |field, model_errors|
                model_errors.each do |model_error|
                  errors.add field, model_error
                end
              end
            end
          end
        end
      end
    end

    def inherit_presence_validators model, fields
      fields.each do |field|
        model._validators[field.to_sym].each do |validation|
          case validation.class.name
          when 'ActiveRecord::Validations::PresenceValidator'
            validates_presence_of field
          end
        end
      end
    end

    def form_name name
      @default_model_name = name
      # So simple form doesn't use the class name for the attribute name
      define_singleton_method 'model_name' do
        ActiveModel::Name.new(self, nil, name.to_s.classify)
      end

      # So simple form can tell if a model is associated
      define_singleton_method 'reflect_on_association' do |field|
        Object::const_get(name.to_s.classify).reflect_on_association field
      end

      # So simple form can automatically set the column type i.e. Boolean
      define_method 'column_for_attribute' do |field|
        send(name).column_for_attribute field
      end
    end
  end
end
