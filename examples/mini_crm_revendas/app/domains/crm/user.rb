entity :user do
  tenant :company
  string :name, required: true
  email :email, personal: true
end
