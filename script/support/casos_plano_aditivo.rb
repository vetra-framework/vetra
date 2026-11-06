# frozen_string_literal: true

# Cenários de fonte compartilhados pela suíte sem banco e pela sonda. Só operam em cópias temporárias dos exemplos.
module AdditivePlanCases
  CASES = {
    tabela: 'mini_crm', schema: 'blog', coluna: 'blog', constante: 'blog', indice: 'blog', unica: 'blog',
    fk: 'blog', composta: 'mini_crm', enum: 'blog', politica: 'mini_crm_revendas', revisao: 'mini_crm', transicao: 'mini_crm', combinado: 'blog'
  }.freeze

  def self.edit(root, relative)
    path = File.join(root, relative)
    File.write(path, yield(File.read(path)))
  end

  def self.write(root, relative, text)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def self.prepare(root, name)
    if %i[fk combinado].include?(name)
      write(root, 'app/domains/blog/category.rb', "entity :category do\n  string :name\nend\n")
      edit(root, 'app/domains/blog/post.rb') { |s| s.sub('  crud', "  id :category_id, optional: true\n  crud") }
    elsif name == :revisao
      write(root, 'app/domains/crm/note.rb', "entity :note do\n  tenant :company\n  string :body\nend\n")
    elsif name == :composta
      write(root, 'app/domains/crm/category.rb', "entity :category do\n  tenant :company\n  string :code\nend\n")
      edit(root, 'app/domains/crm/lead.rb') { |s| s.sub('  crud', "  string :category_code, optional: true\n  crud") }
    end
  end

  def self.change(root, name)
    case name
    when :schema
      write(root, 'app/domains/blog/note.rb', "entity :note do\n  string :body, default: \"\"\nend\n")
    when :tabela
      write(root, 'app/domains/crm/note.rb', <<~SOURCE)
        entity :note do
          tenant :company
          belongs_to :company
          string :body, default: ""
          enum :status, %w[new done], default: "new"
          index :company_id, :body
          crud
          transitions enforce: :db
        end
      SOURCE
      edit(root, 'app/domains/crm/roles.rb') { |s| s.sub('  role :vendedor do', "  role :vendedor do\n    can :read, on: :note") }
    when :coluna
      edit(root, 'app/domains/blog/post.rb') { |s| s.sub('  crud', "  string :nota, optional: true, max: 40\n  crud") }
    when :constante
      edit(root, 'app/domains/blog/post.rb') { |s| s.sub('  crud', "  integer :score, default: 0\n  crud") }
    when :indice, :unica
      edit(root, 'app/domains/blog/post.rb') { |s| s.sub('  crud', "  index :title#{name == :unica ? ', unique: true' : ''}\n  crud") }
    when :fk
      edit(root, 'app/domains/blog/post.rb') { |s| s.sub('  id :category_id, optional: true', '  belongs_to :category, optional: true') }
    when :composta
      edit(root, 'app/domains/crm/category.rb') { |s| s.sub('  string :code', "  index :company_id, :code, unique: true\n  string :code") }
    when :enum
      edit(root, 'app/domains/blog/post.rb') { |s| s.sub('%w[draft published]', '%w[draft published archived]') }
    when :politica
      edit(root, 'app/domains/crm/roles.rb') { |s| s.gsub('on: :lead', 'on: :lead, scope: nil') }
      edit(root, 'app/domains/crm/lead.rb') { |s| s.sub('crud scope: :dealer', 'crud') }
    when :revisao
      edit(root, 'app/domains/crm/roles.rb') { |s| s.sub('  role :vendedor do', "  role :vendedor do\n    can :read, on: :note") }
    when :transicao
      edit(root, 'app/domains/crm/lead.rb') { |s| s.sub('  crud', "  timestamp :closed_at, set_by: :win_lead\n  crud") }
    when :combinado
      change(root, :constante)
      change(root, :indice)
      change(root, :unica)
      change(root, :fk)
      change(root, :enum)
    else raise "Cenário desconhecido: #{name}"
    end
  end

  def self.compile(compiler, name, changed: false)
    document = compiler.write.document
    return document unless %i[composta schema].include?(name) && changed
    document = Vetra::Graph::Data.copy(document)
    if name == :schema
      # Schema customizado também é parte da IR; o DSL atual fixa public.
      document['nodes'].find { |node| node['id'] == 'blog.note' }['storage']['schema'] = 'archive'
    else
      # A IR suporta uma chave composta alternativa; o atalho belongs_to do DSL só expõe (tenant, id).
      # Exercita aqui o consumidor da IR, sem estender o DSL nem o formato do grafo nesta tarefa.
      lead = document['nodes'].find { |node| node['id'] == 'crm.lead' }
      lead['relations'] << { 'kind' => 'belongs_to', 'name' => 'category', 'same_tenant' => true,
        'target' => { 'kind' => 'entity', 'id' => 'crm.category' },
        'local_fields' => %w[company_id category_code], 'target_fields' => %w[company_id code] }
    end
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    File.write(compiler.artifact, Vetra::Graph::Canonical.dump(document) + "\n")
    compiler.read_artifact.document
  end
end
