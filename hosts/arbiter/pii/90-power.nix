# Power (electronics retailer) order mail: the order page link
# (…/orderpage/?so={NUM}&soh={HEX}&…) and the payment id. Order numbers
# after a label are already caught by the global identifiers group.
{
  name = "power";
  when = {
    from = "@power\\.no\\b";
    subject = null;
  };
  rules = [
    {
      search = "((?:so|soh)=)[a-z0-9]+";
      replace = "\\1[ORDER_LINK]";
    }
    {
      # "Betalings id: fdb6f28f"
      search = "(id:\\s+)[a-z0-9]+";
      replace = "\\1[PAY_ID]";
    }
  ];
  examples = [
    {
      from = "Power noreply@power.no";
      input = "http://www.power.no/orderpage/?so=1234567&soh=fdb6f28fa1&source=web";
      expect = "http://www.power.no/orderpage/?so=[ORDER_LINK]&soh=[ORDER_LINK]&source=web";
    }
    {
      from = "Power noreply@power.no";
      input = "Betalings id: fdb6f28f. Levering 12. november, 2 stk.";
      expect = "Betalings id: [PAY_ID]. Levering 12. november, 2 stk.";
    }
  ];
}
