roles scope: :dealer do
  role :vendedor do
    can :read, :create, :update, on: :lead
    can :read, on: :dealer
  end
  role :gerente do
    can :manage, on: :lead
    can :read, on: :dealer
    can :read, on: %i[company user membership], scope: nil
  end
end
