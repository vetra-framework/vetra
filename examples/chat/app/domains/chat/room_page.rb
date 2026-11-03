query :room_page do
  input :room_id, :id
  returns do
    record :room, entity: :room
    collection :messages, entity: :message
  end
  authorize :read, :room, record: :room_id
  uses :rooms, :messages
  live true

  call do |input, rooms, messages|
    room = rooms.find!(input.room_id)
    { room: room, messages: messages.where(room_id: room.id).order(:created_at, :id).last(100) }
  end

  expose http: "GET /rooms/:room_id/page"
end
