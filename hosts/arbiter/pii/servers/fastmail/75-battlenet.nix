# Battle.net (Blizzard) order mail. The text version runs table cells
# together ("Customer Name<first> <last>Invoice Number<digits>Order Status…"),
# so the whole-word name secrets in the people group can't fire on the
# customer name; the two labels around it can. The invoice number is caught
# by the global identifiers group once that tolerates a glued label, and the
# order number in the subject is hashed by the PII filter.
{
  name = "battlenet";
  when = {
    from = "battle\\.net|blizzard";
    subject = null;
  };
  rules = [
    {
      # Whatever sits between the two labels is the name. Bounded, and
      # across line breaks, so another layout of the same table still works
      # and a missing "Invoice" can't swallow the mail.
      search = "(Customer Name)[\\s\\S]{1,80}?(Invoice)";
      replace = "\\1 [NAME] \\2";
    }
    {
      # BattleTag: 3–12 characters, not starting with a digit, "#", digits.
      search = "(?<![\\w#])(?!\\d)\\w{3,12}#[0-9]{4,6}\\b";
      replace = "[BATTLETAG]";
    }
    {
      # account.battle.net/transactions/<id>/…
      search = "(account\\.battle\\.net/[a-z-]+/)[A-Z0-9]+";
      replace = "\\1[TXN_ID]";
    }
    {
      # "Total charged to MasterCard (…)": the report cuts off inside the
      # parentheses, so take whatever they hold (card digits, presumably).
      search = "(Total charged to [^()\\n]{1,40}\\()[^()\\n]{1,40}(\\))";
      replace = "\\1[CARD]\\2";
    }
  ];
  examples = [
    {
      from = "Battle.net noreply@battle.example";
      input = "Hello! If *Wizard#12345* isn’t your account name, don’t click. Customer NameAda  LovelaceInvoice Number1234567890Order StatusComplete";
      expect = "Hello! If *[BATTLETAG]* isn’t your account name, don’t click. Customer Name [NAME] Invoice Number[ORDER] StatusComplete";
    }
    {
      from = "Battle.net noreply@battle.example";
      input = "Total (Any applicable VAT included) NOK549.00 Total charged to MasterCard (1234) <https://account.battle.net/transactions/EU1234567890/abc>";
      expect = "Total (Any applicable VAT included) [AMOUNT] Total charged to MasterCard ([CARD]) <https://account.battle.net/transactions/[TXN_ID]/abc>";
    }
    {
      from = "friend@mail.example";
      input = "Add me: Wizard#12345. Customer Name Ada Lovelace Invoiced";
      expect = "Add me: Wizard#12345. Customer Name Ada Lovelace Invoiced";
    }
  ];
}
