require_relative 'test_helper'
require_relative '../script/sonda_custo_contexto'
require 'minitest/mock'

class ContextCostProbeTest < GraphTest
  def test_records_measurement_runs_the_new_reader_and_reports_the_original_gate_without_a_database
    uuid = '00000000-0000-4000-8000-000000000001'
    row = { id: uuid, company_id: uuid, dealer_id: uuid, seller_id: nil, name: 'Lead', email: 'lead@medicao.invalid',
            status: 'new', valor_amount: BigDecimal('123.45'), valor_currency: 'BRL', created_at: Time.now.getutc }
    # O banco usa microssegundos; Time.now pode ter precisão maior.
    row[:created_at] = Time.at(row[:created_at].to_i, row[:created_at].usec, :microsecond).getutc
    db = Sequel.mock(host: :postgres)
    db.fetch = ->(sql) { sql.include?('set_config') ? [] : Array.new(10_000) { row.dup } }
    document = JSON.parse(File.read(File.join(PROJECT, 'examples/mini_crm_revendas/.vetra/graph.json')))
    probe = ContextCostProbe.allocate
    { runtime: db, linked: Struct.new(:document).new(document), admin: Struct.new(:server_version).new('mock'),
      issuer: Vetra::Data::ContextIssuer.new(kid: 'test', secret: SecureRandom.random_bytes(32)),
      example: 'mini_crm_revendas', report: [], detail: [], thresholds: [], results: [] }.each do |name, value|
      probe.instance_variable_set("@#{name}", value)
    end
    probe.stub(:as_superuser, nil) do
      probe.stub(:insert_leads, nil) do
        probe.stub(:script, nil) do
          probe.stub(:open_runtime, nil) do
            probe.stub(:close_runtime, nil) do
              output, = capture_io { probe.__send__(:records_gate, uuid) }
              assert_includes output, 'OK:'
            end
          end
        end
      end
    end
    assert_equal [true], probe.instance_variable_get(:@results)
    report = probe.instance_variable_get(:@report).join("\n")
    assert_includes report, 'Construção direta dos registros'
    assert_includes report, 'µs / registro'
    assert_includes report, '10%'
    assert_equal 7, probe.instance_variable_get(:@detail).size
    assert_includes probe.instance_variable_get(:@thresholds).first, 'limiar 10,000 %'
    assert_equal 14, db.sqls.count { |sql| sql.include?('FROM "public"."leads"') }
  end
end
