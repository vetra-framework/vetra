entity :room do
  belongs_to :owner, entity: :user, default: :current_actor
  string :name, required: true, max: 80
  many_to_many :members, entity: :user, through: :room_membership, include: :owner
  crud
end
