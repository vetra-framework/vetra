entity :comment do
  belongs_to :post
  string :author_name, required: true, max: 80
  email :author_email, required: true, personal: true
  text :body, required: true, max: 2_000
  boolean :approved, default: false, set_by: :approve_comment
  crud
end
