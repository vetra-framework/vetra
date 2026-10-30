entity :user do
  string :name, required: true
  email :email, personal: true
end
