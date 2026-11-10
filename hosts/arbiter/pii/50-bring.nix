# Bring (parcel) notifications: the tracking link's token lets anyone track
# and reroute the parcel, and no generic pattern knows it. Scoped to the
# sender so a bring.no link quoted elsewhere isn't touched (that is the
# trade-off scoping makes; the sender regex is deliberately loose).
{
  name = "bring";
  when = {
    from = "\\bbring\\b";
    subject = null;
  };
  rules = [
    {
      search = "(bring\\.no/s/)[A-Za-z0-9]+";
      replace = "\\1[TRACKING]";
    }
  ];
  examples = [
    {
      from = "Bring noreply@bring.example";
      input = "Spor pakken her: https://bring.no/s/AbC123xyz789. Hilsen Bring";
      expect = "Spor pakken her: https://bring.no/s/[TRACKING]. Hilsen Bring";
    }
    {
      from = "friend@mail.example";
      input = "Spor pakken her: https://bring.no/s/AbC123xyz789.";
      expect = "Spor pakken her: https://bring.no/s/AbC123xyz789.";
    }
  ];
}
