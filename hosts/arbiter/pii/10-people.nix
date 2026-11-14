# People and places: always applied, to every tool result and prompt.
#
# Rules run in list order, each on the output of the previous one, so a value
# that contains another must come first. Otherwise the shorter rule fires
# first and the longer one never matches, leaving the rest visible. Hence:
# address, then e-mail addresses (they contain names and domains), domains,
# organisations (often named after a place or a person), full names, other
# people's names (they may share the surname), your name parts, places,
# post code. Within a kind, longer before shorter.
#
# `secret` names a sops key under contextforge/ (added with ./add-pii.sh);
# the value is matched case-insensitively as whole words. A secret that is a
# regex (the e-mail and domain ones) is written into sops by hand instead:
# single-quoted, every backslash doubled ('domain\\.tld'), because the value
# lands inside a JSON string. In `examples`,
# write SECRET_ plus the key in UPPER_SNAKE where the value would be
# (`home-full` → SECRET_HOME_FULL); that is what the check substitutes.
{
  name = "people";
  when = null;
  rules = [
    {
      secret = "home-full";
      replace = "[HOME]";
    }
    {
      secret = "home";
      replace = "[HOME]";
    }
    {
      secret = "employer-email";
      replace = "[EMPLOYER_EMAIL]";
    }
    {
      secret = "school-email";
      replace = "[SCHOOL_EMAIL]";
    }
    {
      secret = "family-email1";
      replace = "[FAMILY_EMAIL]";
    }
    {
      secret = "school-domain";
      replace = "[SCHOOL_DOMAIN]";
    }
    {
      secret = "employer-domain1";
      replace = "[EMPLOYER_DOMAIN]";
    }
    {
      secret = "employer-domain2";
      replace = "[EMPLOYER_DOMAIN]";
    }
    {
      secret = "employer-domain3";
      replace = "[EMPLOYER_DOMAIN]";
    }
    {
      secret = "employer-domain4";
      replace = "[EMPLOYER_DOMAIN]";
    }
    {
      # Safety net for the e-mail rules above: an address whose domain a
      # domain rule just replaced means its e-mail regex missed it (a local
      # part or subdomain the regex doesn't allow). Without this the part
      # before the @ stays readable: leaked.name@[SCHOOL_DOMAIN]. Any
      # [X_DOMAIN] label becomes [X_EMAIL], local part included. The local
      # part stops at whitespace, brackets, quotes and URL punctuation, so a
      # link around it survives.
      search = "[^\\s<>\"(),;:@\\[\\]/?=&]+@(?:[A-Za-z0-9-]+\\.)*\\[([A-Z_]+)_DOMAIN\\]";
      replace = "[\\1_EMAIL]";
    }
    {
      secret = "employer2"; # Longer and more specific than employer
      replace = "[EMPLOYER]";
    }
    {
      secret = "employer";
      replace = "[EMPLOYER]";
    }
    {
      secret = "employer-short2"; # Longer and more specific than employer-short
      replace = "[EMPLOYER_SHORT]";
    }
    {
      secret = "employer-short";
      replace = "[EMPLOYER_SHORT]";
    }
    {
      secret = "school-name";
      replace = "[SCHOOL]";
    }
    {
      secret = "fullname"; # Longer and more specific than fullname2
      replace = "[FULL_NAME]";
    }
    {
      secret = "fullname2";
      replace = "[FULL_NAME]";
    }
    {
      secret = "decree-yonder2"; # Slightly longer than decree-yonder
      replace = "[NAME]";
    }
    {
      secret = "family-name1";
      replace = "[NAME]";
    }
    {
      secret = "family-name2";
      replace = "[NAME]";
    }
    {
      secret = "decree-yonder";
      replace = "[NAME]";
    }
    {
      secret = "ivy-pork";
      replace = "[NAME]";
    }
    {
      secret = "first-name";
      replace = "[NAME]";
    }
    {
      secret = "middlename";
      replace = "[MIDDLE_NAME]";
    }
    {
      secret = "surname";
      replace = "[SURNAME]";
    }
    {
      secret = "post-office";
      replace = "[POST_OFFICE]";
    }
    {
      secret = "county";
      replace = "[COUNTY]";
    }
    {
      secret = "city";
      replace = "[CITY]";
    }
    {
      secret = "home-town";
      replace = "[HOME]";
    }
    {
      secret = "post-code";
      replace = "[POST_CODE]";
    }
  ];
  examples = [
    {
      input = "Regards, SECRET_DECREE_YONDER (secret_surname household, Secret_School_Name)";
      expect = "Regards, [NAME] ([SURNAME] household, [SCHOOL])";
    }
    {
      input = "Deliver to SECRET_HOME_FULL, SECRET_POST_CODE SECRET_HOME_TOWN; works at SECRET_EMPLOYER (SECRET_EMPLOYER_SHORT)";
      expect = "Deliver to [HOME], [POST_CODE] [HOME]; works at [EMPLOYER] ([EMPLOYER_SHORT])";
    }
    {
      # Here the e-mail rules never match (their stand-ins aren't regexes),
      # so these go through the safety net, as a missed address would.
      input = "From: Someone <leaked.name@SECRET_SCHOOL_DOMAIN> To: o'neill@elev.SECRET_SCHOOL_DOMAIN, x@SECRET_EMPLOYER_DOMAIN2";
      expect = "From: Someone <[SCHOOL_EMAIL]> To: [SCHOOL_EMAIL], [EMPLOYER_EMAIL]";
    }
    {
      input = "See SECRET_SCHOOL_DOMAIN or https://www.SECRET_SCHOOL_DOMAIN/a?mail=y@SECRET_SCHOOL_DOMAIN&b=1";
      expect = "See [SCHOOL_DOMAIN] or https://www.[SCHOOL_DOMAIN]/a?mail=[SCHOOL_EMAIL]&b=1";
    }
  ];
}
