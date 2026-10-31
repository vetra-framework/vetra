command :remove_member do
  input :room_id, :id
  input :user_id, :id, entity: :user
  returns :room
  authorize :remove_member, :room, record: :room_id
  uses :rooms

  call do |input, rooms|
    room = rooms.lock!(input.room_id)
    fail! :user_id, "o dono da sala não pode ser removido" if room.owner_id == input.user_id
    rooms.remove_member!(room.id, input.user_id)
    room
  end

  expose http: "DELETE /rooms/:room_id/members/:user_id"
end
