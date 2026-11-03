require_relative 'test_helper'

class RoundingTest < GraphTest
  FEATURE = 'vetra.money_rounding'

  def set_rounding(root, expression)
    edit(root, 'config/app.rb') { |text| text.sub('currency "BRL"', "currency \"BRL\", rounding: #{expression}") }
  end

  def normalize(root, version)
    manifest = Vetra::Graph::Manifest.new(root)
    registry = Vetra::Graph::DeclarationLoader.new(manifest).load
    Vetra::Graph::Normalizer.new(registry, manifest, ir_version: version).document
  end

  def validate(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    Vetra::Graph::Validator.new.validate!(document)
  end

  def test_omission_keeps_half_up_implicit_with_or_without_currency_and_money_fields
    %w[blog mini_crm].each do |name|
      with_app(name) do |root, compiler|
        [true, false].each do |with_currency|
          edit(root, 'config/app.rb') { |text| text.sub('  currency "BRL"', '') } unless with_currency
          document = compiler.write.document
          assert_equal '0.6', document['ir_version']
          assert_equal 'BRL', document.dig('app', 'currency')
          refute document['app'].key?('rounding')
          refute_includes document['requires'], FEATURE
          money = document['nodes'].select { |entry| %w[entity contract].include?(entry['kind']) }.any? { |entry| entry['fields'].any? { |field| field.dig('type', 'name') == 'money' } }
          assert_equal name == 'mini_crm', money
          assert_equal document, compiler.validate_file(compiler.artifact, sources: true).document
          assert_equal document, compiler.link.document
          assert_equal document, compiler.check.document
        end
      end
    end
  end

  def test_both_modes_accept_symbols_and_strings_and_link_without_execution
    %w[half_up half_even].each do |mode|
      [":#{mode}", mode.inspect].each do |expression|
        %w[blog mini_crm].each do |name|
          with_app(name) do |root, compiler|
            set_rounding(root, expression)
            document = compiler.write.document
            assert_equal mode, document.dig('app', 'rounding')
            assert_includes document['requires'], FEATURE
            assert_equal document, compiler.validate_file(compiler.artifact, sources: true).document
            assert_equal document, compiler.link.document
            assert_equal document, compiler.check.document
          end
        end
      end
    end
  end

  def test_unknown_modes_and_invalid_types_have_a_specific_diagnostic_and_declaration_line
    [':up', ':half_down', '"HALF_UP"', '""', 'nil', 'true', 'false', '1', '[]', '{}'].each do |expression|
      with_app do |root, compiler|
        set_rounding(root, expression)
        line = File.readlines(File.join(root, 'config/app.rb')).index { |text| text.include?('rounding:') } + 1
        error = assert_graph_error('money_rounding') { compiler.build }
        diagnostic = error.diagnostics.find { |entry| entry.code == 'money_rounding' }
        assert_equal '/app/rounding', diagnostic.pointer
        assert_equal({ 'path' => 'config/app.rb', 'line' => line }, diagnostic.source)
        assert_includes diagnostic.message, 'half_up'
        assert_includes diagnostic.message, 'half_even'
        refute_includes error.diagnostics.map(&:code), 'dsl_error'
      end
    end
  end

  def test_unknown_currency_options_still_fail_audibly
    with_app do |root, compiler|
      set_rounding(root, ':half_up, round: :half_even')
      error = assert_graph_error('unsupported_option') { compiler.build }
      assert_includes error.message, 'round'
    end
  end

  def test_repeating_currency_without_rounding_resets_the_default
    with_app do |root, compiler|
      set_rounding(root, ':half_even')
      edit(root, 'config/app.rb') { |text| text.sub('rounding: :half_even', "rounding: :half_even\n  currency \"BRL\"") }
      document = compiler.build.document
      refute document['app'].key?('rounding')
      refute_includes document['requires'], FEATURE
    end
  end

  def test_external_ir_requires_the_feature_even_for_the_default_mode
    with_app do |_root, compiler|
      original = compiler.build.document
      %w[half_up half_even].each do |mode|
        document = Vetra::Graph::Data.copy(original)
        document['app']['rounding'] = mode
        document['requires'].delete(FEATURE)
        error = assert_graph_error('ir_feature') { validate(document) }
        assert_equal '/app/rounding', error.diagnostics.first.pointer
        assert_graph_error('ir_feature') { Vetra::Graph::Diff.new.compare(document, document) }
      end
    end
  end

  def test_external_ir_rejects_unknown_modes_and_types_structurally
    with_app do |_root, compiler|
      original = compiler.build.document
      ['up', 'half_down', '', nil, true, 1, [], {}].each do |mode|
        document = Vetra::Graph::Data.copy(original)
        document['app']['rounding'] = mode
        error = assert_graph_error('schema') { validate(document) }
        assert error.diagnostics.any? { |entry| entry.pointer == '/app/rounding' }
      end
    end
  end

  def test_ir_0_5_allows_omission_with_the_old_half_up_meaning
    with_app do |_root, compiler|
      original = Vetra::Graph::Data.copy(compiler.build.document)
      original['app']['rounding'] = 'half_up'
      original['requires'] << FEATURE
      validate(original)
      [true, false].each do |with_feature|
        document = Vetra::Graph::Data.copy(original)
        document['app'].delete('rounding')
        document['requires'].delete(FEATURE) unless with_feature
        assert validate(document)
        [[original, document], [document, original]].each do |before, after|
          report = Vetra::Graph::Diff.new.compare(before, after)
          refute report.breaking?
          refute report.data['changes'].any? { |entry| entry['path'] == '/app/rounding' }
          changes = report.data['changes']
          if with_feature
            assert_empty changes
          else
            assert_equal 1, changes.size
            assert_equal '/requires', changes.first['path']
            assert_equal 'review', changes.first['impact']
            assert changes.first['requires_review']
          end
        end
      end
    end
  end

  def test_previous_formats_refuse_the_field_and_feature_independently
    with_app('mini_crm') do |root, _compiler|
      %w[0.1 0.2 0.3 0.4].each do |version|
        original = normalize(root, version)
        document = Vetra::Graph::Data.copy(original)
        document['requires'] << FEATURE
        assert_graph_error('ir_feature') { validate(document) }
        %w[half_up half_even].each do |mode|
          document = Vetra::Graph::Data.copy(original)
          document['app']['rounding'] = mode
          assert_graph_error('schema') { validate(document) }
          assert_graph_error('schema') { Vetra::Graph::Diff.new.compare(document, document) }
        end
      end
    end
  end

  def test_previous_formats_do_not_silently_discard_explicit_rounding
    %w[half_up half_even].each do |mode|
      with_app do |root, _compiler|
        set_rounding(root, ":#{mode}")
        %w[0.1 0.2 0.3 0.4].each do |version|
          error = assert_graph_error('ir_feature') { normalize(root, version) }
          assert_equal '/app/rounding', error.diagnostics.first.pointer
          assert_equal 'config/app.rb', error.diagnostics.first.source['path']
        end
      end
    end
  end

  def test_previous_artifacts_link_unchanged_and_rebuild_preserves_effective_rounding
    with_app('mini_crm') do |root, compiler|
      %w[0.1 0.2 0.3 0.4].each do |version|
        document = normalize(root, version)
        refute document['app'].key?('rounding')
        refute_includes document['requires'], FEATURE
        compiler.artifact.dirname.mkpath
        bytes = "#{Vetra::Graph::Canonical.dump(document)}\n"
        compiler.artifact.binwrite(bytes)
        assert_equal document, compiler.validate_file(compiler.artifact, sources: true).document
        assert_equal document, compiler.link.document
        assert_equal bytes, compiler.artifact.binread
        assert_graph_error('graph_stale') { compiler.check }
        report = Vetra::Graph::Diff.new.compare(document, compiler.build.document)
        refute report.breaking?
        refute report.data['changes'].any? { |entry| entry['path'] == '/app/rounding' }
        changes = report.data['changes']
        assert changes.any? { |entry| entry['path'] == '/ir_version' && entry['impact'] == 'review' }
        refute changes.any? { |entry| entry['path'] == '/requires' } unless version == '0.1'
        assert_equal 1, changes.size unless version == '0.1' # A 0.2 já adicionava created_at.
      end
    end
  end

  def test_ir_0_4_keeps_generated_relation_commands_structured_outputs_and_live
    with_app('chat') do |root, compiler|
      %w[add_member remove_member].each { |name| File.unlink(File.join(root, "app/domains/chat/#{name}.rb")) }
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub(', commands: false', '') }
      document = normalize(root, '0.4')
      assert_includes document['requires'], 'vetra.relation_commands'
      assert_includes document['requires'], 'vetra.structured_outputs'
      assert_includes document['requires'], 'vetra.live'
      compiler.artifact.dirname.mkpath
      bytes = "#{Vetra::Graph::Canonical.dump(document)}\n"
      compiler.artifact.binwrite(bytes)
      assert_equal document, compiler.validate_file(compiler.artifact, sources: true).document
      linked = compiler.link
      assert_equal document, linked.document
      assert_equal 'pending', linked.binding_for('command', 'chat.add_member')['executor']
      assert_equal bytes, compiler.artifact.binread
      refute Vetra::Graph::Diff.new.compare(document, compiler.build.document).breaking?
    end
  end

  def test_diff_marks_both_effective_mode_changes_as_value_breaks
    with_app do |root, compiler|
      set_rounding(root, ':half_up')
      original = compiler.build.document
      half_even = Vetra::Graph::Data.copy(original)
      half_even['app']['rounding'] = 'half_even'
      validate(half_even)
      [[original, half_even], [half_even, original]].each do |before, after|
        report = Vetra::Graph::Diff.new.compare(before, after)
        assert report.breaking?
        change = report.data['changes'].fetch(0)
        assert_equal 1, report.data['summary']['total']
        assert_equal '/app/rounding', change['path']
        assert_equal ['values'], change['categories']
        assert_equal 'breaking', change['impact']
        assert_equal before.dig('app', 'rounding'), change['before']
        assert_equal after.dig('app', 'rounding'), change['after']
        assert change['requires_review']
      end
    end
  end

  def test_diff_handles_implicit_half_up_in_both_directions_and_removal_of_half_even
    with_app('mini_crm') do |root, compiler|
      legacy = normalize(root, '0.4')
      current = Vetra::Graph::Data.copy(compiler.build.document)
      current['app']['rounding'] = 'half_even'
      current['requires'] << FEATURE
      validate(current)
      [[legacy, current], [current, legacy]].each do |before, after|
        report = Vetra::Graph::Diff.new.compare(before, after)
        change = report.data['changes'].find { |entry| entry['path'] == '/app/rounding' }
        assert_equal 'breaking', change['impact']
        assert change['requires_review']
        assert_equal ['values'], change['categories']
      end
    end
  end

  def test_rounding_does_not_relax_default_validation_or_change_scale_and_precision
    %w[half_up half_even].each do |mode|
      [['JPY', 0, '1.5'], ['BRL', 2, '1.225'], ['BHD', 3, '1.2345'], ['BRL', 4, '1.23455']].each do |currency, scale, amount|
        with_app('mini_crm') do |root, compiler|
          edit(root, 'config/app.rb') { |text| text.sub('currency "BRL"', "currency #{currency.inspect}, rounding: :#{mode}") }
          declaration = "money :valor, scale: #{scale}, default: { amount: #{amount.inspect}, currency: #{currency.inspect} }"
          edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('money :valor, optional: true', declaration) }
          assert_graph_error('field_default') { compiler.build }
        end
      end
    end
  end

  def test_mode_is_application_data_and_reproducible_between_checkouts
    with_app('mini_crm') do |root, compiler|
      set_rounding(root, ':half_even')
      original = compiler.build
      Dir.mktmpdir('vetra-rounding-copy-') do |copy|
        FileUtils.cp_r("#{root}/.", copy)
        assert_equal original.bytes, Vetra::Graph::Compiler.new(root: copy).build.bytes
      end
      assert_equal original.bytes, compiler.build.bytes
      original.document['nodes'].select { |entry| %w[entity contract].include?(entry['kind']) }.each do |entry|
        entry['fields'].select { |field| field.dig('type', 'name') == 'money' }.each do |field|
          assert_equal({ 'name' => 'money', 'scale' => 2, 'precision' => 19 }, field['type'])
        end
      end
    end
  end
end
