#!/usr/bin/env python

from fuzzywuzzy import fuzz

print(fuzz.token_set_ratio("Edward Mordrake: Part 2", "Return to Murder House"))
print(fuzz.token_set_ratio("Edward Mordrake: Part 2", "Edward Mordrake (2)"))
print(fuzz.token_set_ratio("Return To Murder House", "Return to Murder House"))
print(fuzz.token_set_ratio("Return To Murder House", "Murder House"))
