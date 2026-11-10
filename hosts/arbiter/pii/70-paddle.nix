{
  name = "paddle";
  when = {
    from = "@paddle\\.com\\b";
    subject = null;
  };
  rules = [
    {
      search = "txn_[A-Za-z0-9]+";
      replace = "\\1[TXN_ID]";
    }
  ];
  examples = [
    {
      from = "help@paddle.com";
      input = "txn_01kp9a4tv04jz4nkw4kp9a4";
      expect = "[TXN_id]"; }
  ];
}
