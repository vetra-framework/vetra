entity :dealer do
  tenant :company
  string :name, required: true
  has_many :memberships, entity: :membership, by: :dealer
end
