# Yubico store: order numbers (ORD-EU…/INV-EU…) and the order page link,
# e.g. https://www.yubico.com/store/order/{HEX}?utm_source=invoice&…&utm_content=ORD-EU{NUMERIC}
{
  name = "yubico";
  when = {
    from = "\\byubico\\b";
    subject = null;
  };
  rules = [
    {
      search = "\\b(?:ORD|INV)[-_]EU[0-9]+\\b";
      replace = "[ORDER_ID]";
    }
    {
      search = "(order/)[A-Za-z0-9]+";
      replace = "\\1[ORDER]";
    }
  ];
  examples = [
    {
      # With a label, the global identifiers group gets there first.
      from = "Yubico noreply@yubico.com";
      input = "Order Number: #ORD-EU313765 (ORD-EU313765 shipped)";
      expect = "Order Number: #[ORDER] ([ORDER_ID] shipped)";
    }
    {
      from = "Yubico noreply@yubico.com";
      input = "https://www.yubico.com/store/order/a1b2c3d4?utm_source=invoice&utm_content=ORD-EU313765";
      expect = "https://www.yubico.com/store/order/[ORDER]?utm_source=invoice&utm_content=[ORDER_ID]";
    }
  ];
}
