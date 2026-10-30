entity :message do
  belongs_to :room
  belongs_to :author, entity: :user, default: :current_actor
  text :body, required: true, max: 4_000
  crud
  index :room_id
end
