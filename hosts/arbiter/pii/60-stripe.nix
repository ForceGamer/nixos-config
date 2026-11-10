# hosts/arbiter/pii/60-stripe.nix
{
  name = "stripe";
  when = {
    from = "@stripe\\.com\\b";
    subject = null;
  };   # check the real sender address
  rules = [
    {
      # Stripe receipt/invoice ids inside links, encoded or not. Keeps the path.
      search = "(invoices(?:%2F|/))[A-Za-z0-9_%-]+";
      replace = "\\1[INVOICE]";
    }
    {
      # Stripe click-tracking links wrap the receipt URL and a per-recipient
      # tracking id; neither should leave the gateway.
      search = "(https?://[a-z0-9.-]*email\\.stripe\\.com/)[^\\s\"'<>)]+";
      replace = "\\1[TRACKED_LINK]";
    }
    {
      search = "#[0-9]+-[0-9]+";
      replace = "\\1[RECEIPT_ID]";
    }
  ];
  examples = [
    { from = "receipts@stripe.com"; input = "https://58.email.stripe.com/CL0/https:%2F%2Fdashboard.stripe.com%2Freceipts%2Finvoices%2FCAcQARoX/1/0100abc"; expect = "https://58.email.stripe.com/[TRACKED_LINK]"; }
  ];
}
