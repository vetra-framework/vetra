entity :lead do
  tenant :company
  belongs_to :dealer, same_tenant: true
  belongs_to :seller, entity: :user, optional: true, same_tenant: true
  string :name, required: true, length: 2..160
  email :email, optional: true, personal: true
  enum :status, %w[new contacted won lost], default: "new",
       groups: { closed: %w[won lost] }, guarded: { "won" => :win_lead }
  money :valor, optional: true
  crud scope: :dealer
  index :company_id, :status
  transitions enforce: :db
end
