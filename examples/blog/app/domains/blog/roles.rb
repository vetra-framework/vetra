roles do
  role :autor do
    can :manage, on: :post, scope: :author
  end
end
