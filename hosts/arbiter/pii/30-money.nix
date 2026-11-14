# Amounts. Global.
{
  name = "money";
  when = null;
  rules = [
    {
      # Crypto amounts: the number before a ticker, keeping the ticker.
      search = "\\b[0-9]*\\.?[0-9]+(?=\\s+(?:USDG|LTC|BTC)\\b)";
      replace = "[CRYPTO_AMOUNT]";
      urls = false; # numbers in a URL are part of it, not data
    }
    {
      # Money: a currency sign or code before the number, or kr/NOK/€ after
      # it. Spaced and dotted thousands allowed. Before a trailing currency
      # the number may be glued to a word ("Total paid49 NOK" in text
      # versions of HTML mail), so only another digit may not precede it,
      # and the currency may be glued to the next label ("49 NOKVoucher").
      search = "(?:€|\\$|£)\\s?[0-9][0-9 .,]*[0-9]|(?:€|\\$|£)[0-9]|\\b(?:NOK|kr|USD|EUR)\\s?[0-9][0-9 .,]*[0-9]|\\b(?:NOK|kr|USD|EUR)\\s?[0-9]|(?<![0-9.,])[0-9][0-9 .,]*[0-9]\\s?(?:€|kr|NOK)(?:\\b|(?=(?-i:[A-Z][a-z])))|(?<![0-9.,])[0-9]\\s?(?:€|kr|NOK)(?:\\b|(?=(?-i:[A-Z][a-z])))";
      replace = "[AMOUNT]";
      urls = false; # numbers in a URL are part of it, not data
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
      # Currency code first, and an amount glued to its label.
      input = "VAT included) NOK549.00 Total paid49 NOK, kr 299 per month";
      expect = "VAT included) [AMOUNT] Total paid[AMOUNT], [AMOUNT] per month";
    }
    {
      input = "Euro 2028 tickets, USDA 2026 report";
      expect = "Euro 2028 tickets, USDA 2026 report";
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
