require_relative 'test_helper'
require_relative '../script/sonda_autorizacao_ruby'

class AuthorizationProbeTest < GraphTest
  def setup
    @probe = RubyAuthorizationProbe.new('unused')
    @tenant, @actor, @dealer, @lead = Array.new(4) { SecureRandom.uuid }
    @document = Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples/mini_crm_revendas')).read_artifact.document
    @db = Sequel.mock(host: :postgres)
    issuer = Vetra::Data::ContextIssuer.new(kid: 'test', secret: 'x' * 32)
    @work = Vetra::Data::UnitOfWork.new(@db, limits: false, issuer: issuer)
    { tenant: @tenant, actors: { manager: @actor }, dealers: [@dealer], leads: [@lead], work: @work,
      catalog: Vetra::Data::Repositories.new(@document), engine: Vetra::Execution::Authorization.new(@document),
      revisions: { @tenant => 3 }, facts: {
        'crm.lead' => [{ id: @lead, company_id: @tenant, dealer_id: @dealer }],
        'crm.dealer' => [{ id: @dealer, company_id: @tenant }],
        'crm.membership' => [{ id: SecureRandom.uuid, company_id: @tenant, dealer_id: @dealer, user_id: @actor, role: 'gerente' }]
      } }.each { |name, value| @probe.instance_variable_set("@#{name}", value) }
  end

  def test_probe_uses_actual_evaluator_and_the_real_repository_operations_with_rollback_per_attempt
    row = { id: @lead, company_id: @tenant, dealer_id: @dealer, seller_id: nil, name: 'Cliente', email: nil,
            status: 'new', valor_amount: nil, valor_currency: nil, created_at: Time.utc(2026, 11, 10) }
    @db.fetch = ->(sql) { sql.include?('set_config') ? [] : [row] }
    @db.sqls
    RubyAuthorizationProbe::ACTIONS.each do |action|
      assert @probe.send(:ruby_decision, action, :manager, 0).allowed?
      assert @probe.send(:sql_decision, action, :manager, 0)
    end
    sqls = @db.sqls
    assert_equal 4, sqls.count { |sql| sql.start_with?('BEGIN') }
    assert_equal 4, sqls.count { |sql| sql == 'ROLLBACK' }
    refute sqls.any? { |sql| sql == 'COMMIT' }
    %w[SELECT INSERT UPDATE DELETE].each { |action| assert sqls.any? { |sql| sql.start_with?(action) } }
    @db.fetch = ->(_sql) { [] }
    refute @probe.send(:sql_decision, 'read', :manager, 0)
  end

  def test_probe_exercises_refusals_instead_of_skipping_the_independent_rls_comparison
    @db.fetch = lambda do |sql|
      raise Sequel::DatabaseError, 'segredo' if sql.start_with?('INSERT')
      []
    end
    %w[read update delete].each { |action| refute @probe.send(:sql_decision, action, :manager, 0) }
    error = assert_raises(Vetra::Data::Error) { @probe.send(:sql_decision, 'create', :manager, 0) }
    assert_equal 'data_database', error.code # Uma falha inesperada não pode virar um falso acesso negado.
    assert RubyAuthorizationProbe::SCENARIOS.key?(:mixed)
    assert RubyAuthorizationProbe::SCENARIOS.key?(:unlinked)
  end
end
