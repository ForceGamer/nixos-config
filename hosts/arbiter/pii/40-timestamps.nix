# Parked: hiding the time of day was judged more cost (UTC date vs Oslo day,
# no time-of-day reasoning, calendar tools) than the correlation risk is
# worth for now. Uncomment the rule to enable it.
{
  name = "timestamps";
  when = null;
  rules = [
    # {
    #   # ISO 8601 timestamps: keep the date, hide the time.
    #   search = "\\b(\\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\\d|3[01]))T(?:[01]\\d|2[0-3]):[0-5]\\d:[0-5]\\d(?:\\.\\d+)?(?:Z|[+-](?:[01]\\d|2[0-3]):?[0-5]\\d)\\b";
    #   replace = "\\1[TIME]";
    # }
  ];
  examples = [ ];
}
