# CS MEGASTORE / ComputerSalg order mail. Their reference code (letter,
# digit, letter, nine digits) sits in every subject next to the order number,
# unlabelled; the order number also appears bare in "(12345678 / a1B…)".
# UUID order-status links and 18-digit Bring tracking numbers are already
# caught by the global identifiers group.
{
  name = "csmegastore";
  when = {
    from = "csmegastore|computersalg|cs megastore";
    subject = null;
  };
  rules = [
    {
      search = "\\b[a-z][0-9][a-z][0-9]{9}\\b";
      replace = "[CS_REF]";
    }
    {
      # "(12345678 / [CS_REF])" after the shop name in the subject.
      search = "(\\()[0-9]{6,10}( / \\[CS_REF\\])";
      replace = "\\1[ORDER]\\2";
    }
    {
      search = "(Bring-Id:\\s*)[0-9]+";
      replace = "\\1[TRACKING]";
    }
  ];
  examples = [
    {
      from = "CS MEGASTORE AS noreply@csmegastore.example";
      input = "Bestillingsoversikt fra CS MEGASTORE AS (12345678 / a1B234567890) Bring-Id: 123456 orderstatus/3f2a1b9c-7d4e-4f10-9a2b-1c3d5e7f9a0b";
      expect = "Bestillingsoversikt fra CS MEGASTORE AS ([ORDER] / [CS_REF]) Bring-Id: [TRACKING] orderstatus/[UUID]";
    }
    {
      from = "CS MEGASTORE AS noreply@csmegastore.example";
      input = "Oppfølgingsmail fra ComputerSalg AS (Fakturanr.: 12345678 - a1B234567890)";
      expect = "Oppfølgingsmail fra ComputerSalg AS (Fakturanr.: [ORDER] - [CS_REF])";
    }
    {
      from = "friend@mail.example";
      input = "code a1B234567890";
      expect = "code a1B234567890";
    }
  ];
}
