entity :user do
  string :name, required: true
  email :email, personal: true, normalize: :downcase, unique: true
end
