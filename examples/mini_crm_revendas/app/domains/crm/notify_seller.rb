handler :notify_seller do
  on "crm.lead.won"
  uses :mailer
  idempotent_by :event_id

  call do |event, mailer|
    next unless event.seller_id

    mailer.deliver :lead_won, to: event.seller_id, lead_id: event.id
  end
end
