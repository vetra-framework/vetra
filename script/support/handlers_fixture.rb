# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# Só código de operações numa cópia temporária do mini_crm. Sem entidade, plano ou IR versionados novos.
# O comando toca a company do lead: ela não tem campo pessoal. O plano físico continua o do exemplo.
module HandlersFixture
  def with_handlers_fixture(body: nil, command_body: nil)
    Dir.mktmpdir('vetra-handlers-') do |root|
      FileUtils.cp_r("#{File.expand_path('../../examples/mini_crm', __dir__)}/.", root)
      FileUtils.rm_rf(File.join(root, '.vetra'))
      FileUtils.rm_rf(File.join(root, 'db'))
      directory = File.join(root, 'app/domains/crm')
      File.open(File.join(directory, 'events.rb'), 'a') do |file|
        file.puts 'event "crm.company.touched", from: :company, fields: %i[id]'
      end
      File.write(File.join(directory, 'touch_lead.rb'), <<~RUBY)
        command :touch_lead do
          input :lead_id, :id
          returns :company
          authorize :update, :company
          uses :leads_read, :companies
          emits "crm.company.touched", with: %i[id]

          call do |input, leads_read, companies|
            lead = leads_read.find!(input.lead_id)
            company = companies.lock!(lead.company_id)
            touched = companies.update!(company, name: "\#{company.name}+")
            #{command_body}
            touched
          end
        end
      RUBY
      %w[notify_sales notify_again].each do |name|
        File.write(File.join(directory, "#{name}.rb"), <<~RUBY)
          handler :#{name} do
            on "crm.lead.won"
            uses :mailer
            calls :touch_lead
            idempotent_by :event_id

            call do |event, mailer|
              #{body || 'call_command :touch_lead, { lead_id: event.id }; mailer.deliver :lead_won, lead_id: event.id'}
            end
          end
        RUBY
      end
      compiler = Vetra::Graph::Compiler.new(root: root)
      compiler.write
      yield compiler.link, root
    end
  end
end
