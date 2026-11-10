{
  name = "paddle";
  when = {
    from = "\\byubico\\b";
    subject = null;
  };
  rules = [
    {
      search = "(:?ORD|INV)(:?_|-)EU[0-9]+";
      replace = "\\1[ORDER_ID]";
    }
    {
      search = "order\\/[A-Za-z0-9]+";
      replace = "\\1[ORDER]";
    }
  ];
  examples = [
    {
      from = "noreply@yubico.com";
      input = "#ORD-EU313765";
      expect = "[ORDER_ID]"; }
  ];
}
# https://www.yubico.com/store/order/{HEX}?utm_source=invoice&utm_medium=email&utm_campaign=Check-order&utm_content=ORD-EU{NUMERIC}
