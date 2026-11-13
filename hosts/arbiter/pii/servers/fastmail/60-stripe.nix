# Stripe receipts. The click-tracking link wraps the receipt URL and a
# per-send tracking id; the direct dashboard link carries the invoice id.
# The long tokens in dashboard.stripe.com/receipts/payment/<token> and
# pay.stripe.com/invoice/acct_…/<token>/pdf are [TOKEN] already, from the
# global links group.
# The sender is invoice+statements+acct_<id>@stripe.com, so match the domain.
{
  name = "stripe";
  when = {
    from = "@stripe\\.com\\b";
    subject = null;
  };
  rules = [
    {
      # Whole tracked link first: everything after the host identifies you.
      search = "(https?://[a-z0-9.-]*email\\.stripe\\.com/)[^\\s\"'<>)]+";
      replace = "\\1[TRACKED_LINK]";
    }
    {
      # Direct receipt link: the invoice id, encoded or not. Keeps the path.
      search = "(invoices(?:%2F|/))[A-Za-z0-9_-]+";
      replace = "\\1[INVOICE]";
    }
    {
      # Receipt number without a label; "Receipt #1234-5678" is already
      # [ORDER] from the global identifiers group. Two parts or more: some
      # merchants send #1234-5678-9012.
      search = "#[0-9]+(?:-[0-9]+)+";
      replace = "#[RECEIPT_ID]";
    }
    {
      # The merchant's Stripe account: pay.stripe.com/invoice/acct_…/[TOKEN].
      search = "(stripe\\.com/invoice/)[A-Za-z0-9_]+";
      replace = "\\1[ACCT]";
    }
  ];
  examples = [
    {
      from = "Stripe invoice+statements+acct_1ABC@stripe.com";
      input = "https://58.email.stripe.com/CL0/https:%2F%2Fdashboard.stripe.com%2Freceipts%2Finvoices%2FCAcQ-ARoX-ChVh-Y2N0%2Fpdf%3Fs=em/1/0100019a-7b3c-4d5e-8f90-1a2b3c4d5e6f-77/AbCd_eF9x=421";
      expect = "https://58.email.stripe.com/[TRACKED_LINK]";
    }
    {
      from = "Stripe invoice+statements+acct_1ABC@stripe.com";
      input = "Receipt #2026-1234 (#2026-1234): https://dashboard.stripe.com/receipts/invoices/CAcQ-ARoX-ChVh-Y2N0/pdf?s=em";
      expect = "Receipt #[ORDER] (#[RECEIPT_ID]): https://dashboard.stripe.com/receipts/invoices/[INVOICE]/pdf?s=em";
    }
    {
      from = "Shop Ltd invoice+statements+acct_1ABC@stripe.com";
      input = "Your receipt from Shop Ltd #1234-5678-9012: (https://pay.stripe.com/invoice/acct_1AbCdEfGhIjKlMnO/live_YWNjdF8xQWJDZEVmR2hJaktsTW5PLF9UYWJjZGVmZ2hpamtsbW5vcHFy0100aBcDeFgH/pdf?s=em) or https://dashboard.stripe.com/receipts/payment/CAcQARoXChVhY2N0XzFBYkNkRWZHaElqS2xNbk8o-vKmwgYyBmFiY2RlZg_x1Y2)";
      expect = "Your receipt from Shop Ltd #[RECEIPT_ID]: (https://pay.stripe.com/invoice/[ACCT]/[TOKEN]) or https://dashboard.stripe.com/receipts/payment/[TOKEN])";
    }
    {
      from = "friend@mail.example";
      input = "Paid (#2026-1234)";
      expect = "Paid (#2026-1234)";
    }
  ];
}
