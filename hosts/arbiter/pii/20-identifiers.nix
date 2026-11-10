# Order, tracking, invoice and booking identifiers. Global.
#
# Every `search` is a Python regex. Nix string escaping applies: `\\b`,
# `\\d`, `\\.`, `\\$` (a bare `$` is the end-of-line anchor). Rules are
# case-insensitive unless they open with their own `(?...)` flags.
{
  name = "identifiers";
  when = null;
  rules = [
    {
      # UUIDs are always identifiers (payment ids, order-status links).
      search = "\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b";
      replace = "[UUID]";
    }
    {
      # 16–20 digit runs: parcel tracking numbers and order-line ids. Card
      # numbers of that length are hashed by the PII filter anyway.
      search = "\\b[0-9]{16,20}\\b";
      replace = "[LONG_ID]";
    }
    {
      # A label (EN/NO) followed by a 5–30 char alphanumeric token with at
      # least one digit. Keeps the label, so the model still sees that there
      # was an order number. Accepts a plural "s" (Kvitterings nr.), a verb
      # (ordrenummer er 123), and runs of #, : and markdown * in between.
      search = "\\b((?:order|ordre|ordrenr|ordrenummer|bestilling(?:snummer|snr)?|purchase order|confirmation|bekreftelse|booking|reservation|reservasjon|reference|referanse|ref|tracking|sporing(?:snummer)?|kolli(?:nummer|nr)?|invoice|faktura(?:nummer|nr)?|receipt|kvittering(?:snummer|snr)?|case|sak(?:snummer|snr)?|ticket)s?(?:\\s*(?:number|nummer|no|nr|num|id|code|kode))?\\.?(?:\\s+(?:er|is))?\\s*(?:[#:*]\\s*)*)(?!\\d{4}-\\d{2}-\\d{2}\\b)(?=[A-Z0-9-]*\\d)[A-Z0-9][A-Z0-9-]{4,29}\\b";
      replace = "\\1[ORDER]";
    }
    {
      # Customer/account numbers after a label.
      search = "\\b((?:kunde|customer|account|konto|member|medlem)s?(?:\\s*(?:number|nummer|no|nr|num|id))?\\.?\\s*(?:[#:*]\\s*)*)[0-9]{4,}\\b";
      replace = "\\1[CUSTOMER_NO]";
    }
    {
      # Numeric cells in HTML mail, e.g. order ids in a table.
      search = ">[0-9]+</div>";
      replace = ">[ORDER_ID]</div>";
    }
  ];
  examples = [
    {
      input = "Your order #123456789 has shipped";
      expect = "Your order #[ORDER] has shipped";
    }
    {
      # Both a colon and a hash between label and number (Yubico's format).
      input = "Order Number: #ORD-EU313765 Placed November 5";
      expect = "Order Number: #[ORDER] Placed November 5";
    }
    {
      input = "Ordrenummer 4471023 er bekreftet";
      expect = "Ordrenummer [ORDER] er bekreftet";
    }
    {
      # Plural s, markdown bold, verb (from the survey report).
      input = "Kvitterings nr.: 12345678 - *Ordrenummer:* 987654321 - Ditt ordrenummer er 555666777.";
      expect = "Kvitterings nr.: [ORDER] - *Ordrenummer:* [ORDER] - Ditt ordrenummer er [ORDER].";
    }
    {
      input = "Kundenummer: 123456789 Bestillingsnummer: 44556677";
      expect = "Kundenummer: [CUSTOMER_NO] Bestillingsnummer: [ORDER]";
    }
    {
      input = "Betalings id: 3f2a1b9c-7d4e-4f10-9a2b-1c3d5e7f9a0b, sporing/70712345678901234";
      expect = "Betalings id: [UUID], sporing/[LONG_ID]";
    }
    {
      input = "Tracking: JJD000123456789";
      expect = "Tracking: [ORDER]";
    }
    {
      input = "Invoice date 2026-11-09";
      expect = "Invoice date 2026-11-09";
    }
    {
      input = "In order to proceed, click here";
      expect = "In order to proceed, click here";
    }
    {
      input = "<div>Order</div><div>4471023</div>";
      expect = "<div>Order</div><div>[ORDER_ID]</div>";
    }
  ];
}
