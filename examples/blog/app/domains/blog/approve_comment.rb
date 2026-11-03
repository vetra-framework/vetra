command :approve_comment do
  input :comment_id, :id
  returns :comment
  authorize :update, :comment, record: :comment_id
  uses :comments

  call do |input, comments|
    comments.update!(input.comment_id, approved: true)
  end
end
