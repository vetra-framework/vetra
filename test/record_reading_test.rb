require_relative 'test_helper'
require 'vetra/data'
require 'minitest/mock'

class RecordReadingTest < GraphTest
  UUID = '00000000-0000-4000-8000-000000000001'.freeze

  def setup
    @db = Sequel.mock(host: :postgres)
    @work = Vetra::Data::UnitOfWork.new(@db, limits: false, scope: :global)
    @claims = { actor_id: UUID, op_id: UUID, cmd: 'blog.create_post' }
  end

  # Referência do caminho da C10, anterior ao ADR-042; não usa o novo leitor.
  def strict_record(type, fields, row)
    values = fields.to_h do |field|
      name = field.fetch('name')
      if field.dig('type', 'name') == 'money'
        amount, currency = row.values_at("#{name}_amount".to_sym, "#{name}_currency".to_sym)
        value = amount.nil? && currency.nil? ? nil : { amount: amount, currency: currency }
      else
        value = row.fetch(name.to_sym)
        value = value.to_h if value.is_a?(Sequel::Postgres::JSONBHash)
        value = value.to_a if value.is_a?(Sequel::Postgres::JSONBArray)
      end
      [name.to_sym, Vetra::Data::Values.coerce(value, field, currency: 'BRL')]
    end
    type.new(**values)
  end

  def row_for(fields, nulls: false)
    fields.each_with_object({}) do |field, row|
      name, kind = field.fetch('name'), field.dig('type', 'name')
      value = case kind
      when 'id' then UUID.dup
      when 'enum' then field.dig('type', 'values').first.dup
      when 'boolean' then false
      when 'integer' then 2**63 - 1
      when 'timestamp' then Time.iso8601('2026-11-10T09:34:56.123456-03:00')
      when 'date' then Date.new(2026, 11, 10)
      when 'decimal' then BigDecimal('1.23')
      when 'json' then Sequel.pg_jsonb({ 'nested' => [+'texto', 1, false, nil, { 'f' => 1.25 }] })
      else +'valor de leitura'
      end
      value = nil if nulls && field['nullable']
      if kind == 'money'
        row["#{name}_amount".to_sym] = nulls && field['nullable'] ? nil : BigDecimal('123.45')
        row["#{name}_currency".to_sym] = nulls && field['nullable'] ? nil : +'BRL'
      else
        row[name.to_sym] = value
      end
    end
  end

  def assert_equivalent(type, fields, row, actual)
    expected = strict_record(type, fields, row)
    assert_equal expected, actual
    assert expected.eql?(actual)
    assert_equal expected.hash, actual.hash
    assert_equal expected.inspect, actual.inspect
    assert_equal expected.to_h, actual.to_h
    assert_equal expected.deconstruct, actual.deconstruct
    assert_equal expected.deconstruct_keys(nil), actual.deconstruct_keys(nil)
    assert_equal expected.members, actual.members
    assert actual.frozen?
    assert Ractor.shareable?(actual)
    assert_equal actual, actual.with
    assert Ractor.shareable?(actual.with)
    fields.each do |field|
      name = field.fetch('name')
      before, after = expected.public_send(name), actual.public_send(name)
      assert_instance_of before.class, after
      assert after.frozen?
      assert Ractor.shareable?(after)
      refute_respond_to actual, "#{name}="
    end
    %i[save save! update! delete! destroy! []=].each { |method| refute_respond_to actual, method }
  end

  def test_every_field_of_all_four_examples_matches_the_strict_path_including_nullable_values
    %w[blog chat mini_crm mini_crm_revendas].each do |example|
      document = JSON.parse(File.read(File.join(PROJECT, 'examples', example, '.vetra/graph.json')))
      catalog = Vetra::Data::Repositories.new(document)
      document['nodes'].select { |node| node['kind'] == 'entity' }.each do |entity|
        fields = entity.fetch('fields')
        capability = document['nodes'].find { |node| node.dig('config', 'entity', 'id') == entity['id'] }
        repository = catalog.bind(capability['id'], unit: @work)
        [false, true].each do |nulls|
          row = row_for(fields, nulls: nulls)
          record = repository.__send__(:read_record!, row)
          assert_equivalent(catalog.record_type(entity['id']), fields, row, record)
          groups = fields.flat_map { |field| field.dig('type', 'groups')&.keys || [] }.uniq
          groups.each do |group|
            expected = strict_record(record.class, fields, row)
            assert_equal expected.public_send("#{group}?"), record.public_send("#{group}?")
          end
        end
      end
    end
  end

  def extra_fields
    %w[integer date timestamp decimal json money].map do |kind|
      { 'name' => kind, 'nullable' => true, 'type' => { 'name' => kind, 'precision' => 18, 'scale' => 2 } }
    end
  end

  def test_additional_types_match_the_old_path_and_reuse_values_already_immutable
    fields = extra_fields
    type = ::Data.define(*fields.map { |field| field['name'].to_sym }) { include Vetra::Data::Record }
    reader = Vetra::Data::RowReader.new(fields, type)
    row = row_for(fields)
    record = reader.call(row)
    assert_equivalent(type, fields, row, record)
    assert_same row[:decimal], record.decimal
    assert_same row[:money_amount], record.money.amount
    assert_same row[:money_currency], record.money.currency
    assert record.timestamp.utc?
    assert_equal(-10_800, row[:timestamp].utc_offset)
    assert_equal Encoding::UTF_8, record.money.currency.encoding
    assert_instance_of Hash, record.json
    assert_raises(FrozenError) { record.json['nested'].first.replace('outro') }
    assert_raises(FrozenError) { record.json['nested'] << 'outro' }
    changed = record.with(json: { 'new' => [+'texto'] })
    assert Ractor.shareable?(changed)
    assert_equivalent(type, fields, row_for(fields, nulls: true), reader.call(row_for(fields, nulls: true)))
    [Sequel.pg_jsonb(['texto', { 'k' => ['v'] }]), 'texto', 42, 1.25, true, false].each do |json|
      row = row_for(fields).merge(json: json)
      assert_equivalent(type, fields, row, reader.call(row))
    end
  end

  def test_reader_transcodes_text_and_preserves_public_construction_and_with_copying
    field = { 'name' => 'text', 'type' => { 'name' => 'text' }, 'nullable' => false }
    type = ::Data.define(:text) { include Vetra::Data::Record }
    reader = Vetra::Data::RowReader.new([field], type)
    row = { text: 'ação'.encode('ISO-8859-1') }
    record = reader.call(row)
    assert_equivalent(type, [field], row, record)
    assert_equal Encoding::UTF_8, record.text.encoding
    text = +'Outra'
    changed = record.with(text: text)
    built = type.new(text: text)
    text.replace('alterada')
    assert_equal 'Outra', changed.text
    assert_equal 'Outra', built.text
    assert_raises(ArgumentError) { record.with(unknown: 1) }
    assert_raises(NoMethodError) { record.unknown }
  end

  def test_database_read_does_not_call_input_validation_or_the_public_copying_constructor
    fields = extra_fields
    type = ::Data.define(*fields.map { |field| field['name'].to_sym }) { include Vetra::Data::Record }
    reader = Vetra::Data::RowReader.new(fields, type)
    row = row_for(fields)
    forbidden = ->(*) { flunk 'A leitura repetiu a validação/cópia da entrada.' }
    Vetra::Data::Values.stub(:coerce, forbidden) do
      Vetra::Data::Values.stub(:immutable, forbidden) do
        assert Ractor.shareable?(reader.call(row))
      end
    end
  end

  def test_corrupt_rows_and_residual_invariants_are_refused_during_construction_without_values_or_cause
    fields = extra_fields
    type = ::Data.define(*fields.map { |field| field['name'].to_sym }) { include Vetra::Data::Record }
    reader = Vetra::Data::RowReader.new(fields, type)
    bad_rows = [
      row_for(fields).except(:date), row_for(fields).merge(timestamp: 'SEGREDO: driver não devolveu Time'),
      row_for(fields).merge(date: Date.new(10000, 1, 1)), row_for(fields).merge(date: Date.new(0, 1, 1)),
      row_for(fields).merge(timestamp: Time.utc(10000)), row_for(fields).merge(timestamp: Time.utc(0)),
      row_for(fields).merge(timestamp: Time.at(1, 1, :nanosecond)),
      row_for(fields).merge(date: Float::INFINITY), row_for(fields).merge(json: { 'x' => Float::INFINITY }),
      row_for(fields).merge(json: Object.new), row_for(fields).merge(integer: Object.new),
      row_for(fields).merge(money_currency: nil), row_for(fields).merge(money_amount: nil),
      row_for(fields).merge(money_currency: "\xFF".b.force_encoding('US-ASCII'))
    ]
    bad_rows.each do |row|
      error = assert_graph_error('data_read_value') { reader.call(row) }
      assert_equal 'Linha do banco incompatível com o registro.', error.diagnostics.first.message
      assert_nil error.cause
      refute_includes error.full_message, 'SEGREDO'
    end
  end

  def test_date_and_timestamp_boundaries_remain_accepted
    fields = extra_fields
    type = ::Data.define(*fields.map { |field| field['name'].to_sym }) { include Vetra::Data::Record }
    reader = Vetra::Data::RowReader.new(fields, type)
    [1, 9999].each do |year|
      row = row_for(fields).merge(date: Date.new(year, 1, 1), timestamp: Time.utc(year))
      assert_equivalent(type, fields, row, reader.call(row))
    end
  end

  def test_strict_inputs_for_create_update_and_equalities_still_fail_before_sql
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/post.rb') do |source|
        source.sub('  crud', <<~RUBY.chomp)
          integer :counter, default: 0
          decimal :tax, precision: 6, scale: 2, optional: true
          date :day, optional: true
          json :payload, optional: true
          money :price, optional: true
          crud
        RUBY
      end
      catalog = Vetra::Data::Repositories.new(compiler.build.document)
      posts = catalog.bind('blog.posts', unit: @work)
      invalid = { title: [nil, 42], status: ['unknown'], counter: [2**63, '1'], tax: ['1.234', '10000.00', 1.23],
                  day: [Date.new(10000), 'não é data'], payload: [{ symbol: 'x' }, Float::INFINITY],
                  price: [{ amount: 1.23 }, { amount: '1.234' }, { amount: '1', currency: 'XXX' }],
                  published_at: ['2026-11-10T12:00:00', Time.at(1, 1, :nanosecond)] }
      @work.transaction(**@claims) do
        @db.sqls
        invalid.each do |name, values|
          values.each do |value|
            assert_graph_error('data_value') { posts.create!(**{ title: 'Post', name => value }) }
            assert_graph_error('data_value') { posts.update!(UUID, **{ name => value }) }
            assert_graph_error('data_value') { posts.where(**{ name => value }).all }
          end
        end
        assert_empty @db.sqls
      end
    end
  end

  def test_reading_fields_with_and_predicates_in_another_ractor
    document = JSON.parse(File.read(File.join(PROJECT, 'examples/mini_crm/.vetra/graph.json')))
    catalog = Vetra::Data::Repositories.new(document)
    fields = node(document, 'entity', 'crm.lead').fetch('fields')
    record = Vetra::Data::RowReader.new(fields, catalog.record_type('crm.lead')).call(row_for(fields))
    before = Warning[:experimental]
    Warning[:experimental] = false
    result = Ractor.new(record) do |lead|
      changed = lead.with(name: 'Outro', status: 'won')
      [lead, lead.to_h, changed.closed?, changed.name, Ractor.shareable?(changed)]
    end.value
    assert_same record, result[0]
    assert_equal record.to_h, result[1]
    assert_equal [true, 'Outro', true], result.drop(2)
  ensure
    Warning[:experimental] = before
  end
end
