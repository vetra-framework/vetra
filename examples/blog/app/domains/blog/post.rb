entity :post do
  id :author_id, default: :current_actor
  string :title, required: true, max: 200
  enum :status, %w[draft published], default: "draft",
       guarded: { "published" => :publish_post }
  timestamp :published_at, set_by: :publish_post
  crud scope: :author
  index :status, :published_at
end
