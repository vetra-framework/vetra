roles do
  role :autor do
    can :manage, on: :post, scope: :author
  end

  visitor do
    can :read, on: :post, where: { status: "published" }
    can :read, on: :comment, where: { approved: true }
    can :create, on: :comment, fields: %i[post_id author_name author_email body],
        rate_limit: "5/min"
  end

  role :admin do
    can :manage, on: %i[post comment]
  end
end
