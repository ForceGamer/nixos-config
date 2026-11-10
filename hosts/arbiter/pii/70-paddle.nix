# Paddle (payment processor) receipts: transaction ids.
{
  name = "paddle";
  when = {
    from = "@paddle\\.com\\b";
    subject = null;
  };
  rules = [
    {
      search = "\\btxn_[A-Za-z0-9]+";
      replace = "[TXN_ID]";
    }
  ];
  examples = [
    {
      from = "help@paddle.com";
      input = "Transaction txn_01kp9a4tv04jz4nkw4kp9a4 completed";
      expect = "Transaction [TXN_ID] completed";
    }
  ];
}
