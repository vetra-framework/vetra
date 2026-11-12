require_relative 'test_helper'
require 'vetra/execution'
require 'securerandom'

# Contrato da identidade na borda pública (K23, ADR-049), sem banco: o guarda do resolvedor, a identidade anônima estável, a geração
# coerente dos papéis e a recusa do modo distribuído sem autoridade compartilhada.
class ExecutionPublicIdentityTest < GraphTest
  def self.linked(example)
    (@linked ||= {})[example] ||= Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples', example)).link
  end

  Identity = Vetra::Execution::Identity
  PublicIdentity = Vetra::Execution::PublicIdentity
  AnonymousIssuer = Vetra::Execution::AnonymousIssuer

  SECRET = 'a' * 40

  def setup
    @blog = self.class.linked('blog')
    @crm = self.class.linked('mini_crm')
    @actor = SecureRandom.uuid
    @tenant = SecureRandom.uuid
  end

  def guard(identity, linked = @blog)
    PublicIdentity.new(resolver: ->(_credentials) { identity }, linked: linked)
  end

  def refused(code, identity, linked = @blog)
    error = assert_raises(Vetra::Data::Error) { guard(identity, linked).call(:credencial) }
    assert_equal code, error.code
    error
  end

  # ---- o guarda ------------------------------------------------------------------------------------------------------------

  def test_a_declared_identity_passes_as_an_equal_canonical_copy
    identity = Identity.new(actor_id: @actor, roles: ['blog.autor'], generation: 3)
    passed = guard(identity).call(:credencial)
    assert_equal identity, passed
    refute_same identity, passed, 'o que passa adiante é uma cópia canônica, e não o objeto do resolvedor'
    crm = Identity.new(tenant_id: @tenant, actor_id: @actor, roles: ['crm.gerente'])
    assert_equal crm, guard(crm, @crm).call(:credencial)
  end

  def test_what_was_checked_is_what_is_used_even_if_the_resolver_returns_a_shifty_object
    reads = 0
    flipping = Class.new(Identity) do
      define_method(:system_actor) { (reads += 1) == 1 ? nil : 'crm.notify_sales' }
    end.new(tenant_id: @tenant, actor_id: @actor, roles: ['crm.gerente'])
    passed = guard(flipping, @crm).call(:credencial)
    assert_equal Identity, passed.class
    assert_nil passed.system_actor
    assert_nil passed.system_actor, 'e continua nil a cada leitura'

    role = +'blog.autor'
    mutable = Identity.new(actor_id: @actor, roles: [role])
    passed = guard(mutable).call(:credencial)
    role.replace('blog.admin')
    assert_equal ['blog.autor'], passed.roles, 'alterar o texto do resolvedor depois não muda a identidade conferida'
    assert passed.roles.frozen? && passed.roles.all?(&:frozen?) && passed.actor_id.frozen?
  end

  def test_a_hostile_string_or_array_subclass_cannot_swap_what_was_checked
    hostile = Class.new(String) do
      def dup = String.new('blog.admin')

      def to_s = 'blog.admin'

      def to_str = 'blog.admin'
    end
    passed = guard(Identity.new(actor_id: @actor, roles: [hostile.new('blog.autor')])).call(:credencial)
    assert_equal ['blog.autor'], passed.roles
    assert_equal String, passed.roles.first.class, 'o que passa adiante é um String nativo'

    lying_array = Class.new(Array) do
      def each = yield('blog.admin')

      def map = [String.new('blog.admin')]
    end.new(['blog.autor'])
    assert_equal ['blog.autor'], guard(Identity.new(actor_id: @actor, roles: lying_array)).call(:credencial).roles

    lying_actor = Class.new(String) { def dup = String.new(SecureRandom.uuid) }.new(@actor)
    assert_equal @actor, guard(Identity.new(actor_id: lying_actor, roles: [])).call(:credencial).actor_id

    refused('execution_identity_role', Identity.new(actor_id: @actor, roles: [hostile.new('blog.root')]))
    refused('execution_identity_tenant', Identity.new(tenant_id: 42, actor_id: @actor, roles: []))
    refused('execution_identity_actor', Identity.new(actor_id: @actor.encode('UTF-16LE'), roles: []))
    refused('execution_identity_actor', Identity.new(actor_id: @actor.dup.force_encoding('UTF-8') << "\xFF".b.force_encoding('UTF-8'), roles: []))
    refused('execution_identity_tenant', Identity.new(tenant_id: @tenant.encode('UTF-16LE'), actor_id: @actor, roles: ['crm.gerente']), @crm)
    refused('execution_identity_tenant', Identity.new(tenant_id: :secret, actor_id: @actor, roles: []))
    refused('execution_identity_role', Identity.new(actor_id: @actor, roles: ['blog.autor', nil]))
  end

  def test_an_error_raised_by_an_identity_reader_is_generic_too
    forged = Vetra::Data::Error.single('data_context', 'segredo-do-banco')
    %i[actor_id roles tenant_id system_actor generation].each do |reader|
      identity = Class.new(Identity) { define_method(reader) { raise forged } }.new(actor_id: @actor, roles: [])
      edge = Vetra::Execution::Edge.new(identity: guard(identity), facts: ->(_) {}, authority: Vetra::Execution::InProcessAuthority.new)
      error = assert_raises(Vetra::Data::Error) { edge.resolve(:credencial) }
      assert_equal 'execution_identity', error.code, "leitor #{reader}"
      refute_includes error.diagnostics.map(&:to_s).join, 'segredo'
      assert_nil error.cause
    end
    %i[nil? is_a? >= ==].each do |method|
      fake = Object.new
      fake.define_singleton_method(method) { |*| true }
      generation_liar = Class.new(Identity) { define_method(:generation) { fake } }.new(actor_id: @actor, roles: [])
      assert_equal 'execution_identity_generation', assert_raises(Vetra::Data::Error) { guard(generation_liar).call(:credencial) }.code, "generation que mente em #{method}"
      system_liar = Class.new(Identity) { define_method(:system_actor) { fake } }.new(actor_id: @actor, roles: [])
      assert_equal 'execution_identity_system', assert_raises(Vetra::Data::Error) { guard(system_liar).call(:credencial) }.code, "system_actor que mente em #{method}"
    end
    liar = Object.new
    def liar.is_a?(_) = true
    assert_equal 'execution_identity', assert_raises(Vetra::Data::Error) { guard(liar).call(:credencial) }.code, 'quem decide se é uma Identity é o módulo'
  end

  def test_an_error_raised_by_the_resolver_is_always_generic_even_if_it_forges_a_code
    ['segredo-do-resolvedor', nil].each do |message|
      forged = lambda do |_|
        raise Vetra::Data::Error.single('data_context', message || 'x')
      end
      edge = Vetra::Execution::Edge.new(identity: PublicIdentity.new(resolver: forged, linked: @blog), facts: ->(_) {}, authority: Vetra::Execution::InProcessAuthority.new)
      error = assert_raises(Vetra::Data::Error) { edge.resolve(:credencial) }
      assert_equal 'execution_identity', error.code
      refute_includes error.diagnostics.map(&:to_s).join, 'segredo'
      assert_nil error.cause
    end
    direct = Vetra::Execution::Edge.new(identity: ->(_) { raise Vetra::Data::Error.single('data_context', 'x') }, facts: ->(_) {}, authority: Vetra::Execution::InProcessAuthority.new)
    lying = Object.new
    def lying.call(_) = raise(Vetra::Data::Error.single('data_context', 'segredo-do-colaborador'))
    def lying.is_a?(_) = true
    liar_edge = Vetra::Execution::Edge.new(identity: lying, facts: ->(_) {}, authority: Vetra::Execution::InProcessAuthority.new)
    error = assert_raises(Vetra::Data::Error) { liar_edge.resolve(:credencial) }
    assert_equal 'execution_identity', error.code, 'um colaborador que mente em is_a? não é o guarda'
    refute_includes error.diagnostics.map(&:to_s).join, 'segredo'
    assert_equal 'execution_identity', assert_raises(Vetra::Data::Error) { direct.resolve(:credencial) }.code,
                 'um colaborador que não é o guarda também não faz o código atravessar'
  end

  def test_the_resolver_never_sees_more_than_the_credentials_and_its_error_does_not_cross
    seen = nil
    resolver = lambda do |credentials|
      seen = credentials
      raise 'segredo do banco'
    end
    edge = Vetra::Execution::Edge.new(identity: PublicIdentity.new(resolver: resolver, linked: @blog), facts: ->(_) {}, authority: Vetra::Execution::InProcessAuthority.new)
    error = assert_raises(Vetra::Data::Error) { edge.resolve(:credencial) }
    assert_equal :credencial, seen
    assert_equal 'execution_identity', error.code
    refute_includes error.diagnostics.map(&:to_s).join, 'segredo'
    assert_nil error.cause
  end

  def test_a_system_actor_never_enters_a_public_surface
    refused('execution_identity_system', Identity.new(tenant_id: @tenant, system_actor: 'crm.notify_sales'), @crm)
    refused('execution_identity_system', Identity.new(actor_id: @actor, roles: ['blog.autor'], system_actor: 'blog.handler'))
  end

  def test_a_non_identity_is_refused
    refused('execution_identity', { actor_id: @actor, roles: ['blog.admin'] })
    refused('execution_identity', nil)
  end

  def test_the_actor_must_be_a_lowercase_uuid_even_for_a_visitor
    refused('execution_identity_actor', Identity.new(roles: ['blog.visitor']))
    refused('execution_identity_actor', Identity.new(actor_id: 'admin', roles: ['blog.autor']))
    refused('execution_identity_actor', Identity.new(actor_id: @actor.upcase, roles: ['blog.autor']))
    refused('execution_identity_actor', Identity.new(actor_id: 42, roles: []))
  end

  def test_roles_must_be_declared_in_the_graph
    refused('execution_identity_role', Identity.new(actor_id: @actor, roles: ['blog.root']))
    refused('execution_identity_role', Identity.new(actor_id: @actor, roles: [:'blog.autor']))
    refused('execution_identity_role', Identity.new(actor_id: @actor, roles: 'blog.autor'))
    refused('execution_identity_role', Identity.new(actor_id: @actor, roles: ['crm.gerente']))
  end

  def test_the_tenant_matches_the_application
    refused('execution_identity_tenant', Identity.new(tenant_id: @tenant, actor_id: @actor, roles: ['blog.autor']))
    refused('execution_identity_tenant', Identity.new(actor_id: @actor, roles: ['crm.gerente']), @crm)
    refused('execution_identity_tenant', Identity.new(tenant_id: 'empresa', actor_id: @actor, roles: ['crm.gerente']), @crm)
  end

  def test_the_generation_is_a_non_negative_integer
    refused('execution_identity_generation', Identity.new(actor_id: @actor, roles: ['blog.autor'], generation: -1))
    refused('execution_identity_generation', Identity.new(actor_id: @actor, roles: ['blog.autor'], generation: '3'))
    assert guard(Identity.new(actor_id: @actor, roles: ['blog.autor'], generation: 0)).call(:credencial)
  end

  def test_the_guard_needs_a_callable_resolver_and_the_linked_graph
    assert_raises(Vetra::Data::Error) { PublicIdentity.new(resolver: :nope, linked: @blog) }
    assert_raises(Vetra::Data::Error) { PublicIdentity.new(resolver: ->(_) {}, linked: @blog.document) }
  end

  def test_the_error_keeps_its_code_through_the_edge_and_the_inspection_is_redacted
    edge = Vetra::Execution::Edge.new(identity: guard(Identity.new(actor_id: 'x')), facts: ->(_) {}, authority: Vetra::Execution::InProcessAuthority.new)
    error = assert_raises(Vetra::Data::Error) { edge.resolve(:credencial) }
    assert_equal 'execution_identity_actor', error.code
    refute_includes guard(nil).inspect, 'Proc'
  end

  # ---- a identidade anônima --------------------------------------------------------------------------------------------------

  def test_an_anonymous_credential_is_verified_and_its_actor_is_stable
    issuer = AnonymousIssuer.new(secret: SECRET)
    token = issuer.issue
    actor = issuer.verify(token)
    assert_match PublicIdentity::UUID, actor
    assert_equal actor, issuer.verify(token), 'a mesma credencial dá sempre o mesmo ator'
    assert_equal actor, AnonymousIssuer.new(secret: SECRET).verify(token), 'e em outro processo com o mesmo segredo'
    assert_equal 8, actor[14].to_i, 'UUID de versão 8'
    assert_includes %w[8 9 a b], actor[19]
    refute_equal actor, issuer.verify(issuer.issue), 'visitantes diferentes têm atores diferentes'
    refute_includes token, actor
  end

  def test_a_forged_or_foreign_credential_is_not_a_visitor
    issuer = AnonymousIssuer.new(secret: SECRET)
    token = issuer.issue
    prefix, nonce, mac = token.split('.')
    flipped = mac.dup
    flipped[0] = flipped[0] == 'A' ? 'B' : 'A'
    [nil, 42, '', 'a1', "#{prefix}.#{nonce}", "#{prefix}.#{nonce}.#{flipped}", "b1.#{nonce}.#{mac}", "#{prefix}.#{nonce}.#{mac}.x",
     "#{prefix}.#{'A' * 22}.#{mac}", "#{prefix}.#{nonce}.#{'A' * 43}", "#{prefix}.#{nonce}.#{mac}" + 'A' * 200, "#{prefix}.#{nonce}!.#{mac}"].each do |bad|
      assert_nil issuer.verify(bad), "não verifica: #{bad.inspect[0, 40]}"
    end
    assert_nil AnonymousIssuer.new(secret: 'b' * 40).verify(token), 'outro segredo não verifica'
    assert_nil issuer.identity('lixo', roles: ['blog.visitor'])
  end

  def test_a_credential_in_another_encoding_or_with_non_ascii_is_refused_without_raising
    issuer = AnonymousIssuer.new(secret: SECRET)
    token = issuer.issue
    [token.encode('UTF-16LE'), token.encode('UTF-32BE'), 'a1'.encode('UTF-16LE'), "#{token}é", token.dup.force_encoding('BINARY') + "\xFF".b, "\u202E#{token}"].each do |bad|
      assert_nil issuer.verify(bad)
    end
    assert_equal issuer.verify(token), issuer.verify(token.dup.force_encoding('BINARY')), 'a mesma credencial em ASCII-8BIT ainda verifica'
  end

  def test_the_anonymous_identity_passes_the_public_guard
    issuer = AnonymousIssuer.new(secret: SECRET)
    identity = issuer.identity(issuer.issue, roles: ['blog.visitor'], generation: 0)
    assert_kind_of Identity, identity
    assert_equal identity, guard(identity).call(:credencial)
  end

  def test_the_anonymous_secret_must_be_long_enough
    assert_raises(Vetra::Data::Error) { AnonymousIssuer.new(secret: 'curto') }
    error = assert_raises(Vetra::Data::Error) { AnonymousIssuer.new(secret: nil) }
    assert_equal 'execution_anonymous_secret', error.code
    refute_includes AnonymousIssuer.new(secret: SECRET).inspect, SECRET
  end

  # ---- a geração coerente dos papéis ---------------------------------------------------------------------------------------

  def runner_for(identity_generation_authority)
    catalog = Vetra::Data::Repositories.new(@blog.document)
    row = { id: SecureRandom.uuid, title: 'T', author_id: @actor, status: 'published', published_at: Time.now.utc.floor(6), created_at: Time.now.utc.floor(6) }
    rows = -> { [row] }
    make = lambda do
      Sequel.mock(host: :postgres).tap { |db| db.fetch = ->(sql) { sql.include?('set_config') ? [] : rows.call } }
    end
    facts = Vetra::Execution::DatabaseFacts.new(catalog: catalog, authority: identity_generation_authority,
                                                unit: Vetra::Data::UnitOfWork.new(make.call, scope: :global, limits: false))
    edge = Vetra::Execution::Edge.new(identity: ->(credentials) { credentials }, facts: facts, authority: identity_generation_authority)
    [Vetra::Execution::Runner.new(linked: @blog, catalog: catalog, edge: edge, unit: Vetra::Data::UnitOfWork.new(make.call, scope: :global, limits: false)), row[:id]]
  end

  def test_roles_from_a_replaced_generation_are_a_401_not_a_403
    authority = Vetra::Execution::InProcessAuthority.new
    runner, post = runner_for(authority)
    identity = Identity.new(actor_id: @actor, roles: ['blog.autor'], generation: authority.call)
    assert runner.run('blog.find_post', { post_id: post }, credentials: identity).ok?
    authority.publish!
    stale = runner.run('blog.find_post', { post_id: post }, credentials: identity)
    assert_equal :unresolved, stale.status
    assert_equal 401, stale.http_status
    assert_equal 'execution_identity_stale', stale.code
    fresh = Identity.new(actor_id: @actor, roles: ['blog.autor'], generation: authority.call)
    assert runner.run('blog.find_post', { post_id: post }, credentials: fresh).ok?
  end

  def test_an_identity_without_generation_is_not_checked_and_an_authority_that_cannot_read_it_fails_closed
    authority = Vetra::Execution::InProcessAuthority.new
    runner, post = runner_for(authority)
    authority.publish!
    assert runner.run('blog.find_post', { post_id: post }, credentials: Identity.new(actor_id: @actor, roles: ['blog.autor'])).ok?
    blind = Class.new { def call(_context = nil) = 0 }.new
    edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: ->(_) {}, authority: blind)
    refute edge.identity_current?(Identity.new(generation: 0))
    assert edge.identity_current?(Identity.new)
    broken = Class.new do
      def call(_context = nil) = 0
      def identity_generation_value(_context = nil) = raise('banco fora do ar')
    end.new
    refute Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: ->(_) {}, authority: broken).identity_current?(Identity.new(generation: 0))
  end

  def test_the_database_authority_reads_the_identity_generation_from_its_holder
    generation = Vetra::Execution::InProcessAuthority.new
    db = Sequel.mock(host: :postgres)
    db.fetch = { revision: 7 }
    authority = Vetra::Execution::DatabaseAuthority.new(db: db, identity_generation: generation)
    assert_equal 0, authority.identity_generation_value
    authority.identity_changed!
    assert_equal 1, authority.identity_generation_value
    refute authority.shared?, 'a geração em memória vale para um processo'
    shared = Class.new do
      def call(_context = nil) = 5
      def publish!(_context = nil) = 6
      def shared? = true
    end.new
    assert Vetra::Execution::DatabaseAuthority.new(db: db, identity_generation: shared).shared?
  end

  # ---- vários processos ------------------------------------------------------------------------------------------------------

  def test_several_processes_need_a_shared_authority
    local = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: ->(_) {}, authority: Vetra::Execution::InProcessAuthority.new)
    error = assert_raises(Vetra::Data::Error) { Vetra::Execution.require_shared_authority!(local) }
    assert_equal 'execution_authority_not_shared', error.code
    shared = Class.new do
      def call(_context = nil) = 0
      def shared? = true
    end.new
    assert_nil Vetra::Execution.require_shared_authority!(Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: ->(_) {}, authority: shared))
    assert_raises(Vetra::Data::Error) { Vetra::Execution.require_shared_authority!(Object.new) }
  end
end
