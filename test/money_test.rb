require_relative 'test_helper'

class MoneyTest < GraphTest
  def with_money_app(currency, declaration = 'money :valor, optional: true')
    with_app('mini_crm') do |root, compiler|
      edit(root, 'config/app.rb') { |text| text.sub('currency "BRL"', "currency #{currency.inspect}") }
      edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('money :valor, optional: true', declaration) }
      yield root, compiler
    end
  end

  def money_field(document, kind = 'entity', id = 'crm.lead', name = 'valor')
    node(document, kind, id)['fields'].find { |field| field['name'] == name } || raise('Campo não encontrado')
  end

  def validate(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    Vetra::Graph::Validator.new.validate!(document)
  end

  def test_implicit_scale_follows_currency_in_entities_and_crud_contracts
    { 'BRL' => 2, 'USD' => 2, 'JPY' => 0, 'BHD' => 3, 'CLF' => 4 }.each do |currency, exponent|
      with_money_app(currency) do |_root, compiler|
        result = compiler.build
        assert_empty result.warnings
        assert_equal '0.1', result.document['ir_version']
        [
          ['entity', 'crm.lead'], ['contract', 'crm.lead.record'],
          ['contract', 'crm.create_lead.input'], ['contract', 'crm.update_lead.input']
        ].each do |kind, id|
          assert_equal({ 'name' => 'money', 'precision' => 19, 'scale' => exponent }, money_field(result.document, kind, id)['type'], "#{currency}: #{id}")
        end
      end
    end
  end

  def test_explicit_scale_can_equal_or_exceed_currency_exponent
    [['JPY', 0], ['JPY', 2], ['BHD', 3], ['BHD', 4], ['BRL', 4]].each do |currency, scale|
      with_money_app(currency, "money :valor, scale: #{scale}") do |_root, compiler|
        assert_equal scale, money_field(compiler.build.document).dig('type', 'scale')
      end
    end
  end

  def test_scale_below_currency_exponent_has_json_pointer_and_origin
    [['BRL', 1], ['BHD', 2], ['CLF', 3]].each do |currency, scale|
      with_money_app(currency, "money :valor, scale: #{scale}") do |_root, compiler|
        error = assert_graph_error('money_scale') { compiler.build }
        diagnostic = error.diagnostics.find { |item| item.code == 'money_scale' }
        assert_match %r{\A/nodes/\d+/fields/\d+/type/scale\z}, diagnostic.pointer
        assert_equal 'app/domains/crm/lead.rb', diagnostic.source['path']
        assert_includes diagnostic.message, currency
      end
    end
  end

  def test_implicit_scale_still_cannot_exceed_precision
    with_money_app('BHD', 'money :valor, precision: 2') do |_root, compiler|
      assert_graph_error('decimal_scale') { compiler.build }
    end
  end

  def test_money_scale_is_checked_when_money_exists_only_in_a_query_input
    with_app do |root, compiler|
      edit(root, 'config/app.rb') { |text| text.sub('currency "BRL"', 'currency "BHD"') }
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('  returns :post', "  input :price, :money, scale: 2\n  returns :post") }
      error = assert_graph_error('money_scale') { compiler.build }
      diagnostic = error.diagnostics.find { |item| item.code == 'money_scale' }
      assert_equal 'app/domains/blog/find_post.rb', diagnostic.source['path']
    end
  end

  def test_money_inputs_and_event_payloads_use_currency_but_decimal_keeps_its_default
    with_money_app('BHD') do |root, compiler|
      edit(root, 'app/domains/crm/win_lead.rb') do |text|
        text.sub('input :lead_id, :id', "input :lead_id, :id\n  input :price, :money\n  input :ratio, :decimal")
            .sub('with: %i[id]', 'with: %i[id valor]')
      end
      edit(root, 'app/domains/crm/events.rb') { |text| text.sub('fields: %i[id]', 'fields: %i[id valor]') }
      write(root, 'app/domains/crm/quote.rb', <<~RUBY)
        query :quote do
          input :price, :money, scale: 4
          returns :lead
          authorize :read, :lead
          uses :leads
          call do |input, leads|
            leads.all
          end
        end
      RUBY
      document = compiler.write.document
      assert_equal 3, money_field(document, 'contract', 'crm.win_lead.input', 'price').dig('type', 'scale')
      assert_equal 2, money_field(document, 'contract', 'crm.win_lead.input', 'ratio').dig('type', 'scale')
      assert_equal 4, money_field(document, 'contract', 'crm.quote.input', 'price').dig('type', 'scale')
      payload = node(document, 'event', 'crm.lead.won')['payload']['id']
      assert_equal 3, money_field(document, 'contract', payload).dig('type', 'scale')
      assert_equal document, compiler.link.document
    end
  end

  def test_unknown_or_undefined_currency_exponent_is_not_assumed_to_be_two
    %w[ZZZ XAU XXX].each do |currency|
      ['money :valor', 'money :valor, scale: 4'].each do |declaration|
        with_money_app(currency, declaration) do |_root, compiler|
          error = assert_graph_error('money_currency') { compiler.build }
          diagnostic = error.diagnostics.find { |item| item.code == 'money_currency' }
          assert_equal '/app/currency', diagnostic.pointer
          assert_equal 'config/app.rb', diagnostic.source['path']
          assert_includes diagnostic.message, currency
        end
      end
    end
  end

  def test_defaults_follow_currency_scale_without_rounding
    [
      ['JPY', '100', true], ['JPY', '100.50', false],
      ['BHD', '1.234', true], ['BHD', '1.2345', false],
      ['BRL', '10.00', true], ['BRL', '10.001', false]
    ].each do |currency, amount, valid|
      declaration = "money :valor, default: { amount: #{amount.inspect}, currency: #{currency.inspect} }"
      with_money_app(currency, declaration) do |_root, compiler|
        if valid
          assert_equal amount, money_field(compiler.build.document).dig('default', 'value', 'amount')
        else
          assert_graph_error('field_default') { compiler.build }
        end
      end
    end
  end

  def test_extended_precision_accepts_extra_decimals_up_to_the_declared_scale
    %w[10.0015 10.00151].each do |amount|
      declaration = "money :valor, scale: 4, default: { amount: #{amount.inspect}, currency: 'BRL' }"
      with_money_app('BRL', declaration) do |_root, compiler|
        if amount == '10.0015'
          assert_equal amount, money_field(compiler.build.document).dig('default', 'value', 'amount')
        else
          assert_graph_error('field_default') { compiler.build }
        end
      end
    end
  end

  def test_default_currency_must_have_an_exponent_that_fits_the_field
    [['USD', 2, true], ['BHD', 2, false], ['BHD', 3, true], ['ZZZ', 4, false], ['XAU', 4, false]].each do |currency, scale, valid|
      declaration = "money :valor, scale: #{scale}, default: { amount: '1', currency: #{currency.inspect} }"
      with_money_app('BRL', declaration) do |_root, compiler|
        if valid
          assert_equal currency, money_field(compiler.build.document).dig('default', 'value', 'currency')
        else
          assert_graph_error('field_default') { compiler.build }
        end
      end
    end
  end

  def test_validator_checks_scale_in_both_entity_and_contract_from_external_ir
    with_money_app('BHD') do |_root, compiler|
      original = compiler.build.document
      [['entity', 'crm.lead'], ['contract', 'crm.win_lead.input']].each do |kind, id|
        document = Vetra::Graph::Data.copy(original)
        owner = node(document, kind, id)
        if kind == 'entity'
          money_field(document)['type']['scale'] = 2
        else
          owner['fields'] << Vetra::Graph::Data.copy(money_field(document)).merge('name' => 'price')
          owner['fields'].last['type']['scale'] = 2
        end
        error = assert_graph_error('money_scale') { validate(document) }
        position = document['nodes'].index(owner)
        diagnostic = error.diagnostics.find { |item| item.code == 'money_scale' && item.pointer.start_with?("/nodes/#{position}/") }
        refute_nil diagnostic
        assert_equal owner['source'], diagnostic.source
      end
    end
  end

  def test_validator_rejects_unknown_app_currency_in_external_ir
    with_money_app('BRL') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      document['app']['currency'] = 'ZZZ'
      error = assert_graph_error('money_currency') { validate(document) }
      diagnostic = error.diagnostics.find { |item| item.code == 'money_currency' }
      assert_equal '/app/currency', diagnostic.pointer
      refute_nil diagnostic.source
    end
  end
end
