roles do
  authenticated do
    can :create, on: :room
    can :read, on: :room, where: { members: :current_actor }
    can :read, on: :message, where: { room: { members: :current_actor } }
    can :create, on: :message, fields: %i[room_id body], where: { room: { members: :current_actor } }
    can :delete, on: :message, where: { author: :current_actor }
  end
end
