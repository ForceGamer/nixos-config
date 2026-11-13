# Elkjøp receipts: a survey link whose parameters identify the purchase and
# the customer, a streaming voucher code (a value in itself), and 8-digit
# order numbers that start with 4 or 9, which the PII filter would otherwise
# hash as Norwegian phone numbers.
{
  name = "elkjop";
  when = {
    from = "elkj[øo]p";
    subject = null;
  };
  rules = [
    {
      search = "(netigate\\.se/[^\\s?>\"]*\\?)[^\\s>\"]+";
      replace = "\\1[SURVEY_PARAMS]";
    }
    {
      search = "(voucher=)[A-Za-z0-9]+";
      replace = "\\1[VOUCHER]";
    }
    {
      search = "(Ordrebekreftelse\\s+)[0-9]{6,10}\\b";
      replace = "\\1[ORDER]";
    }
  ];
  examples = [
    {
      from = "Elkjøp noreply@elkjop.example";
      input = "Ordrebekreftelse 41234567 https://www.netigate.se/a/s.aspx?s=1234567A9&l=123456&qid=987654321 https://viaplay.example/register/1234?voucher=aB3cD4eF5";
      expect = "Ordrebekreftelse [ORDER] https://www.netigate.se/a/s.aspx?[SURVEY_PARAMS] https://viaplay.example/register/1234?voucher=[VOUCHER]";
    }
    {
      from = "friend@mail.example";
      input = "voucher=aB3cD4eF5";
      expect = "voucher=aB3cD4eF5";
    }
  ];
}
