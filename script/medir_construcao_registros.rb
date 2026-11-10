#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/vetra/data'

# Referência da C10, preservada para comparar sem banco e sem depender da implementação escolhida.
class StrictRowReader
  def initialize(type, fields)
    @record_type = type
    @fields = fields.to_h { |field| [field['name'], field] }.freeze
  end

  def call(row)
    values = @fields.to_h do |name, field|
      if field.dig('type', 'name') == 'money'
        amount, currency = row.values_at("#{name}_amount".to_sym, "#{name}_currency".to_sym)
        value = amount.nil? && currency.nil? ? nil : { amount: amount, currency: currency }
      else
        value = row.fetch(name.to_sym)
        if field.dig('type', 'name') == 'json'
          value = value.to_h if value.is_a?(Sequel::Postgres::JSONBHash)
          value = value.to_a if value.is_a?(Sequel::Postgres::JSONBArray)
        end
      end
      [name.to_sym, coerce(name, value)]
    end
    @record_type.new(**values)
  end

  private

  def coerce(name, value)
    Vetra::Data::Values.coerce(value, @fields.fetch(name), currency: 'BRL')
  end
end

# Protótipo sob demanda: leitores lógicos e operações de valor, sem cache mutável.
def lazy_type(fields, eager)
  type = Data.define(:_row)
  type.const_set(:FIELDS, Ractor.make_shareable(fields.to_h { |field| [field['name'].to_sym, field['type']['name']] }))
  type.const_set(:EAGER, eager)
  type.class_eval do
    def initialize(_row:)
      super(_row: Ractor.make_shareable(_row))
    end

    def read_field(name)
      kind = self.class::FIELDS.fetch(name)
      if kind == 'money'
        Vetra::Data::RowReader.money(_row.fetch("#{name}_amount".to_sym), _row.fetch("#{name}_currency".to_sym))
      else
        Vetra::Data::RowReader.convert(_row.fetch(name), kind)
      end
    rescue KeyError, ArgumentError, TypeError, NoMethodError, RangeError, EncodingError
      Vetra::Data::RowReader.invalid!
    end
    private :read_field

    def to_h = self.class::FIELDS.to_h { |name, _| [name, public_send(name)] }
    def with(**values)
      return self if values.empty?
      record = self.class::EAGER.new(**to_h.merge(values))
      row = self.class::FIELDS.each_with_object({}) do |(name, kind), result|
        value = record.public_send(name)
        if kind == 'money'
          result["#{name}_amount".to_sym] = value&.amount
          result["#{name}_currency".to_sym] = value&.currency
        else
          result[name] = value
        end
      end
      self.class.new(_row: row)
    end
    def ==(other) = other.instance_of?(self.class) && to_h == other.to_h
    def eql?(other) = other.instance_of?(self.class) && to_h.eql?(other.to_h)
    def hash = [self.class, to_h].hash
    def inspect = to_h.inspect
    def deconstruct = to_h.values
    def deconstruct_keys(keys) = keys ? to_h.slice(*keys) : to_h
    def members = self.class::FIELDS.keys
    def closed? = %w[won lost].include?(status)
  end
  fields.each do |field|
    name = field.fetch('name')
    type.class_eval("def #{name}; read_field(:#{name}); end", __FILE__, __LINE__)
  end
  type
end

