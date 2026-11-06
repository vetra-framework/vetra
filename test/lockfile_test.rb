require_relative 'test_helper'

# A CI instala as gems com o lockfile congelado, e o Bundler recusa uma entrada de CHECKSUMS sem hash: um lockfile
# resolvido sem rede (bundle lock --local, com a gem instalada à mão) passa localmente e quebra a CI.
class LockfileTest < Minitest::Test
  LOCKFILES = Dir[File.join(GraphTest::PROJECT, '{,examples/*/}Gemfile.lock')].sort

  def test_every_gem_in_checksums_has_a_sha256
    assert_operator LOCKFILES.size, :>=, 5
    LOCKFILES.each do |path|
      text = File.read(path)
      section = text[/^CHECKSUMS\n(.*?)(?:\n\n|\z)/m, 1]
      refute_nil section, "#{path} sem CHECKSUMS"
      # Gems de fonte PATH (o próprio vetra) não têm checksum: o Bundler as lê do diretório.
      local = text.scan(/^PATH\n.*?\n  specs:\n(.*?)(?:\n\n|\z)/m).flatten.flat_map { |specs| specs.scan(/^    (\S+) \(/).flatten }
      missing = section.lines.map(&:strip).reject(&:empty?).reject do |line|
        line.match?(/ sha256=[0-9a-f]{64}\z/) || local.include?(line[/\A\S+/])
      end
      assert_empty missing, "#{path}: gems sem checksum: #{missing.join(', ')}"
    end
  end
end
