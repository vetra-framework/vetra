entity :membership do
  tenant :company
  belongs_to :user, same_tenant: true
  belongs_to :dealer, same_tenant: true
  enum :role, %w[vendedor gerente]
  memberships of: :dealer, actor: :user, role: :role
  index :company_id, :user_id, :dealer_id, :role, unique: true
end
