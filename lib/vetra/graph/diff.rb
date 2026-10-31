module Vetra
  module Graph
    class Diff
      NODE_METADATA = %w[source annotations generated_from previous_ids].freeze
      REVIEW_CATEGORIES = %w[permissions isolation privacy transitions capabilities storage implementation events dependencies surface].freeze
      CONTRACT_KINDS = %w[entity contract command query event route].freeze
      TEXT_SETS = %w[actions previous_ids previous_names requires constants dynamic hosts].freeze
      LABELS = { 'breaking' => 'QUEBRA POTENCIAL', 'review' => 'REVISÃO', 'additive' => 'ADIÇÃO', 'metadata' => 'METADADOS' }.freeze
      CATEGORY_LABELS = {
        'privacy' => 'PRIVACIDADE', 'transitions' => 'TRANSIÇÕES', 'isolation' => 'ISOLAMENTO',
        'capabilities' => 'CAPACIDADES', 'surface' => 'SUPERFÍCIE'
      }.freeze

      class Report
        attr_reader :data

        def initialize(data)
          @data = Data.freeze(data)
          freeze
        end

        def breaking?
          data.dig('summary', 'breaking').positive?
        end

        def changed?
          data.dig('summary', 'total').positive?
        end

        def to_h
          data
        end

        def to_json
          "#{Canonical.dump(data)}\n"
        end

        def to_text
          counts = data.fetch('summary')
          lines = ["graph:diff: #{data.dig('before', 'app')} → #{data.dig('after', 'app')}"]
          if counts['total'].zero?
            lines << 'Sem alterações no modelo ou nos metadados comparados.'
          else
            architectural = counts['total'] - counts['metadata']
            lines << "#{architectural} alterações arquiteturais; #{counts['breaking']} quebras potenciais; #{counts['requires_review']} exigem revisão; #{counts['metadata']} metadados."
            %w[architecture metadata].each do |group|
              changes = data['changes'].select { |change| (change['impact'] == 'metadata') == (group == 'metadata') }
              next if changes.empty?
              lines << '' << (group == 'metadata' ? 'Metadados de origem/build:' : 'Mudanças no modelo:')
              changes.each do |change|
                labels = [LABELS.fetch(change['impact'])]
                labels.concat(change['categories'].filter_map { |category| CATEGORY_LABELS[category] })
                labels << 'REVISÃO NECESSÁRIA' if change['impact'] == 'additive' && change['requires_review']
                labels << 'IMPACTO DE PERMISSÃO INDETERMINADO' if change['permission_impact']
                lines << "[#{labels.join(' | ')}] #{change['kind']} #{change['id']} #{change['path']}: #{change['description']}"
                # Full snapshots remain available in JSON. Security changes always
                # show both sides; ordinary node additions need only the summary.
                security = change['permission_impact'] || (change['categories'] & CATEGORY_LABELS.keys).any?
                if change['impact'] != 'metadata' && (security || change['change'] == 'modified')
                  lines << "  antes: #{change['before_present'] ? Canonical.dump(change['before']) : '(ausente)'}"
                  lines << "  depois: #{change['after_present'] ? Canonical.dump(change['after']) : '(ausente)'}"
                end
              end
            end
          end
          if data['changes'].any? { |change| change['impact'] == 'metadata' && (change['path'].start_with?('/inputs/', '/implementation/') || change['path'] == '/producer') }
            lines << '' << 'Fontes/build mudaram; a comparação não avalia equivalência do código Ruby.'
          end
          "#{lines.join("\n")}\n"
        end
      end

      def compare(before, after)
        warnings = validate(before, 'before') + validate(after, 'after')
        @changes = []
        @before, @after = normalize(before), normalize(after)
        @before_usage, @after_usage = contract_usage(@before), contract_usage(@after)
        old_nodes = @before['nodes'].to_h { |node| [node.values_at('kind', 'id'), node] }
        new_nodes = @after['nodes'].to_h { |node| [node.values_at('kind', 'id'), node] }
        pairs, removed, added = match(old_nodes, new_nodes, 'previous_ids', node_ids: true)
        @renames = pairs.to_h { |old_node, new_node| [old_node.values_at('kind', 'id'), new_node['id']] }

        compare_application
        pairs.each { |old_node, new_node| compare_node(old_node, new_node) }
        removed.each { |node| node_change(node, 'removed') }
        added.each { |node| node_change(node, 'added') }
        @changes.sort_by! { |change| [change['impact'] == 'metadata' ? 1 : 0, change['kind'], change['id'], change['path'], change['change']] }
        counts = %w[breaking review additive metadata].to_h { |impact| [impact, @changes.count { |change| change['impact'] == impact }] }
        counts.merge!('total' => @changes.size, 'requires_review' => @changes.count { |change| change['requires_review'] })
        Report.new(
          'format_version' => '1',
          'before' => header(@before), 'after' => header(@after),
          'summary' => counts, 'changes' => @changes, 'warnings' => warnings
        )
      end

      private

      def validate(document, side)
        Validator.new.validate!(document).map do |warning|
          { 'side' => side, 'code' => warning.code, 'message' => warning.message, 'pointer' => warning.pointer, 'source' => Data.copy(warning.source) }
        end
      rescue Error => error
        label = side == 'before' ? 'Grafo anterior' : 'Grafo posterior'
        raise Error.new(error.diagnostics.map do |diagnostic|
          Diagnostic.new(**diagnostic.to_h.merge(message: "#{label}: #{diagnostic.message}"))
        end)
      end

      def header(document)
        { 'app' => document.dig('app', 'name'), 'ir_version' => document['ir_version'], 'digest' => document['digest'] }
      end

      def normalize(value, property = nil, parent = nil)
        case value
        when Hash
          return Data.copy(value) if property == 'annotations' || value['kind'] == 'literal'
          value.to_h { |key, child| [key.dup, normalize(child, key, value)] }
        when Array
          children = value.map { |child| normalize(child) }
          if children.all? { |child| child.is_a?(Hash) && child.keys.sort == %w[id kind] }
            children.sort_by { |child| child.values_at('kind', 'id') }
          elsif %w[fields relations indexes].include?(property) && children.all? { |child| child.is_a?(Hash) && child.key?('name') }
            children.sort_by { |child| child['name'] }
          elsif property == 'fields' && !parent&.key?('unique') && children.all? { |child| child.is_a?(String) }
            children.sort
          elsif TEXT_SETS.include?(property)
            children.sort
          elsif property == 'emits'
            children.sort_by { |child| Canonical.dump(child) }
          elsif property == 'guarded'
            children.sort_by { |child| child['value'] }
          else
            children
          end
        else Data.copy(value)
        end
      end

      def rewrite_references(value)
        case value
        when Hash
          return Data.copy(value) if value['kind'] == 'literal'
          if value.keys.sort == %w[id kind]
            Data.reference(value['kind'], @renames.fetch(value.values_at('kind', 'id'), value['id']))
          else
            value.to_h { |key, child| [key, key == 'annotations' ? Data.copy(child) : rewrite_references(child)] }
          end
        when Array then value.map { |child| rewrite_references(child) }
        else Data.copy(value)
        end
      end

      def match(old_items, new_items, aliases, node_ids: false, owner: nil)
        remaining = old_items.dup
        pairs, added = [], []
        new_items.keys.sort.each do |key|
          current = new_items.fetch(key)
          if remaining.key?(key)
            pairs << [remaining.delete(key), current]
            next
          end
          candidates = current.fetch(aliases, []).filter_map do |previous|
            previous_key = node_ids ? [current['kind'], previous] : previous
            previous_key if remaining.key?(previous_key)
          end
          if candidates.size > 1
            raise Error.single('diff_rename_ambiguous', 'Renomeação corresponde a mais de uma identidade anterior; uma fusão não é um rename.', source: (owner || current)['source'])
          elsif candidates.size == 1
            pairs << [remaining.delete(candidates.first), current]
          else
            added << current
          end
        end
        [pairs, remaining.values, added]
      end

      def contract_usage(document)
        uses = Hash.new { |hash, key| hash[key] = [] }
        document['nodes'].each do |node|
          uses[node.dig('input', 'id')] << 'input' if node['input']
          uses[node.dig('output', 'id')] << 'output' if node['output']
          uses[node.dig('payload', 'id')] << 'event' if node['kind'] == 'event'
        end
        uses
      end

      def compare_application
        owner = { 'kind' => 'application', 'id' => @after.dig('app', 'name') }
        old_app = rewrite_references(@before['app'])
        compare_properties(old_app, @after['app'], owner, '/app')
        property(@before, @after, 'requires', owner, '/requires', ['dependencies'], 'review')
        %w[producer annotations].each { |key| property(@before, @after, key, owner, "/#{key}", ['build'], 'metadata') }
        old_inputs = @before['inputs'].to_h { |input| [input['path'], input] }
        new_inputs = @after['inputs'].to_h { |input| [input['path'], input] }
        (old_inputs.keys | new_inputs.keys).sort.each do |path|
          property(old_inputs, new_inputs, path, owner, "/inputs/#{escape(path)}", ['build'], 'metadata')
        end
      end

      def compare_node(before, after)
        owner = after.slice('kind', 'id', 'source')
        if before['id'] != after['id']
          emit(owner, '/id', 'renamed', before['id'], after['id'], node_categories(after) + ['identity'], CONTRACT_KINDS.include?(after['kind']) ? 'breaking' : 'review', 'Identidade renomeada explicitamente')
        end
        old = normalize(rewrite_references(before))
        # This string is a binding identity rather than a typed graph reference.
        if before['id'] != after['id'] && old.dig('implementation', 'kind') == 'ruby'
          old['implementation']['ref'] = "#{after['id']}#call"
        end
        NODE_METADATA.each { |key| property(old, after, key, owner, "/#{key}", ['origin'], 'metadata') }
        %w[path digest].each do |key|
          property(old.fetch('implementation', {}), after.fetch('implementation', {}), key, owner, "/implementation/#{key}", ['build'], 'metadata')
        end
        old_content = node_content(old)
        new_content = node_content(after)
        contexts = if after['kind'] == 'contract'
          (@before_usage[before['id']] + @after_usage[after['id']]).uniq
        else
          ['entity']
        end
        contexts = ['unknown'] if contexts.empty?
        compare_properties(old_content, new_content, owner, '', contexts)
      end

      def node_content(node)
        node.reject { |key, _| (NODE_METADATA + %w[kind id]).include?(key) }.to_h do |key, value|
          if key == 'implementation'
            [key, value.reject { |property, _| %w[path digest].include?(property) }]
          else
            [key, value]
          end
        end
      end

      def compare_properties(before, after, owner, prefix, contexts = [])
        (before.keys | after.keys).sort.each do |key|
          next if before.key?(key) == after.key?(key) && before[key] == after[key]
          path = "#{prefix}/#{escape(key)}"
          if key == 'fields' && %w[entity contract].include?(owner['kind']) && prefix.empty?
            compare_fields(before.fetch(key, []), after.fetch(key, []), owner, contexts)
          elsif %w[relations indexes].include?(key) && owner['kind'] == 'entity' && prefix.empty?
            compare_named(before.fetch(key, []), after.fetch(key, []), owner, path)
          else
            categories = categories(owner, key, prefix)
            impact = impact(owner, key, before[key], after[key], contexts, prefix)
            property(before, after, key, owner, path, categories, impact)
          end
        end
      end

      def compare_fields(before, after, owner, contexts)
        old_items = before.to_h { |field| [field['name'], field] }
        new_items = after.to_h { |field| [field['name'], field] }
        pairs, removed, added = match(old_items, new_items, 'previous_names', owner: owner)
        removed.each do |field|
          emit(owner, "/fields/#{escape(field['name'])}", 'removed', field, nil, field_categories(owner, field), 'breaking', 'Campo removido', after_present: false)
        end
        added.each do |field|
          breaking = contexts.any? { |context| %w[input event].include?(context) && field['required'] }
          breaking ||= contexts.include?('entity') && !field['nullable'] && !field.key?('default') && !field.key?('generate')
          impact = breaking ? 'breaking' : (contexts.include?('unknown') ? 'review' : 'additive')
          emit(owner, "/fields/#{escape(field['name'])}", 'added', nil, field, field_categories(owner, field), impact, 'Campo adicionado', before_present: false)
        end
        pairs.each do |old, current|
          path = "/fields/#{escape(current['name'])}"
          if old['name'] != current['name']
            emit(owner, "#{path}/name", 'renamed', old['name'], current['name'], field_categories(owner, current) + ['identity'], 'breaking', 'Campo renomeado explicitamente')
          end
          property(old, current, 'previous_names', owner, "#{path}/previous_names", ['origin'], 'metadata')
          compare_properties(old.reject { |key, _| %w[name previous_names].include?(key) }, current.reject { |key, _| %w[name previous_names].include?(key) }, owner, path, contexts)
        end
      end

      def compare_named(before, after, owner, prefix)
        old = before.to_h { |item| [item['name'], item] }
        current = after.to_h { |item| [item['name'], item] }
        (old.keys | current.keys).sort.each do |name|
          property(old, current, name, owner, "#{prefix}/#{escape(name)}", ['storage'], 'review')
        end
      end

      def field_categories(owner, field)
        result = ['contract']
        result << 'storage' if owner['kind'] == 'entity'
        result << 'privacy' if field.dig('privacy', 'personal')
        result << 'transitions' if field['set_by'] || field['guarded']
        result
      end

      def node_categories(node)
        result = case node['kind']
        when 'role', 'policy' then ['permissions']
        when 'entity' then %w[model storage]
        when 'contract' then ['contract']
        when 'command', 'query' then %w[contract permissions capabilities]
        when 'capability' then ['capabilities']
        when 'event' then %w[events contract]
        when 'handler' then node.fetch('calls', []).empty? ? %w[events capabilities] : %w[events capabilities permissions]
        when 'route' then %w[surface contract permissions]
        when 'application' then ['configuration']
        else ['dependencies']
        end
        result << 'isolation' if node['tenant']
        if %w[entity contract].include?(node['kind'])
          result += node.fetch('fields', []).flat_map { |field| field_categories(node, field) } - ['contract', 'storage']
        end
        result.uniq.sort
      end

      def categories(owner, key, prefix)
        return ['privacy'] if key == 'privacy' || key == 'history'
        return ['transitions'] if %w[guarded set_by transitions].include?(key)
        return %w[isolation permissions] if key == 'tenant'
        return ['permissions'] if key == 'authorize'
        return ['permissions'] if key == 'calls' && owner['kind'] == 'handler'
        return ['capabilities'] if key == 'uses'
        return ['dependencies'] if key == 'domain' || key == 'depends_on'
        return ['implementation'] if %w[implementation unsafe_effect].include?(key)
        return owner['kind'] == 'entity' ? %w[contract storage] : ['contract'] if prefix.start_with?('/fields/')
        node_categories(owner)
      end

      def impact(owner, key, before, after, contexts, prefix)
        return 'review' if %w[privacy guarded set_by transitions history tenant authorize calls uses domain depends_on implementation unsafe_effect].include?(key)
        return 'breaking' if owner['kind'] == 'route'
        return 'breaking' if %w[input output payload storage].include?(key)
        if prefix.start_with?('/fields/')
          return type_impact(before, after, contexts) if key == 'type'
          if key == 'required'
            return 'breaking' if contexts.include?('event') || (contexts.include?('input') && after) || (contexts.include?('output') && !after) || (contexts.include?('entity') && after)
            return contexts.include?('unknown') ? 'review' : 'additive'
          end
          if key == 'nullable'
            return 'breaking' if contexts.include?('event') || contexts.include?('entity') || (contexts.include?('input') && !after) || (contexts.include?('output') && after)
            return contexts.include?('unknown') ? 'review' : 'additive'
          end
          if key == 'constraints'
            return constraints_impact(before || {}, after || {}, contexts)
          end
          return 'review'
        end
        'review'
      end

      def type_impact(before, after, contexts)
        return 'breaking' unless before && after && before['name'] == 'enum' && after['name'] == 'enum'
        return 'breaking' unless before.reject { |key, _| %w[values groups].include?(key) } == after.reject { |key, _| %w[values groups].include?(key) }
        removed = before['values'] - after['values']
        added = after['values'] - before['values']
        return 'review' if (removed.empty? && added.empty?) || contexts.include?('unknown')
        return 'breaking' if contexts.include?('event') || (contexts.include?('input') && removed.any?) || (contexts.include?('output') && added.any?) || (contexts.include?('entity') && removed.any?)
        return 'review' if before['groups'] != after['groups']
        'additive'
      end

      def constraints_impact(before, after, contexts)
        return 'breaking' if contexts.include?('event') || (after['unique'] && !before['unique'])
        input_tighter = after.fetch('min_length', 0) > before.fetch('min_length', 0)
        input_tighter ||= after.key?('max_length') && (!before.key?('max_length') || after['max_length'] < before['max_length'])
        output_wider = after.fetch('min_length', 0) < before.fetch('min_length', 0)
        output_wider ||= before.key?('max_length') && (!after.key?('max_length') || after['max_length'] > before['max_length'])
        return 'breaking' if ((contexts & %w[input entity]).any? && input_tighter) || (contexts.include?('output') && output_wider)
        return 'review' if contexts.include?('unknown') || before['unique'] != after['unique']
        'additive'
      end

      def node_change(node, change)
        before, after = change == 'added' ? [nil, node_content(node).merge(node.slice('kind', 'id'))] : [node_content(node).merge(node.slice('kind', 'id')), nil]
        impact = change == 'removed' && CONTRACT_KINDS.include?(node['kind']) ? 'breaking' : (change == 'added' ? 'additive' : 'review')
        emit(node, '/', change, before, after, node_categories(node), impact, change == 'added' ? 'Nó adicionado' : 'Nó removido', before_present: change != 'added', after_present: change != 'removed')
      end

      def property(before, after, key, owner, path, categories, impact)
        return if before.key?(key) == after.key?(key) && before[key] == after[key]
        change = !before.key?(key) ? 'added' : (!after.key?(key) ? 'removed' : 'modified')
        emit(owner, path, change, before[key], after[key], categories, impact, 'Propriedade alterada', before_present: before.key?(key), after_present: after.key?(key))
      end

      def emit(owner, path, change, before, after, categories, impact, description, before_present: true, after_present: true)
        categories = categories.uniq.sort
        record = owner.slice('kind', 'id').merge(
          'path' => path, 'change' => change, 'categories' => categories, 'impact' => impact,
          'description' => description, 'before_present' => before_present, 'after_present' => after_present,
          'before' => Data.copy(before), 'after' => Data.copy(after),
          'requires_review' => impact != 'metadata' && (impact != 'additive' || (categories & REVIEW_CATEGORIES).any?)
        )
        record['permission_impact'] = 'indeterminate' if impact != 'metadata' && (categories & %w[permissions isolation]).any?
        @changes << record
      end

      def escape(value)
        value.gsub('~', '~0').gsub('/', '~1')
      end
    end
  end
end
