require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

Rake::TestTask.new('test:diagnostics') do |task|
  task.description = 'Executa a suíte e exige cobertura dos códigos de diagnóstico'
  task.libs << 'test'
  task.pattern = 'test/**/*_test.rb'
  task.warning = true
  task.ruby_opts << '-r./test/support/diagnostic_coverage_runner'
end

task default: 'test:diagnostics'
