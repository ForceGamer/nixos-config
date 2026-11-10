{
  name = "power";
  when = {
    from = "@power\\.no\\b";
    subject = null;
  };
  rules = [
    {
      search = "(\\s+)[0-9]+";
      replace = "\\1[ORDER_ID]";
    }
    { #http://www.power.no/orderpage/?so={NUM}&soh={HEX}&source=web&utm_source=transactional&utm_medium=email&utm_campaign=bring-ondoor-delivery&utm_content=image
      search = "(:?so=|soh=)[a-z0-9]+";
      replace = "\\1[ORDER_LINK]";
    }
    { #Betalings id: fdb6f28f
      search = "(id:\\s+)[a-z0-9]+";
      replace = "\\1[PAY_ID]";
    }
  ];
  examples = [
    {
      from = "help@paddle.com";
      input = "txn_01kp9a4tv04jz4nkw4kp9a4";
      expect = "[TXN_id]"; }
  ];
}
