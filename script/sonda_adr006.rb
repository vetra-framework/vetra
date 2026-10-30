#!/usr/bin/env ruby
# Sonda do ADR-006: mede o que o Ruby::Box do Ruby 4.0 isola e o que não isola, e como ele se comporta com
# extensões nativas. Não faz parte da suíte do compilador.
#
#   DATABASE_URL=postgres://usuario@127.0.0.1:5432/descartavel ruby script/sonda_adr006.rb
#
# Requisitos: Ruby 4.0 e a gem pg instalada. Para a verificação de extensão nativa funcionar, instale o pg
# compilado contra a libpq do sistema (`gem install pg --platform ruby`); a variante pré-compilada falha
# dentro de uma box e a sonda registra isso. O banco só é usado para um `select 1 + 1`.
require "open3"
require "rbconfig"

unless defined?(Ruby::Box) && Ruby::Box.enabled?
  abort("Ruby::Box não existe neste Ruby (precisa de 4.0 ou superior)") unless defined?(Ruby::Box)
  exec({ "RUBY_BOX" => "1" }, RbConfig.ruby, "-W:no-experimental", __FILE__, *ARGV)
end

RESULTS = []

def check(name)
  ok, detail = yield
  RESULTS << [ok, name, detail]
rescue Exception => e
  RESULTS << [false, name, "#{e.class}: #{e.message.lines.first(2).join(' ').strip[0, 200]}"]
end

def box_with(*gems)
  Ruby::Box.new.tap do |box|
    gems.each { |name| box.load_path.unshift(*Gem::Specification.find_by_name(name).full_require_paths) }
  end
end

a = Ruby::Box.new
b = Ruby::Box.new

check("monkey patch em String na box A não vaza para a principal nem para a B") do
  a.eval("class String; def vetra_sonda; :patched; end; end")
  seen = [a.eval('"x".respond_to?(:vetra_sonda)'), "x".respond_to?(:vetra_sonda), b.eval('"x".respond_to?(:vetra_sonda)')]
  [seen == [true, false, false], "A, principal, B = #{seen.inspect}"]
end
check("constante definida na box A não existe na principal") do
  a.eval("SONDA_CONSTANTE = 42")
  [a.eval("SONDA_CONSTANTE") == 42 && !Object.const_defined?(:SONDA_CONSTANTE), "principal define? #{Object.const_defined?(:SONDA_CONSTANTE)}"]
end

%w[bigdecimal prism].each do |name|
  check("extensão nativa de gem (#{name}) carrega numa box") do
    box = box_with(name)
    box.require(name)
    [true, "carregou"]
  end
end
check("extensão nativa padrão (json) carrega numa box") do
  box = Ruby::Box.new
  box.require("json")
  [box.eval("JSON.generate([1])") == "[1]", "JSON.generate([1]) => #{box.eval('JSON.generate([1])')}"]
end
check("pg carrega numa box e fala com o PostgreSQL") do
  box = box_with("pg")
  box.require("pg")
  value = box.eval(%q{PG.connect(ENV.fetch("DATABASE_URL")).exec("select 1 + 1").getvalue(0, 0)})
  [value == "2" && !Object.const_defined?(:PG), "select 1 + 1 => #{value}; PG na principal? #{Object.const_defined?(:PG)}"]
end

box = Ruby::Box.new
check("NÃO é sandbox: lê arquivos do sistema") do
  size = box.eval("File.read(#{__FILE__.inspect}).size")
  [size.positive?, "leu #{size} bytes do próprio script, fora de qualquer permissão da box"]
end
check("NÃO é sandbox: executa comandos do sistema") do
  out = box.eval("`echo vetra`").strip
  [out == "vetra", "echo => #{out}"]
end
check("NÃO é sandbox: abre conexões de rede") do
  require "uri"
  uri = URI.parse(ENV.fetch("DATABASE_URL", "postgres://127.0.0.1:5432"))
  ok = box.eval(%{require "socket"; TCPSocket.new(#{(uri.host || '127.0.0.1').inspect}, #{uri.port || 5432}).close; true})
  [ok, "conectou em #{uri.host}:#{uri.port}"]
end
check("NÃO é sandbox: enxerga o mesmo ambiente do processo") do
  ENV["VETRA_SONDA_BOX"] = "visivel"
  [box.eval('ENV["VETRA_SONDA_BOX"]') == "visivel", "ENV compartilhado"]
end
check("NÃO isola falhas: exceção na box propaga ao chamador") do
  message = begin
    box.eval('raise "falha dentro da box"')
    nil
  rescue RuntimeError => e
    e.message
  end
  [message == "falha dentro da box", "capturada fora: #{message.inspect}"]
end
check("NÃO isola falhas: exit dentro da box encerra o processo inteiro") do
  _, status = Open3.capture2e({ "RUBY_BOX" => "1" }, RbConfig.ruby, "-W:no-experimental", "-e", "Ruby::Box.new.eval('exit 7'); exit 0")
  [status.exitstatus == 7, "status do processo: #{status.exitstatus}"]
end
check("Com o modo box ligado, $? fica sem valor depois de system (Process.wait2 e Open3 funcionam)") do
  system("true")
  _, via_open3 = Open3.capture2e("false")
  [$?.inspect.include?("uninitialized") && via_open3.exitstatus == 1, "$? => #{$?.inspect}; Open3 => exit #{via_open3.exitstatus}"]
end

width = RESULTS.map { |_, name, _| name.size }.max
puts "ruby #{RUBY_VERSION} | Ruby::Box.enabled? = #{Ruby::Box.enabled?}"
RESULTS.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name.ljust(width)}  | #{detail}" }
puts RESULTS.all? { |ok, _, _| ok } ? "Resultado: todas as verificações passaram." : "Resultado: há verificações com falha."
exit(RESULTS.all? { |ok, _, _| ok } ? 0 : 1)
