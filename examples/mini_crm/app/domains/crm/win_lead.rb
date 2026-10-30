command :win_lead do
  input :lead_id, :id
  returns :lead
  authorize :update, :lead, record: :lead_id
  uses :leads
  emits "crm.lead.won", with: %i[id]

  call do |input, leads|
    lead = leads.lock!(input.lead_id)
    fail! :status, "lead já encerrado" if lead.closed?
    leads.update!(lead, status: "won")
  end

  expose http: "POST /leads/:lead_id/win"
end
