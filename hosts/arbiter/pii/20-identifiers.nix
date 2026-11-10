# Order, tracking, invoice and booking identifiers. Global for now; the HTML
# cell rule is a candidate for a sender scope once the merchant is known.
#
# Every `search` is a Python regex. Nix string escaping applies: `\\b`,
# `\\d`, `\\.`, `\\$` (a bare `$` is the end-of-line anchor). Rules are
# case-insensitive unless they open with their own `(?...)` flags.
{
  name = "identifiers";
  when = null;
  rules = [
    {
      # A label (EN/NO) followed by a 5–30 char alphanumeric token with at
      # least one digit. Keeps the label, so the model still sees that there
      # was an order number.
      search = "\\b((?:order|ordre|ordrenr|ordrenummer|bestilling(?:snummer|snr)?|purchase order|confirmation|bekreftelse|booking|reservation|reservasjon|reference|referanse|ref|tracking|sporing(?:snummer)?|kolli(?:nummer|nr)?|invoice|faktura(?:nummer|nr)?|receipt|kvittering(?:snummer|snr)?|case|sak(?:snummer|snr)?|ticket)(?:\\s*(?:number|nummer|no|nr|num|id|code|kode))?\\.?\\s*[#:]?\\s*)(?!\\d{4}-\\d{2}-\\d{2}\\b)(?=[A-Z0-9-]*\\d)[A-Z0-9][A-Z0-9-]{4,29}\\b";
      replace = "\\1[ORDER]";
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
      input = "Ordrenummer 4471023 er bekreftet";
      expect = "Ordrenummer [ORDER] er bekreftet";
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
