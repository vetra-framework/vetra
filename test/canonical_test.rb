require_relative 'test_helper'

class CanonicalTest < GraphTest
  Canonical = Vetra::Graph::Canonical

  def test_rfc8785_utf16_key_order_and_escaping
    input = { '€' => 1, "\r" => 2, 'דּ' => 3, '😀' => 4, "\u0080" => 5, 'ö' => 6, '1' => 7 }
    expected = "{\"\\r\":2,\"1\":7,\"\u0080\":5,\"ö\":6,\"€\":1,\"😀\":4,\"דּ\":3}"
    assert_equal expected, Canonical.dump(input)
    escaped = <<~'JSON'.chomp
      "a\n\t\u000f\"\\/"
    JSON
    assert_equal escaped, Canonical.dump("a\n\t\u000f\"\\/")
  end

  def test_float_and_non_json_data_are_rejected
    [1.0, Float::NAN, (2**53), :symbol, Object.new, proc {}].each do |value|
      assert_graph_error('invalid_data') { Canonical.dump({ 'value' => value }) }
    end
    assert_graph_error('invalid_data') { Canonical.dump({ symbol: true }) }
  end

  def test_parser_refuses_duplicate_keys_and_invalid_json
    ['{"x":1,"x":2}', '{"x":{"y":1,"y":2}}', '{"x":NaN}', '{"x":"\\ud800"}', 'null trailing'].each do |bytes|
      assert_graph_error('invalid_json') { Canonical.parse(bytes) }
    end
  end

  def test_documental_fixture_hashes_match_independent_jcs_vectors
    Dir[File.join(PROJECT, 'docs/ir/exemplos/*.json')].each do |path|
      document = Canonical.parse(File.read(path))
      assert_equal document['digest'], Canonical.digest(document)
      assert_empty Vetra::Graph::Validator.new.validate!(document).reject { |warning| warning.code == 'entity_no_policy' }
    end
  end

  def test_digest_excludes_only_root_digest_and_preserves_array_order
    document = { 'digest' => 'old', 'nested' => { 'digest' => 'kept' }, 'keys' => %w[b a] }
    expected = Canonical.digest(document)
    document['digest'] = 'new'
    assert_equal expected, Canonical.digest(document)
    document['keys'].reverse!
    refute_equal expected, Canonical.digest(document)
    document['keys'].reverse!
    document['nested']['digest'] = 'different'
    refute_equal expected, Canonical.digest(document)
  end
end
