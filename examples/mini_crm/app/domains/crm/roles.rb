roles do
  role :vendedor do
    can :read, :create, :update, on: :lead
  end
  role :gerente do
    can :manage, on: :lead
    can :read, on: :company
  end
end
