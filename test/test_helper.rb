require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "vetra"
require "vetra/cli"

class GraphTest < Minitest::Test
  PROJECT = File.expand_path('..', __dir__)

  def with_app(name = 'blog')
    Dir.mktmpdir('vetra-test-') do |directory|
      FileUtils.cp_r("#{PROJECT}/examples/#{name}/.", directory)
      FileUtils.rm_rf(File.join(directory, '.vetra'))
      yield directory, Vetra::Graph::Compiler.new(root: directory)
    end
  end

  def edit(root, path)
    file = File.join(root, path)
    File.write(file, yield(File.read(file)))
  end

  def write(root, path, text)
    file = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, text)
  end

  def node(document, kind, id = nil)
    document.fetch('nodes').find { |entry| entry['kind'] == kind && (!id || entry['id'] == id) } || raise('Nó não encontrado')
  end

  # As fixtures de formatos anteriores representam o blog antes do recurso da IR 0.6.
  def omit_blog_rate_limit(root)
    edit(root, 'app/domains/blog/roles.rb') { |text| text.gsub(/,\s*rate_limit: "[^"]*"/, '') }
  end

  def assert_graph_error(code)
    error = assert_raises(Vetra::Graph::Error) { yield }
    assert_includes error.diagnostics.map(&:code), code, error.message
    error
  end
end
