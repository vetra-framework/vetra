query :find_post do
  input :post_id, :id
  returns :post
  authorize :read, :post, record: :post_id
  uses :posts

  call do |input, posts|
    posts.find!(input.post_id)
  end
end
