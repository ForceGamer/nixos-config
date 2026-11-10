# Amounts. Global.
{
  name = "money";
  when = null;
  rules = [
    {
      # Crypto amounts: the number before a ticker, keeping the ticker.
      search = "\\b[0-9]*\\.?[0-9]+(?=\\s+(?:USDG|LTC|BTC)\\b)";
      replace = "[CRYPTO_AMOUNT]";
    }
    {
      # Money: a currency sign before the number, or kr/NOK/€ after it.
      # Spaced and dotted thousands allowed.
      search = "(?:€|\\$|£)\\s?[0-9][0-9 .,]*[0-9]|(?:€|\\$|£)[0-9]|\\b[0-9][0-9 .,]*[0-9]\\s?(?:€|kr|NOK)\\b|\\b[0-9]\\s?(?:€|kr|NOK)\\b";
      replace = "[AMOUNT]";
    }
  ];
  examples = [
    {
      input = "You sent 0.0125 BTC to";
      expect = "You sent [CRYPTO_AMOUNT] BTC to";
    }
    {
      input = "Total: $1,234.56";
      expect = "Total: [AMOUNT]";
    }
    {
      input = "Sum 1 299,00 kr";
      expect = "Sum [AMOUNT]";
    }
    {
      input = "Beløp: 450 NOK";
      expect = "Beløp: [AMOUNT]";
    }
    {
      input = "Version 2.0 of the app";
      expect = "Version 2.0 of the app";
    }
    {
      input = "100 krone notes";
      expect = "100 krone notes";
    }
  ];
}
