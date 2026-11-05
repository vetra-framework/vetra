require_relative 'test_helper'
require_relative '../script/sonda_contexto_assinado'

class SignedContextProbeTest < GraphTest
  def test_initialization_reads_the_real_utf8_plan_without_connecting
    probe = SignedContextProbe.new('postgres://unused/unused')
    plan = probe.instance_variable_get(:@plan)
    assert_equal Encoding::UTF_8, plan.render.encoding
    assert_includes plan.render, 'Papéis Vetra ausentes ou incompatíveis'
  end

  def test_base64url_uses_no_padding_or_line_breaks_and_preserves_binary_bytes
    probe = SignedContextProbe.allocate
    assert_equal '', probe.send(:b64, '')
    assert_equal 'Zg', probe.send(:b64, 'f')
    assert_equal 'Zm8', probe.send(:b64, 'fo')
    assert_equal 'Zm9v', probe.send(:b64, 'foo')
    assert_equal '-_8', probe.send(:b64, "\xFB\xFF".b)
    bytes = Random.bytes(32)
    encoded = probe.send(:b64, bytes)
    assert_match(/\A[A-Za-z0-9_-]{43}\z/, encoded)
    assert_equal bytes, (encoded.tr('-_', '+/') + '=').unpack1('m0')
  end

  def test_connection_uses_the_effective_endpoint_without_empty_service_or_hostaddr
    admin = Struct.new(:conninfo_hash, :host, :hostaddr, :port).new(
      { service: '', servicefile: nil, host: 'first,second', hostaddr: '', user: 'postgres',
        dbname: 'postgres', options: '-c statement_timeout=1000' }, '/tmp/vetra', nil, 5432
    )
    probe = SignedContextProbe.allocate
    probe.instance_variable_set(:@admin, admin)
    assert_equal({ 'host' => '/tmp/vetra', 'port' => '5432', 'user' => 'postgres',
                   'dbname' => 'temporary', 'options' => '-c statement_timeout=1000' },
                 probe.send(:connection_params, 'temporary'))
  end
end
