effect :mailer do
  adapter "app.mailer"
  idempotency_key true
  retry_safe true
  simulate :memory
  timeout 5
end
