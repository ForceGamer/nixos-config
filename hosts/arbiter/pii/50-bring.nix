# Bring/Posten (parcel) notifications: the tracking link's token lets anyone
# track and reroute the parcel, and no generic pattern knows it. Scoped to
# the sender so a bring.no link quoted elsewhere isn't touched (that is the
# trade-off scoping makes; the sender regex is deliberately loose).
{
  name = "bring";
  when = {
    from = "\\b(?:bring|posten)\\b";
    subject = null;
  };
  rules = [
    {
      search = "(bring\\.no/s/)[A-Za-z0-9]+";
      replace = "\\1[TRACKING]";
    }
    {
      # The global identifiers group (20) has already turned the number
      # after "Sporingsnummer" into [ORDER] by the time this group runs;
      # this only relabels it.
      search = "(sporingsnummer:?\\s+)\\[ORDER\\]";
      replace = "\\1[TRACKING]";
    }
  ];
  examples = [
    {
      from = "Bring noreply@bring.example";
      input = "Spor pakken her: https://bring.no/s/AbC123xyz789. Sporingsnummer: 70712345678901234. Hilsen Bring";
      expect = "Spor pakken her: https://bring.no/s/[TRACKING]. Sporingsnummer: [TRACKING]. Hilsen Bring";
    }
    {
      from = "friend@mail.example";
      input = "Spor pakken her: https://bring.no/s/AbC123xyz789.";
      expect = "Spor pakken her: https://bring.no/s/AbC123xyz789.";
    }
  ];
}
