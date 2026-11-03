query :my_rooms do
  returns :room, collection: true
  authorize :read, :room
  uses :rooms

  call do |_input, rooms|
    rooms.order(:name).all
  end

  expose http: "GET /rooms"
end
