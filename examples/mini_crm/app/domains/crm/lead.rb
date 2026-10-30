entity :lead do
  tenant :company
  belongs_to :company
  string :name, required: true, length: 2..160
  email :email, optional: true, personal: true
  enum :status, %w[new contacted won lost], default: "new",
       groups: { closed: %w[won lost] }, guarded: { "won" => :win_lead }
  money :valor, optional: true
  crud
  index :company_id, :status
  transitions enforce: :db
end
