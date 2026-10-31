module Vetra
  module Graph
    module DSL
      class Base < BasicObject
        def self.const_missing(name)
          ::Object.const_get(name)
        end

        def initialize(registry, manifest, domain, source)
          @registry, @manifest, @domain, @source = registry, manifest, domain, source
        end

        def evaluate(block)
          instance_eval(&block) if block
          self
        end

        def evaluate_source(declaration_source, declaration_filename)
          instance_eval(declaration_source, declaration_filename, 1)
        end

        def method_missing(name, *_args, **_options, &_block)
          error("unsupported_declaration", "Declaração #{name} não implementada no protótipo; nenhum dado foi descartado.")
        end

        def error(code, message)
          ::Kernel.raise Error.single(code, message, source: @source)
        end

        def source(block)
          return @manifest.source(*block.source_location) if block
          filename = @manifest.root.join(@source['path']).to_s
          frame = ::Kernel.caller_locations.find { |entry| (entry.absolute_path || entry.path) == filename }
          frame ? @manifest.source(filename, frame.lineno) : @source
        end

        def qualify(name)
          value = name.to_s
          value.include?(".") ? value : "#{@domain}.#{value}"
        end

        def declaration(kind, name, attributes)
          error("domain_required", "Declare nós dentro de app/domains/<domínio>/.") unless @domain
          { "kind" => kind, "id" => qualify(name), "domain" => @domain, "source" => @source, **attributes }
        end

        def options!(options, allowed)
          unknown = options.keys - allowed
          error("unsupported_option", "Opções não implementadas: #{unknown.join(', ')}.") unless unknown.empty?
        end
      end

      class App < Base
        attr_reader :attributes

        def initialize(*args, name:)
          super(*args)
          @attributes = { "name" => name.to_s, "currency" => "BRL", "locale" => "pt-BR", "tenant" => nil, "source" => @source }
        end

        def currency(value, **options)
          options!(options, [])
          @attributes["currency"] = value.to_s
        end

        def locale(value)
          @attributes["locale"] = value.to_s
        end

        def tenant(value)
          @attributes["tenant"] = value.to_s
        end
      end

      class Domain < Base
        attr_reader :dependencies

        def initialize(*args)
          super
          @dependencies = nil
        end

        def depends_on(*names)
          @dependencies = names.map(&:to_s)
        end
      end

      class Fields < Base
        attr_reader :fields
        TYPES = %w[string text email boolean integer date timestamp json id decimal money].freeze

        def initialize(*args)
          super
          @fields = []
        end

        TYPES.each do |type|
          define_method(type) { |name, **options| field(name, type, **options) }
        end

        def enum(name, values, **options)
          field(name, "enum", **options.merge(values: values))
        end

        def slug(name, from:, **options)
          field(name, "string", **options.merge(generate: { "kind" => "slug", "from" => from.to_s }))
        end

        def field(name, type, **options)
          options!(options, %i[required optional nullable default personal classification set_by guarded values groups precision scale entity min max length unique normalize generate was])
          error("duplicate_field", "Campo repetido: #{name}.") if fields.any? { |entry| entry['name'] == name.to_s }
          optional = options.fetch(:optional, false)
          descriptor = { "name" => type.to_s }
          descriptor["entity"] = options[:entity].to_s if options.key?(:entity)
          descriptor["values"] = options.fetch(:values).map(&:to_s) if type.to_s == "enum"
          descriptor["groups"] = options[:groups].to_h { |key, values| [key.to_s, values.map(&:to_s)] } if options[:groups]
          if %w[money decimal].include?(type.to_s)
            descriptor["precision"] = options.fetch(:precision, 19)
            # Money's implicit scale depends on the application, resolved during normalization.
            descriptor["scale"] = options.fetch(:scale, 2) if type.to_s == "decimal" || options.key?(:scale)
          end
          personal = options.fetch(:personal, false)
          privacy = { "personal" => personal }
          privacy["classification"] = options.fetch(:classification, "personal").to_s if personal
          entry = {
            "name" => name.to_s, "type" => descriptor,
            "required" => options.fetch(:required, !optional && !options.key?(:default) && !options.key?(:generate)),
            "nullable" => options.fetch(:nullable, optional || (type.to_s == "timestamp" && options.key?(:set_by))),
            "privacy" => privacy
          }
          if options.key?(:default)
            value = options[:default]
            entry["default"] = if %i[current_actor current_tenant].include?(value)
              { "kind" => "context", "name" => value.to_s }
            else
              { "kind" => "literal", "value" => json_value(value) }
            end
          end
          entry["set_by"] = ::Kernel.Array(options[:set_by]).map(&:to_s) if options.key?(:set_by)
          entry["guarded"] = options[:guarded].map { |value, commands| { "value" => value.to_s, "commands" => ::Kernel.Array(commands).map(&:to_s) } } if options[:guarded]
          entry["previous_names"] = ::Kernel.Array(options[:was]).map(&:to_s) if options.key?(:was)
          entry["normalize"] = ::Kernel.Array(options[:normalize]).map(&:to_s) if options.key?(:normalize)
          entry["generate"] = options[:generate] if options.key?(:generate)
          constraints = {}
          constraints["min_length"] = options[:min] if options.key?(:min)
          constraints["max_length"] = options[:max] if options.key?(:max)
          if options[:length]
            range = options[:length]
            error("unsupported_option", "length exige Range de inteiros inclusivo.") unless range.is_a?(::Range) && !range.exclude_end?
            constraints.merge!("min_length" => range.begin, "max_length" => range.end)
          end
          constraints["unique"] = options[:unique] if options.key?(:unique)
          entry["constraints"] = constraints unless constraints.empty?
          @fields << entry
        end

        def json_value(value)
          case value
          when ::Hash then value.to_h { |key, child| [key.to_s, json_value(child)] }
          when ::Array then value.map { |child| json_value(child) }
          when ::Symbol then value.to_s
          else value
          end
        end
      end

      class Entity < Fields
        attr_reader :attributes

        def initialize(*args, options:)
          super(*args)
          options!(options, %i[table repository was])
          @attributes = { "fields" => fields, "relations" => [], "indexes" => [], "history" => "full", "transitions" => { "enforce" => "application" }, "options" => options }
        end

        def tenant(value)
          @attributes["tenant"] = value == false ? false : value.to_s
        end

        def belongs_to(name, entity: name, optional: false, same_tenant: false, **options)
          options!(options, %i[default])
          field("#{name}_id", "id", entity: entity, optional: optional, **options)
          @attributes["relations"] << { "name" => name.to_s, "target" => entity.to_s, "kind" => "belongs_to", "same_tenant" => same_tenant }
        end

        def has_many(name, entity:, by:)
          @attributes["relations"] << { "name" => name.to_s, "target" => entity.to_s, "kind" => "has_many", "by" => by.to_s, "same_tenant" => false }
        end

        # `entity:` e `through:` são opcionais: sem `entity:`, o alvo é a entidade do mesmo domínio com o nome da
        # relação no singular; sem `through:`, o normalizador gera a entidade de junção (ver Normalizer).
        def many_to_many(name, entity: nil, through: nil, include: nil)
          @attributes["relations"] << {
            "name" => name.to_s, "target" => entity&.to_s, "kind" => "many_to_many", "through" => through&.to_s,
            "include" => ::Kernel.Array(include).map(&:to_s), "same_tenant" => false
          }
        end

        def memberships(of:, actor:, role:)
          error("duplicate_memberships", "Declare memberships uma única vez por entidade.") if @attributes.key?("memberships")
          @attributes["memberships"] = { "of" => of.to_s, "actor" => actor.to_s, "role" => role.to_s }
        end

        def index(*names, unique: false)
          @attributes["indexes"] << { "fields" => names.map(&:to_s), "unique" => unique }
        end

        def crud(scope: nil)
          @attributes["crud"] = { "scope" => scope&.to_s }
        end

        def history(value)
          @attributes["history"] = value.to_s
        end

        def transitions(enforce:)
          @attributes["transitions"] = { "enforce" => enforce.to_s }
        end
      end

      class Operation < Fields
        attr_reader :attributes, :implementation

        def initialize(*args)
          super
          @attributes = { "fields" => fields, "uses" => [], "emits" => [], "exposures" => [], "on" => [], "calls" => [] }
        end

        def input(name, type, **options)
          field(name, type.to_s, **options)
        end

        def returns(entity)
          @attributes["returns"] = entity.to_s
        end

        def authorize(action, entity, record: nil)
          @attributes["authorize"] = { "action" => action.to_s, "entity" => entity.to_s }
          @attributes["authorize"]["record"] = record.to_s if record
        end

        def uses(*names)
          @attributes["uses"].concat(names.map(&:to_s))
        end

        def emits(event, with:, from: nil)
          @attributes["emits"] << { "event" => event.to_s, "fields" => with.map(&:to_s), "from" => from&.to_s }
        end

        def expose(http:, idempotency: :optional)
          @attributes["exposures"] << { "http" => http, "idempotency" => idempotency.to_s }
        end

        def call(&block)
          error("duplicate_implementation", "Declare apenas um bloco call.") if @implementation
          @implementation = block
        end

        def unsafe_effect(reason)
          error("unsafe_reason", "unsafe_effect exige motivo não vazio.") if reason.to_s.strip.empty?
          @attributes["unsafe_effect"] = reason.to_s
        end

        def on(*events)
          @attributes["on"].concat(events.map(&:to_s))
        end

        def calls(*commands)
          @attributes["calls"].concat(commands.map(&:to_s))
        end

        def idempotent_by(value)
          @attributes["idempotent_by"] = value.to_s
        end
      end

      class Role < Base
        attr_reader :permissions

        def initialize(*args, scope: nil)
          super(*args)
          @scope = scope
          @permissions = []
        end

        def can(*actions, on:, where: {}, fields: "*", scope: @scope, **options)
          options!(options, [])
          ::Kernel.Array(on).each do |entity|
            @permissions << { "entity" => entity.to_s, "actions" => actions.map(&:to_s), "where" => where, "fields" => fields == "*" ? "*" : fields.map(&:to_s), "scope" => scope&.to_s }
          end
        end
      end

      class Roles < Base
        def initialize(*args, scope: nil)
          super(*args)
          @scope = scope
        end

        def role(name, anonymous: false, &block)
          origin = source(block)
          builder = Role.new(@registry, @manifest, @domain, origin, scope: @scope).evaluate(block)
          @registry.add(declaration("role", name, "source" => origin, "anonymous" => anonymous, "permissions" => builder.permissions))
        end

        def visitor(&block)
          role(:visitor, anonymous: true, &block)
        end

        def authenticated(&block)
          role(:authenticated, &block)
        end
      end

      class Effect < Base
        attr_reader :attributes

        def initialize(*args)
          super
          @attributes = { "adapter" => "app.effect", "retry_safe" => false, "simulation" => "none", "config" => { "type" => "external", "idempotency_key" => false, "hosts" => [], "timeout_ms" => 5000 } }
        end

        def adapter(value)
          @attributes["adapter"] = value.to_s
        end

        def retry_safe(value)
          @attributes["retry_safe"] = value
        end

        def simulate(value)
          @attributes["simulation"] = value.to_s
        end

        def idempotency_key(value)
          @attributes["config"]["idempotency_key"] = value
        end

        def hosts(*values)
          @attributes["config"]["hosts"] = values
        end

        def timeout(seconds)
          @attributes["config"]["timeout_ms"] = seconds * 1000
        end
      end

      class Context < Base
        def app(name, &block)
          builder = App.new(@registry, @manifest, nil, source(block), name: name).evaluate(block)
          @registry.app(builder.attributes)
        end

        def domain(name, &block)
          error("domain_mismatch", "Domínio deve coincidir com o diretório #{@domain}.") unless name.to_s == @domain
          builder = Domain.new(@registry, @manifest, @domain, source(block)).evaluate(block)
          @registry.add({ "kind" => "domain", "id" => @domain, "source" => source(block), "depends_on" => builder.dependencies })
        end

        def entity(name, **options, &block)
          builder = Entity.new(@registry, @manifest, @domain, source(block), options: options).evaluate(block)
          @registry.add(declaration("entity", name, builder.attributes.merge("source" => source(block))))
        end

        %w[command query handler].each do |kind|
          define_method(kind) do |name, &block|
            builder = Operation.new(@registry, @manifest, @domain, source(block)).evaluate(block)
            error("missing_implementation", "Declare call em #{name}.") unless builder.implementation
            @registry.add(declaration(kind, name, builder.attributes.merge("source" => source(block))), block: builder.implementation)
          end
        end

        def roles(scope: nil, &block)
          Roles.new(@registry, @manifest, @domain, source(block), scope: scope).evaluate(block)
        end

        def effect(name, &block)
          builder = Effect.new(@registry, @manifest, @domain, source(block)).evaluate(block)
          @registry.add(declaration("capability", name, builder.attributes.merge("source" => source(block))))
        end

        def event(name, from:, fields:, visibility: :internal, consumer_required: false, version: 1)
          @registry.add(declaration("event", name, "source" => source(nil), "from" => from.to_s, "fields" => fields.map(&:to_s), "visibility" => visibility.to_s, "consumer_required" => consumer_required, "version" => version))
        end
      end
    end
  end
end
