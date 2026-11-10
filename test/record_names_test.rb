require_relative 'test_helper'
require 'vetra/data'

class RecordNamesTest < GraphTest
  PROBE_PATH = 'app/domains/blog/record_probe.rb'.freeze

  def write_probe(root, fields)
    write(root, PROBE_PATH, "entity :record_probe do\n#{fields}\nend\n")
  end

  def probe(document)
    node(document, 'entity', 'blog.record_probe')
  end

  def runtime_document(document)
    copy = Vetra::Graph::Data.copy(document)
    yield probe(copy)
    copy['digest'] = Vetra::Graph::Canonical.digest(copy)
    copy
  end

  def reserved_record_methods(type)
    hooks = %i[
      initialize initialize_copy initialize_clone initialize_dup method_missing respond_to_missing?
      singleton_method_added singleton_method_removed singleton_method_undefined instance_variables_to_inspect
    ]
    private_methods = type.private_instance_methods.select do |name|
      type.instance_method(name).owner != Kernel || hooks.include?(name)
    end
    (type.public_instance_methods + type.protected_instance_methods + private_methods).map(&:to_s).uniq
  end

  def test_build_and_check_refuse_representative_record_methods_with_field_pointer_and_origin
    with_app do |root, compiler|
      %w[hash class with to_h inspect send public_send members freeze object_id method eql?
        initialize method_missing respond_to_missing? initialize_copy].each do |name|
        write_probe(root, "  string :label\n  string :#{name}")
        %i[build check].each do |operation|
          error = assert_graph_error('field_name_collides_with_record') { compiler.public_send(operation) }
          diagnostic = error.diagnostics.first
          assert_equal "/fields/1/name", diagnostic.pointer
          assert_equal "O campo #{name} colide com um método do registro Data; renomeie o campo.", diagnostic.message
          assert_equal PROBE_PATH, diagnostic.source['path']
          assert_equal 1, diagnostic.source['line']
          assert_equal :error, diagnostic.severity
        end
      end
    end
  end

  def test_failed_write_preserves_the_approved_artifact_and_cli_reports_the_new_code
    with_app do |root, compiler|
      approved = compiler.write.bytes
      write_probe(root, '  string :hash')
      %w[graph:build graph:check].each do |command|
        out, err = StringIO.new, StringIO.new
        assert_equal 1, Vetra::CLI.run([command, '--root', root], out: out, err: err)
        assert_empty out.string
        assert_includes err.string, '[field_name_collides_with_record] /fields/0/name:'
        assert_includes err.string, 'renomeie o campo'
        assert_equal approved, compiler.artifact.binread
      end
    end
  end

  def test_similar_field_names_and_enum_groups_are_accepted_by_compiler_and_repositories
    with_app do |root, compiler|
      write_probe(root, <<~RUBY)
        string :hashed
        string :klass
        string :with_value
        string :inspection
        enum :status, %w[draft published], groups: { closed: %w[draft], hash: %w[draft] }
      RUBY
      document = compiler.write.document
      assert compiler.check
      type = Vetra::Data::Repositories.new(document).record_type('blog.record_probe')
      record = type.new(id: 'id', created_at: Time.utc(2026), hashed: 'digest', klass: 'business',
        with_value: 'value', inspection: 'description', status: 'draft')
      assert_equal 'digest', record.hashed
      assert_equal 'business', record.klass
      assert_equal 'value', record.with_value
      assert_equal 'description', record.inspection
      assert record.closed?
      assert record.hash?
      assert_equal record, record.with
      assert_equal 1, { record => 1 }[record.with]
    end
  end

  def test_private_kernel_functions_are_accepted_as_fields_and_enum_groups
    with_app do |root, compiler|
      names = %w[format open select test system load]
      fields = names.map { |name| "  string :#{name}" }.join("\n")
      write_probe(root, fields + "\n  enum :status, %w[closed open], groups: { autoload: %w[closed], block_given: %w[closed], iterator: %w[closed] }")
      document = compiler.write.document
      assert compiler.check
      type = Vetra::Data::Repositories.new(document).record_type('blog.record_probe')
      attributes = names.to_h { |name| [name.to_sym, "#{name} original"] }
      record = type.new(id: 'id', created_at: Time.utc(2026), status: 'closed', **attributes)
      changed = record.with(**names.to_h { |name| [name.to_sym, "#{name} alterado"] })
      names.each do |name|
        assert_equal "#{name} original", record.public_send(name)
        assert_equal "#{name} alterado", changed.public_send(name)
      end
      %i[autoload? block_given? iterator?].each do |predicate|
        assert record.public_send(predicate)
        refute changed.with(status: 'open').public_send(predicate)
      end
    end
  end

  def test_enum_predicates_colliding_with_public_and_private_methods_point_to_the_group
    with_app do |root, compiler|
      %w[frozen nil eql respond_to respond_to_missing enum_group].each do |name|
        write_probe(root, "  string :label\n  enum :status, %w[closed open], groups: { #{name}: %w[closed] }")
        error = assert_graph_error('field_name_collides_with_record') { compiler.build }
        diagnostic = error.diagnostics.first
        assert_equal "/fields/1/type/groups/#{name}", diagnostic.pointer
        assert_equal "O grupo de enum #{name} gera o predicado #{name}?, que colide com um método do registro Data; renomeie o grupo.", diagnostic.message
        assert_equal PROBE_PATH, diagnostic.source['path']
      end
    end
  end

  # A enumeração parte de um registro real e exclui funções privadas do Kernel que podem virar leitores.
  def test_compiler_and_repositories_agree_on_all_record_field_method_names
    with_app do |root, compiler|
      write_probe(root, '  string :label')
      document = compiler.build.document
      type = Vetra::Data::Repositories.new(document).record_type('blog.record_probe')
      methods = reserved_record_methods(type)
      names = methods.grep(/\A[a-z][a-z0-9_]*\z/) - type.members.map(&:to_s)
      assert_includes names, 'hash'
      assert_includes names, 'initialize'
      %w[format open select test system load].each { |name| refute_includes names, name }
      names.each do |name|
        write_probe(root, "  string :#{name}")
        error = assert_raises(Vetra::Graph::Error, name) { compiler.build }
        assert_includes error.diagnostics.map(&:code), 'field_name_collides_with_record', name
        doc = runtime_document(document) { |entity| entity['fields'].find { |field| field['name'] == 'label' }['name'] = name }
        assert_graph_error('data_record_type') { Vetra::Data::Repositories.new(doc) }
      end
    end
  end

  def test_compiler_and_repositories_agree_on_all_record_enum_predicates
    with_app do |root, compiler|
      write_probe(root, '  enum :status, %w[closed open]')
      document = compiler.build.document
      type = Vetra::Data::Repositories.new(document).record_type('blog.record_probe')
      predicates = reserved_record_methods(type).grep(/\A[a-z][a-z0-9_]*\?\z/)
      assert_includes predicates, 'frozen?'
      assert_includes predicates, 'enum_group?'
      assert_includes predicates, 'respond_to_missing?'
      %w[autoload? block_given? iterator?].each { |name| refute_includes predicates, name }
      predicates.each do |predicate|
        name = predicate.delete_suffix('?')
        write_probe(root, "  enum :status, %w[closed open], groups: { #{name}: %w[closed] }")
        assert_graph_error('field_name_collides_with_record') { compiler.build }
        doc = runtime_document(document) do |entity|
          entity['fields'].find { |field| field['name'] == 'status' }['type']['groups'] = { name => ['closed'] }
        end
        assert_graph_error('data_record_type') { Vetra::Data::Repositories.new(doc) }
      end
    end
  end

  def test_kernel_methods_added_after_loading_follow_their_current_visibility
    with_app do |root, compiler|
      begin
        Kernel.define_method(:late_kernel_field) { nil }
        Kernel.define_method(:late_kernel_group?) { false }
        Kernel.send(:private, :late_kernel_field, :late_kernel_group?)
        write_probe(root, '  string :late_kernel_field')
        document = compiler.build.document
        Vetra::Data::Repositories.new(document)
        write_probe(root, '  enum :status, %w[closed open], groups: { late_kernel_group: %w[closed] }')
        group_document = compiler.build.document
        Vetra::Data::Repositories.new(group_document)

        Kernel.send(:protected, :late_kernel_field, :late_kernel_group?)
        assert_graph_error('field_name_collides_with_record') { compiler.build }
        assert_graph_error('data_record_type') { Vetra::Data::Repositories.new(group_document) }
        write_probe(root, '  string :late_kernel_field')
        assert_graph_error('field_name_collides_with_record') { compiler.build }
        assert_graph_error('data_record_type') { Vetra::Data::Repositories.new(document) }
      ensure
        Kernel.remove_method(:late_kernel_field)
        Kernel.remove_method(:late_kernel_group?)
      end
    end
  end

  def test_core_generated_field_names_keep_their_existing_diagnostic
    with_app do |root, compiler|
      %w[id created_at].each do |name|
        write_probe(root, "  string :#{name}")
        assert_graph_error('reserved_field') { compiler.build }
      end
    end
  end

  def test_methods_added_to_record_after_loading_are_reserved_at_both_boundaries
    with_app do |root, compiler|
      write_probe(root, '  string :label')
      document = compiler.build.document
      record = Vetra::Data::Record
      begin
        record.define_method(:late_record_method) { nil }
        record.define_method(:late_record_group?) { false }
        record.send(:private, :late_record_group?)

        write_probe(root, '  string :late_record_method')
        assert_graph_error('field_name_collides_with_record') { compiler.build }
        doc = runtime_document(document) do |entity|
          entity['fields'].find { |field| field['name'] == 'label' }['name'] = 'late_record_method'
        end
        assert_graph_error('data_record_type') { Vetra::Data::Repositories.new(doc) }

        write_probe(root, '  enum :status, %w[closed open], groups: { late_record_group: %w[closed] }')
        assert_graph_error('field_name_collides_with_record') { compiler.build }
        doc = runtime_document(document) do |entity|
          entity['fields'] << { 'name' => 'status', 'type' => { 'name' => 'enum', 'values' => %w[closed open],
            'groups' => { 'late_record_group' => ['closed'] } }, 'required' => true, 'nullable' => false,
            'privacy' => { 'personal' => false } }
        end
        assert_graph_error('data_record_type') { Vetra::Data::Repositories.new(doc) }
      ensure
        record.remove_method(:late_record_method)
        record.remove_method(:late_record_group?)
      end
    end
  end
end
