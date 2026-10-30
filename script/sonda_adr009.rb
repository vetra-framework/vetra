#!/usr/bin/env ruby
# Sonda do ADR-009: verifica, só com a biblioteca padrão, as duas premissas técnicas dos workflows duráveis:
# (1) o não-determinismo (relógio, aleatoriedade, I/O, espera, threads) pode ser bloqueado com TracePoint; e
# (2) Ruby linear em Fiber, reexecutado por replay do histórico, retoma sem repetir efeitos já registrados.
# Não é o motor de workflows, e sim a prova de viabilidade que sustenta a decisão. Fora da suíte do compilador.
#
#   ruby script/sonda_adr009.rb
RESULTS = []

def check(name)
  ok, detail = yield
  RESULTS << [ok, name, detail]
rescue Exception => e
  RESULTS << [false, name, "#{e.class}: #{e.message.lines.first&.strip}"]
end

class Nondeterminism < StandardError; end

# Rótulo do que é proibido, decidido pelo método e, quando preciso, pelo receptor. No Ruby 4.0, Time.now é
# definido em Ruby e gera :call (não :c_call), então o rastreio precisa assinar os dois eventos.
def forbidden(tp)
  owner = tp.self.is_a?(Module) ? tp.self : nil
  case tp.callee_id
  when :now then "relógio" if owner == Time
  when :clock_gettime then "relógio" if owner == Process
  when :rand, :srand then "aleatoriedade"
  when :sleep then "espera"
  when :new then "thread" if owner == Thread
  when :read, :open, :write then "I/O" if owner && owner <= IO
  end
end

def guarded
  trace = TracePoint.new(:c_call, :call) do |tp|
    label = forbidden(tp)
    raise Nondeterminism, "#{tp.callee_id} (#{label}) não é permitido no workflow" if label
  end
  trace.enable(target_thread: Thread.current) { yield }
end

{
  "Time.now" => -> { Time.now },
  "Process.clock_gettime" => -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
  "rand" => -> { rand },
  "Random.rand" => -> { Random.rand },
  "sleep" => -> { sleep 0 },
  "File.read" => -> { File.read(__FILE__) },
  "Thread.new" => -> { Thread.new {}.join }
}.each do |name, call|
  check("TracePoint bloqueia #{name} dentro do workflow") do
    message = begin
      guarded { call.call }
      nil
    rescue Nondeterminism => e
      e.message
    end
    [!message.nil?, message || "NÃO bloqueou"]
  end
end

check("o bloqueio alcança uma Fiber criada dentro do workflow, na mesma thread") do
  message = begin
    guarded { Fiber.new { Time.now }.resume }
    nil
  rescue Nondeterminism => e
    e.message
  end
  [!message.nil?, message || "NÃO bloqueou dentro da Fiber"]
end
check("fora do bloqueio, o mesmo código segue livre") do
  [Time.now.is_a?(Time) && rand.is_a?(Float), "Time.now e rand funcionam"]
end
check("só assinar :c_call deixaria Time.now passar (por isso os dois eventos)") do
  passed = true
  TracePoint.new(:c_call) { |tp| raise Nondeterminism if tp.callee_id == :now }.enable(target_thread: Thread.current) do
    Time.now
  rescue Nondeterminism
    passed = false
  end
  [passed, "Time.now #{passed ? 'não foi' : 'foi'} visto por :c_call"]
end

class Engine
  attr_reader :history, :executed

  def initialize
    @history = []
    @executed = Hash.new(0)
  end

  class Ctx
    def initialize(history)
      @history = history
      @position = 0
    end

    def activity(name, *args)
      recorded = @history[@position]
      @position += 1
      if recorded
        unless recorded[:name] == name
          raise Nondeterminism, "posição #{@position - 1}: o histórico tem #{recorded[:name]} e o código chamou #{name}"
        end
        return recorded[:result]
      end
      Fiber.yield([:run, name, args])
    end
  end

  # Reexecuta o workflow desde o início; cada passo já registrado devolve o resultado do histórico.
  def run(workflow)
    loop do
      fiber = Fiber.new { workflow.call(Ctx.new(@history)) }
      outcome = fiber.resume
      return outcome unless fiber.alive? && outcome.is_a?(Array) && outcome.first == :run

      _, name, args = outcome
      result = yield(name, args)
      @executed[name] += 1
      @history << { name: name, result: result }
    end
  end
end

workflow = ->(ctx) { charge = ctx.activity(:cobrar, 100); [charge, ctx.activity(:enviar_email, charge)] }
effects = { cobrar: ->(value) { "cobranca-#{value}" }, enviar_email: ->(id) { "email-para-#{id}" } }
perform = ->(name, args) { effects.fetch(name).call(*args) }

first = Engine.new
result = first.run(workflow, &perform)
check("o workflow linear completa e cada efeito roda uma vez") do
  [result == ["cobranca-100", "email-para-cobranca-100"] && first.executed.values.all? { |count| count == 1 }, "executados: #{first.executed}"]
end

resumed = Engine.new
resumed.history.concat(first.history.first(1))
resumed_result = resumed.run(workflow, &perform)
check("após uma queda, o replay reaproveita o histórico e não repete o passo já feito") do
  [resumed_result == result && resumed.executed[:cobrar].zero? && resumed.executed[:enviar_email] == 1, "executados na retomada: #{resumed.executed}"]
end

check("um código alterado, incompatível com o histórico, é detectado") do
  changed = ->(ctx) { id = ctx.activity(:enviar_email, 1); ctx.activity(:cobrar, id) }
  message = begin
    Engine.new.tap { |engine| engine.history.concat(first.history) }.run(changed, &perform)
    nil
  rescue Nondeterminism => e
    e.message
  end
  [!message.nil?, message || "NÃO detectou"]
end
check("uma Fiber suspensa não é serializável (por isso o replay, e não persistir Fibers)") do
  fiber = Fiber.new { Fiber.yield 1; 2 }
  fiber.resume
  message = begin
    Marshal.dump(fiber)
    nil
  rescue TypeError => e
    e.message
  end
  [!message.nil?, message || "serializou (inesperado)"]
end

width = RESULTS.map { |_, name, _| name.size }.max
puts "ruby #{RUBY_VERSION}"
RESULTS.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name.ljust(width)}  | #{detail}" }
puts RESULTS.all? { |ok, _, _| ok } ? "Resultado: todas as verificações passaram." : "Resultado: há verificações com falha."
exit(RESULTS.all? { |ok, _, _| ok } ? 0 : 1)
