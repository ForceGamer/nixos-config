# Power (electronics retailer) order mail: the order page link
# (…/orderpage/?so={NUM}&soh={HEX}&…), the PostNord return link, and the
# payment id. Order numbers after a label (also in markdown bold) and the
# UUID payment id are caught by the global identifiers group first.
{
  name = "power";
  when = {
    from = "@power\\.no\\b|\\bpower norge\\b";
    subject = null;
  };
  rules = [
    {
      search = "((?:so|soh)=)[a-z0-9]+";
      replace = "\\1[ORDER_LINK]";
    }
    {
      # my.postnord.no/return?q=<token>&reference=<order>
      search = "(postnord\\.no/return\\?q=)[A-Za-z0-9]+";
      replace = "\\1[RETURN_TOKEN]";
    }
    {
      search = "(reference=)[0-9]+";
      replace = "\\1[ORDER]";
    }
    {
      # "Betalings id: fdb6f28f" or "*Betalings id:* fdb6f28f"
      search = "(id:\\*?\\s+)[a-z0-9]+";
      replace = "\\1[PAY_ID]";
    }
  ];
  examples = [
    {
      from = "POWER Norge noreply@power.no";
      input = "http://www.power.no/orderpage/?so=1234567&soh=fdb6f28fa1&source=web";
      expect = "http://www.power.no/orderpage/?so=[ORDER_LINK]&soh=[ORDER_LINK]&source=web";
    }
    {
      from = "POWER Norge noreply@power.no";
      input = "*Ordrenummer:* 123456789 *Betalings id:* 3f2a1b9c-7d4e-4f10-9a2b-1c3d5e7f9a0b https://my.postnord.no/return?q=aBcDeF123456&reference=123456789";
      expect = "*Ordrenummer:* [ORDER] *Betalings id:* [UUID] https://my.postnord.no/return?q=[RETURN_TOKEN]&reference=[ORDER]";
    }
    {
      from = "POWER Norge noreply@power.no";
      input = "Betalings id: fdb6f28f. Levering 12. november, 2 stk.";
      expect = "Betalings id: [PAY_ID]. Levering 12. november, 2 stk.";
    }
  ];
}
