command :publish_post do
  input :post_id, :id
  returns :post
  authorize :update, :post, record: :post_id
  uses :posts, :clock
  emits "blog.post.published", with: %i[id]

  call do |input, posts, clock|
    post = posts.lock!(input.post_id)
    fail! :status, "só rascunhos podem ser publicados" unless post.status == "draft"
    posts.update!(post, status: "published", published_at: clock.now)
  end

  expose http: "POST /posts/:post_id/publish"
end
