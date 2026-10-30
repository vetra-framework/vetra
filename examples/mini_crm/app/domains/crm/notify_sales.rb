handler :notify_sales do
  on "crm.lead.won"
  uses :mailer
  idempotent_by :event_id

  call do |event, mailer|
    mailer.deliver :lead_won, lead_id: event.id
  end
end
