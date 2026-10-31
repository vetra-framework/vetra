command :add_member do
  input :room_id, :id
  input :user_id, :id, entity: :user
  returns :room
  authorize :add_member, :room, record: :room_id
  uses :rooms

  call do |input, rooms|
    room = rooms.lock!(input.room_id)
    rooms.add_member!(room.id, input.user_id)
    room
  end

  expose http: "POST /rooms/:room_id/members"
end