def fixture(profile)
  lead = JSON.parse(File.read(File.expand_path('../examples/mini_crm_revendas/.vetra/graph.json', __dir__)))
    .fetch('nodes').find { |node| node['id'] == 'crm.lead' }.fetch('fields')
  fields = profile == :lead ? lead : [
    ['id', 'id'], ['company_id', 'id'], ['name', 'string'], ['email', 'email'], ['status', 'enum'],
    ['valor', 'money'], ['created_at', 'timestamp'], ['day', 'date'], ['tax', 'decimal'], ['payload', 'json']
  ].map do |name, kind|
    { 'name' => name, 'nullable' => false, 'type' => { 'name' => kind, 'precision' => 18, 'scale' => 2, 'values' => %w[new won lost] } }
  end
  row = { id: '00000000-0000-4000-8000-000000000001', company_id: '00000000-0000-4000-8000-000000000002',
          dealer_id: '00000000-0000-4000-8000-000000000003', seller_id: nil, name: 'Lead de medição', email: 'lead@medicao.invalid',
          status: 'new', valor_amount: BigDecimal('123.45'), valor_currency: 'BRL',
          created_at: Time.iso8601('2026-11-10T12:34:56.123456Z'), day: Date.new(2026, 11, 10),
          tax: BigDecimal('1.23'), payload: { 'nested' => ['texto', 1, true, nil, { 'value' => 1.25 }] } }
  names = fields.flat_map { |field| field.dig('type', 'name') == 'money' ? %W[#{field['name']}_amount #{field['name']}_currency] : [field['name']] }.map(&:to_sym)
  [fields, row.slice(*names)]
end

count = Integer(ENV.fetch('VETRA_REGISTROS', '10000'))
rounds = Integer(ENV.fetch('VETRA_RODADAS', '9'))
Sequel.mock(host: :postgres).extension(:pg_json)
Warning[:experimental] = false
puts "#{RUBY_DESCRIPTION}; #{count} linhas; #{rounds} rodadas; GC ligado; sem JIT: #{!RubyVM::YJIT.enabled?}"
%i[lead mixed].each do |profile|
  fields, seed = fixture(profile)
  eager = Data.define(*fields.map { |field| field['name'].to_sym }) { include Vetra::Data::Record }
  lazy = lazy_type(fields, eager)
  reader = Vetra::Data::RowReader.new(fields, eager)
  strict = StrictRowReader.new(eager, fields)
  # Acessos Ruby diretos, evitando cobrar ao lazy um laço/reflexão por campo que a aplicação não precisa usar.
  access = Module.new
  access.module_eval("def self.all(record); #{fields.map { |field| "record.#{field['name']}" }.join('; ')}; nil; end", __FILE__, __LINE__)
  # A montagem das linhas e o congelamento dos valores do piso ficam FORA da região medida.
  source = Marshal.dump(Array.new(count) { Marshal.load(Marshal.dump(seed)) })
  logical = strict.call(Marshal.load(Marshal.dump(seed))).to_h.freeze
  floor = Data.define(*logical.keys)
  assert_record = reader.call(Marshal.load(Marshal.dump(seed)))
  raise 'valores diferentes' unless assert_record.to_h == logical && Ractor.shareable?(assert_record)
  lazy_record = lazy.new(_row: Marshal.load(Marshal.dump(seed)))
  raise 'lazy inválido' unless lazy_record.to_h == logical && Ractor.shareable?(lazy_record.with) && Ractor.shareable?(lazy_record)
  raise 'lazy with inválido' unless lazy_record.with(name: 'Outro').instance_of?(lazy) && lazy_record.with == lazy_record
  raise 'lazy sem igualdade' unless lazy_record == lazy.new(_row: Marshal.load(Marshal.dump(seed)))
  raise 'lazy não atravessa Ractor' unless Ractor.new(lazy_record) { |record| record.to_h }.value == logical
  variants = {
    'a: atual' => ->(rows) { rows.map { |row| strict.call(row) } },
    'b: leitura' => ->(rows) { rows.map { |row| reader.call(row) } },
    'b: leitura + todos' => ->(rows) { rows.map { |row| reader.call(row) }.each { |record| access.all(record) } },
    'c: lazy construção' => ->(rows) { rows.map { |row| lazy.new(_row: row) } },
    'c: lazy + todos' => lambda { |rows|
      rows.map { |row| lazy.new(_row: row) }.each { |record| access.all(record) }
    },
    'c: lazy + todos 2x' => lambda { |rows|
      rows.map { |row| lazy.new(_row: row) }.each { |record| access.all(record); access.all(record) }
    },
    'piso Data.new' => ->(rows) { rows.map { floor.new(**logical) } }
  }
  results = Hash.new { |hash, key| hash[key] = [] }
  variants.each_value { |run| run.call(Marshal.load(source).first(1000)) }
  rounds.times do |round|
    variants.to_a.rotate(round).each do |label, run|
      rows = Marshal.load(source)
      GC.start
      result = nil
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run.call(rows)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began
      raise 'medição incompleta' unless result.size == count
      results[label] << elapsed * 1_000_000 / count
    end
  end
  puts "\n#{profile}: #{fields.size} campos lógicos, #{seed.size} colunas; µs/registro: mediana (mínimo–máximo)"
  results.each do |label, values|
    middle = values.sort[values.size / 2]
    puts format('%-24s %.3f (%.3f–%.3f)', label, middle, values.min, values.max)
  end
end
