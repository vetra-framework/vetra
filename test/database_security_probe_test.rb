require_relative 'test_helper'
require_relative '../script/sonda_rls_integridade'

class DatabaseSecurityProbeTest < GraphTest
  def test_probe_reads_both_real_plans_and_compiles_set_by_fixture_without_connecting
    probe = DatabaseSecurityProbe.new('postgres://unused/unused')
    %w[mini_crm mini_crm_revendas mini_crm_set_by].each do |example|
      probe.send(:prepare_plan, example)
      sql = probe.instance_variable_get(:@plan).render
      assert_includes sql, 'AS RESTRICTIVE'
      assert_includes sql, 'CREATE TABLE "vetra"."authz_revisions"'
      assert_includes sql, 'BEFORE INSERT OR UPDATE'
      assert_equal Encoding::UTF_8, sql.encoding
      if example == 'mini_crm_set_by'
        assert_includes sql, 'ROW(NEW."approved") IS DISTINCT FROM ROW(FALSE)'
        assert_includes sql, 'ROW(NEW."email") IS DISTINCT FROM ROW(NULL)'
      end
    end
  end
end
