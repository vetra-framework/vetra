entity :room_membership do
  belongs_to :room
  belongs_to :user
  index :room_id, :user_id, unique: true
end
