require_relative 'test_helper'

# ADR-001, critério 2 da fase 0: cada regra semântica tem um caso que a dispara, com código, ponteiro JSON e origem.
# Cada teste abaixo dispara uma regra que nenhum outro teste exercitava (docs/fase-0-criterios.md).
class DiagnosticsTest < GraphTest
  # Validador: parte da IR de exemplo e a altera para violar só a regra-alvo. A IR é montada à mão porque o
  # validador também verifica IR que não veio do DSL (um artefato lido do disco), e o normalizador nunca produz
  # alguns desses estados (por exemplo, implementation_ref e tenant_root).
  def validator_document
    Vetra::Graph::Canonical.parse(File.read(File.join(PROJECT, 'docs/ir/exemplos/mini-crm.v0.1.json')))
  end

  def diagnostics_for(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    validator = Vetra::Graph::Validator.new
    validator.validate!(document)
    validator.warnings
  rescue Vetra::Graph::Error => e
    e.diagnostics
  end

  def lead(document) = node(document, 'entity', 'crm.lead')

  def lead_field(document, name) = lead(document)['fields'].find { |field| field['name'] == name }

  def win_lead(document) = node(document, 'command', 'crm.win_lead')

  def other_command(document)
    copy = Vetra::Graph::Data.copy(win_lead(document))
    copy['id'] = 'crm.reopen_lead'
    copy['implementation']['ref'] = 'crm.reopen_lead#call'
    document['nodes'] << copy
    copy
  end

  # [mutação, com origem?]. As regras que só avisam (severidade :warning) não impedem a validação.
  VALIDATOR_CASES = {
    'duplicate_input' => [->(d) { d['inputs'] << d['inputs'].first.merge('digest' => "sha256:#{'1' * 64}") }, false],
    'dependency_unclassified' => [->(d) { node(d, 'dependency', 'crm.pg')['trust'] = 'unclassified' }, true],
    'domain_unrestricted' => [->(d) { node(d, 'domain', 'crm')['depends_on'] = nil }, true],
    'decimal_scale' => [->(d) { lead_field(d, 'valor')['type']['scale'] = lead_field(d, 'valor')['type']['precision'] + 1 }, true],
    'enum_group' => [->(d) { lead_field(d, 'status')['type']['groups']['ghost'] = ['nonexistent'] }, true],
    'field_constraints' => [->(d) { lead_field(d, 'name')['constraints'] = { 'min_length' => 10, 'max_length' => 2 } }, true],
    'field_generation' => [->(d) { lead_field(d, 'name')['generate'] = { 'kind' => 'slug', 'from' => 'ghost' } }, true],
    'duplicate_guard' => [lambda { |d|
      other = other_command(d)
      lead_field(d, 'status')['guarded'] << { 'value' => 'won', 'commands' => [{ 'kind' => 'command', 'id' => other['id'] }] }
    }, true],
    'guard_value' => [->(d) { lead_field(d, 'status')['guarded'] << { 'value' => 'ghost', 'commands' => [{ 'kind' => 'command', 'id' => 'crm.win_lead' }] } }, true],
    'field_rename' => [->(d) { lead_field(d, 'email')['previous_names'] = ['name'] }, true],
    'duplicate_relation' => [->(d) { lead(d)['relations'] << lead(d)['relations'].first.merge('same_tenant' => true) }, true],
    'relation_key' => [->(d) { lead(d)['relations'].first['local_fields'] = %w[company_id status] }, true],
    'duplicate_index' => [->(d) { lead(d)['indexes'] << lead(d)['indexes'].first.merge('unique' => true) }, true],
    'tenant_index' => [->(d) { lead(d)['indexes'] << { 'name' => 'ghost_idx', 'fields' => %w[status company_id], 'unique' => false } }, true],
    'tenant_root' => [->(d) { node(d, 'entity', 'crm.company')['tenant'] = lead(d)['tenant'] }, true],
    'implementation_ref' => [->(d) { win_lead(d)['implementation']['ref'] = 'crm.other#call' }, true],
    'authorize_record' => [->(d) { win_lead(d)['authorize']['record'] = 'ghost' }, true],
    'crud_repository' => [lambda { |d|
      win_lead(d)['implementation'] = { 'kind' => 'builtin', 'name' => 'crud.update' }
      win_lead(d)['uses'] = [{ 'kind' => 'capability', 'id' => 'crm.leads' }, { 'kind' => 'capability', 'id' => 'crm.leads_read' }]
    }, true],
    'predicate_input' => [lambda { |d|
      node(d, 'policy', 'crm.vendedor_leads')['predicate'] =
        { 'op' => 'eq', 'left' => { 'kind' => 'input', 'path' => ['x'] }, 'right' => { 'kind' => 'literal', 'value' => 1 } }
    }, true],
    'sql_boundary' => [->(d) { node(d, 'capability', 'crm.leads')['config'] = { 'type' => 'sql', 'access' => 'read' } }, true]
  }.freeze

  VALIDATOR_CASES.each do |code, (mutation, with_source)|
    define_method("test_validator_emits_#{code}") do
      document = validator_document
      instance_exec(document, &mutation)
      diagnostic = diagnostics_for(document).find { |item| item.code == code }
      refute_nil diagnostic, "#{code} não foi emitido"
      assert_match %r{\A/}, diagnostic.pointer, "#{code} sem ponteiro JSON"
      assert diagnostic.source['path'], "#{code} sem origem" if with_source
    end
  end

  # Normalizador, DSL, carregador, manifesto e registro: cada caso parte de um exemplo, altera as declarações e
  # compila. [exemplo, preparação, com origem?]. Os códigos do DSL chegam intactos: o carregador só reembrulha
  # SyntaxError, ArgumentError, TypeError e NameError.
  DECLARATION_CASES = {
    'app_missing' => ['blog', ->(root) { write(root, 'config/app.rb', "# sem Vetra.app\n") }, false],
    'tenant_reference' => ['mini_crm', ->(root) { edit(root, 'config/app.rb') { |text| text.sub('tenant :company', 'tenant :ghost') } }, false],
    'tenant_mismatch' => ['mini_crm', ->(root) { edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('tenant :company', 'tenant :other') } }, true],
    'reserved_field' => ['blog', ->(root) { edit(root, 'app/domains/blog/post.rb') { |text| text.sub("  string :title", "  string :id\n  string :title") } }, true],
    'crud_enum' => ['blog', lambda { |root|
      edit(root, 'app/domains/blog/post.rb') do |text|
        text.sub(%(enum :status, %w[draft published], default: "draft"), %(enum :status, %w[published], default: "published"))
      end
    }, true],
    'predicate_relation' => ['blog', lambda { |root|
      edit(root, 'app/domains/blog/roles.rb') { |text| text.sub('scope: :author', 'where: { ghost: { id: :current_actor } }') }
    }, true],
    'field_missing' => ['blog', ->(root) { edit(root, 'app/domains/blog/events.rb') { |text| text.sub('fields: %i[id]', 'fields: %i[ghost]') } }, true],
    'handler_idempotency' => ['mini_crm', ->(root) { edit(root, 'app/domains/crm/notify_sales.rb') { |text| text.sub("  idempotent_by :event_id\n", '') } }, true],
    'authorize_missing' => ['blog', ->(root) { edit(root, 'app/domains/blog/publish_post.rb') { |text| text.sub(/^  authorize .*\n/, '') } }, true],
    'route_format' => ['blog', ->(root) { edit(root, 'app/domains/blog/publish_post.rb') { |text| text.sub('"POST /posts/:post_id/publish"', '"POST"') } }, true],
    'domain_required' => ['blog', ->(root) { edit(root, 'config/app.rb') { |text| "#{text}entity :ghost do\nend\n" } }, true],
    'unsupported_option' => ['blog', ->(root) { edit(root, 'app/domains/blog/post.rb') { |text| text.sub('max: 200', 'max: 200, ghost: 1') } }, true],
    'missing_option' => ['blog', ->(root) { edit(root, 'app/domains/blog/post.rb') { |text| text.sub('  crud', "  has_many :comments\n  crud") } }, true],
    'relation_target' => ['blog', ->(root) { edit(root, 'app/domains/blog/post.rb') { |text| text.sub('  crud', "  many_to_many :gizmos\n  crud") } }, true],
    'unsafe_reason' => ['blog', ->(root) { edit(root, 'app/domains/blog/publish_post.rb') { |text| text.sub("  call do", "  unsafe_effect ' '\n  call do") } }, true],
    'domain_mismatch' => ['blog', ->(root) { edit(root, 'app/domains/blog/domain.rb') { |text| text.sub('domain :blog', 'domain :other') } }, true],
    'missing_implementation' => ['blog', ->(root) { edit(root, 'app/domains/blog/publish_post.rb') { |text| text.sub(/  call do.*?\n  end\n/m, '') } }, true],
    'duplicate_app' => ['blog', ->(root) { edit(root, 'config/app.rb') { |text| "#{text}Vetra.app :blog do\nend\n" } }, true],
    'domain_name' => ['blog', ->(root) { write(root, 'app/domains/Bad-Name/x.rb', "entity :x do\nend\n") }, true],
    'input_missing' => ['blog', ->(root) { FileUtils.rm(File.join(root, '.ruby-version')) }, false],
    'input_symlink' => ['blog', ->(root) { File.symlink(File.join(root, 'app/domains'), File.join(root, 'app/alias')) }, false]
  }.freeze

  DECLARATION_CASES.each do |code, (app, setup, with_source)|
    define_method("test_declaration_emits_#{code}") do
      with_app(app) do |root, compiler|
        instance_exec(root, &setup)
        error = assert_graph_error(code) { compiler.build }
        diagnostic = error.diagnostics.find { |item| item.code == code }
        assert_match %r{\A/}, diagnostic.pointer, "#{code} sem ponteiro JSON"
        assert diagnostic.source['path'], "#{code} sem origem" if with_source
      end
    end
  end

  # O que o DSL ainda não implementa falha nomeando a opção, como já faz nas opções de campo, e não com o
  # ArgumentError do Ruby embrulhado em dsl_error (docs/fase-0-criterios.md, critério 7).
  def test_unimplemented_options_are_named_instead_of_leaking_a_ruby_argument_error
    {
      'rate_limit' => ['app/domains/blog/roles.rb', ->(text) { text.sub('scope: :author', 'scope: :author, rate_limit: "5/min"') }],
      'rounding' => ['config/app.rb', ->(text) { text.sub('currency "BRL"', 'currency "BRL", rounding: :half_up') }]
    }.each do |option, (path, change)|
      with_app('blog') do |root, compiler|
        edit(root, path, &change)
        error = assert_graph_error('unsupported_option') { compiler.build }
        assert_includes error.message, option
        diagnostic = error.diagnostics.find { |item| item.code == 'unsupported_option' }
        assert diagnostic.source['path'], "#{option} sem origem"
        refute_includes error.diagnostics.map(&:code), 'dsl_error'
      end
    end
  end

  # Uma palavra-chave desconhecida ou ausente numa declaração nomeia a opção e o método e aponta a linha real da
  # declaração, em vez de repassar o ArgumentError do Ruby na linha 1 do arquivo.
  def test_keyword_errors_name_the_option_the_method_and_the_line
    {
      'unsupported_option' => ['post.rb', 'crud scope: :author', 'crud scope: :author, ui: :admin', 'ui', 'crud'],
      'missing_option' => ['publish_post.rb', 'expose http: "POST /posts/:post_id/publish"', 'expose', 'http', 'expose']
    }.each do |code, (file, from, to, option, method)|
      with_app('blog') do |root, compiler|
        path = "app/domains/blog/#{file}"
        edit(root, path) { |text| text.sub(from, to) }
        line = File.readlines(File.join(root, path)).index { |content| content.include?(to) } + 1
        error = assert_graph_error(code) { compiler.build }
        diagnostic = error.diagnostics.find { |item| item.code == code }
        assert_equal line, diagnostic.source['line'], "#{code}: linha da declaração"
        assert_includes diagnostic.message, "em #{method}:"
        assert_includes diagnostic.message, option
        refute_includes error.diagnostics.map(&:code), 'dsl_error'
      end
    end
  end

  def test_project_root_must_exist
    Dir.mktmpdir('vetra-test-') do |directory|
      assert_graph_error('project_root') { Vetra::Graph::Compiler.new(root: File.join(directory, 'ausente')) }
      assert_graph_error('project_root') { Vetra::Graph::DiffSource.new(root: File.join(directory, 'ausente')) }
    end
  end

  def test_artifact_directory_cannot_leave_the_project
    with_app do |root, compiler|
      Dir.mktmpdir('vetra-outside-') do |outside|
        File.symlink(outside, File.join(root, '.vetra'))
        assert_graph_error('artifact_path') { compiler.write }
        assert_empty Dir.children(outside), 'nada deve ser gravado fora do projeto'
      end
    end
  end

  def test_diff_by_revision_reports_a_missing_git
    with_app do |root, _compiler|
      path = ENV['PATH']
      begin
        ENV['PATH'] = ''
        assert_graph_error('git_unavailable') { Vetra::Graph::DiffSource.new(root: root).read('git:HEAD') }
      ensure
        ENV['PATH'] = path
      end
    end
  end

  def test_schema_refuses_external_references
    schema = JSON.parse(File.read(Vetra::Graph::Schema::PATH, encoding: Encoding::UTF_8))
    schema['properties']['app'] = { '$ref' => 'https://example.invalid/app.json' }
    Dir.mktmpdir('vetra-schema-') do |directory|
      path = File.join(directory, 'v0.1.schema.json')
      File.write(path, JSON.generate(schema))
      original = Vetra::Graph::Schema::PATH
      begin
        Vetra::Graph::Schema.send(:remove_const, :PATH)
        Vetra::Graph::Schema.const_set(:PATH, path)
        assert_graph_error('schema_reference') { Vetra::Graph::Schema.new.validate!(validator_document) }
      ensure
        Vetra::Graph::Schema.send(:remove_const, :PATH)
        Vetra::Graph::Schema.const_set(:PATH, original)
      end
    end
  end

  # ADR-001, critério 3: a descoberta de arquivos em outra ordem gera os mesmos bytes. O teste embaralha a ordem em
  # que o Find entrega os caminhos e confere que a ordem mudou de fato, senão ele passaria sem testar nada.
  def test_discovery_order_does_not_change_the_graph_bytes
    require 'minitest/mock'
    with_app('mini_crm') do |root, compiler|
      expected = compiler.build.bytes
      original = Find.method(:find)
      reordered = [] # uma entrada por varredura: [ordem original, ordem entregue ao compilador]
      [1, 2, 3].each do |seed|
        replay = lambda do |*roots, &block|
          paths = []
          original.call(*roots) { |path| paths << path }
          shuffled = paths.shuffle(random: Random.new(seed))
          reordered << [paths, shuffled]
          shuffled.each { |path| catch(:prune) { block.call(path) } }
        end
        Find.stub(:find, replay) { assert_equal expected, Vetra::Graph::Compiler.new(root: root).build.bytes }
      end
      assert reordered.any? { |before, after| before.size > 1 && before != after }, 'a ordem de descoberta não foi alterada'
    end
  end
end
