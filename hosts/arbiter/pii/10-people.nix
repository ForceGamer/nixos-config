# People and places: always applied, to every tool result and prompt.
#
# Rules run in list order, each on the output of the previous one, so a value
# that contains another must come first: the full address before the street
# and the town, full names before the surname, the long employer name before
# its short form. Otherwise the shorter rule fires first and the longer one
# never matches, leaving the rest visible.
#
# `secret` names a sops key under contextforge/ (added with ./add-pii.sh);
# the value is matched case-insensitively as whole words. In `examples`,
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
      secret = "post-office";
      replace = "[POST_OFFICE]";
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
      secret = "county";
      replace = "[COUNTY]";
    }
    {
      secret = "city";
      replace = "[CITY]";
    }
    {
      secret = "employer";
      replace = "[EMPLOYER]";
    }
    {
      secret = "employer-short";
      replace = "[EMPLOYER_SHORT]";
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
      secret = "home";
      replace = "[HOME]";
    }
    {
      secret = "home-town";
      replace = "[HOME]";
    }
    {
      secret = "school-name";
      replace = "[SCHOOL]";
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
  ];
}
