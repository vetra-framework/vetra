command :add_member_by_email do
  input :room_id, :id
  input :email, :email, personal: true, normalize: :downcase
  returns :room
  authorize :add_member, :room, record: :room_id
  uses :rooms, :users_read

  call do |input, rooms, users_read|
    room = rooms.lock!(input.room_id)
    users = users_read.where(email: input.email).first(2)
    fail! :email, "não foi possível adicionar o membro" unless users.size == 1
    rooms.add_member!(room.id, users.first.id)
    room
  end
end
