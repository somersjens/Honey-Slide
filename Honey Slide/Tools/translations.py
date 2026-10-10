#!/usr/bin/env python3
"""Round-trip the string catalog through a translator-friendly CSV.

    Tools/translations.py export [--out Translations.csv] [--languages fr,de,es]
    Tools/translations.py import Translations.csv [--dry-run]

The catalog is the source of truth for *structure*: whether a key is a plain
string, varies with a count, or has counted parts inside a longer sentence. The
CSV only ever carries text, so a translator cannot break the shape of a string
by filling in a cell, and the importer knows how to read every cell without
having to guess.

Export writes one row per string — a key that changes with a count gets one row
per grammatical form — with the English source, the Dutch translation and an
Import reads any such file back — including one holding a single language — and
writes what it finds into the catalog, validating as it goes.
"""

from __future__ import annotations

import argparse
import collections
import csv
import json
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Localizable.xcstrings")
DELIMITER = ";"

# Column layout. `key` leads so that a reviewer can sort or filter the sheet
# without the importer losing track of which row is which — matching on row
# order would corrupt everything silently the first time someone sorts.
#
# Every cell holds exactly one string. A string that changes with a count gets
# one row per grammatical form, told apart by `form`, rather than several forms
# crammed into a single cell.
FIXED_COLUMNS = ["key", "form", "instruction", "en", "nl"]

# Every language the app offers, in the order they were commissioned. Kept in
# step with AppLanguage.roster in Localization.swift.
LANGUAGES = [
    "af", "sq", "am", "ar", "hy", "as", "az", "eu", "be", "bn", "bs", "bg",
    "my", "ca", "zh", "hr", "cs", "da", "nl", "en", "et", "fo", "fi", "fr",
    "gl", "ka", "de", "el", "gu", "he", "hi", "hu", "is", "id", "ga", "it",
    "ja", "kn", "kk", "km", "ko", "lo", "lv", "lt", "mk", "ms", "ml", "mr",
    "mn", "ne", "nb", "or", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "si",
    "sk", "sl", "es", "sw", "sv", "ta", "te", "th", "bo", "tr", "uk", "ur",
    "ug", "uz", "vi", "cy", "zu",
]

# The plural forms the sheet asks for. Deliberately just these two: a handful of
# languages distinguish more (Polish few/many, Arabic zero/two), but this is a
# children's game where a number that reads slightly off is a fair price for a
# translation sheet nobody has to think hard about.
EXPORTED_FORMS = ["one", "other"]

# What the importer will still accept. Wider than what is asked for, so a
# translator who does fill in a `few` row has it honoured rather than rejected.
PLURAL_CATEGORIES = ["zero", "one", "two", "few", "many", "other"]

LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*(?:\.[a-z]+)?)[ \t]*=[ \t]*(.*)$")
# %@ , %lld , %1$@ , %2$lld — the specifiers a value may carry.
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(@|lld)")
SUBSTITUTION_REF = re.compile(r"%(?:(\d+)\$)?#@([A-Za-z_][A-Za-z0-9_]*)@")


# --------------------------------------------------------------- catalog i/o


def load_catalog():
    with open(CATALOG, encoding="utf-8") as handle:
        return json.load(handle)


def save_catalog(catalog):
    """Write the catalog back exactly the way Xcode would, so a diff shows only
    the translations that changed and never a reformatting of the whole file."""
    ordered = collections.OrderedDict([
        ("sourceLanguage", catalog["sourceLanguage"]),
        ("strings", collections.OrderedDict(
            sorted(catalog["strings"].items(), key=lambda kv: kv[0].lower()))),
        ("version", catalog["version"]),
    ])
    with open(CATALOG, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(ordered, indent=2, ensure_ascii=False,
                                separators=(",", " : ")) + "\n")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


# ------------------------------------------------------------------ structure


def structure_of(entry):
    """How a key is shaped, read from its English source.

    Returns ("plain", None), ("plural", None), or ("substitution", [names]).
    """
    english = entry.get("localizations", {}).get("en", {})
    if "variations" in english:
        return "plural", None
    if "substitutions" in english:
        return "substitution", sorted(english["substitutions"])
    return "plain", None


def forms_of(localization, kind):
    """One language's translation of one key, as ordered (form, text) pairs.

    `form` is "" for a string that does not vary, a CLDR category for one that
    varies with a count, and "part:category" for a counted part inside a longer
    sentence. Each pair is exactly one string, which is exactly one CSV cell.
    """
    if localization is None:
        return []
    if kind == "plain":
        return [("", localization.get("stringUnit", {}).get("value", ""))]
    if kind == "plural":
        forms = localization.get("variations", {}).get("plural", {})
        return [(c, forms[c]["stringUnit"]["value"])
                for c in PLURAL_CATEGORIES if c in forms]
    pairs = [("", localization.get("stringUnit", {}).get("value", ""))]
    for name, sub in sorted(localization.get("substitutions", {}).items()):
        forms = sub.get("variations", {}).get("plural", {})
        pairs += [(f"{name}:{c}", forms[c]["stringUnit"]["value"])
                  for c in PLURAL_CATEGORIES if c in forms]
    return pairs


def row_forms(entry, kind, names):
    """The rows a key gets in an exported sheet: one per form we ask for."""
    if kind == "plain":
        return [""]
    if kind == "plural":
        return list(EXPORTED_FORMS)
    return [""] + [f"{name}:{c}" for name in names for c in EXPORTED_FORMS]


def accepted_forms(entry, kind, names):
    """The rows an imported sheet may carry. Wider than `row_forms`, so a
    translator who adds a form their language really needs is not turned away
    for answering more carefully than we asked."""
    if kind == "plain":
        return [""]
    if kind == "plural":
        return list(PLURAL_CATEGORIES)
    return [""] + [f"{name}:{c}" for name in names for c in PLURAL_CATEGORIES]


def build(pairs, kind, names, english_localization):
    """Turn the filled-in (form, text) pairs for one language back into a
    catalog localization. Raises ValueError aimed at whoever filled them in."""
    values = {form: text for form, text in pairs if text.strip()}
    if not values:
        return None

    if kind == "plain":
        return unit(values[""])

    if kind == "plural":
        if "other" not in values:
            raise ValueError("the 'other' row is required for a counted string")
        return {"variations": {"plural": {
            c: unit(values[c]) for c in PLURAL_CATEGORIES if c in values}}}

    if "" not in values:
        raise ValueError("the row holding the sentence itself is empty")
    english_subs = english_localization.get("substitutions", {})
    result = {"stringUnit": {"state": "translated", "value": values[""]},
              "substitutions": {}}
    for name in names:
        forms = {c: values[f"{name}:{c}"] for c in PLURAL_CATEGORIES
                 if f"{name}:{c}" in values}
        if "other" not in forms:
            raise ValueError(f"the counted part {name!r} needs its 'other' row")
        result["substitutions"][name] = {
            "argNum": english_subs[name]["argNum"],
            "formatSpecifier": english_subs[name]["formatSpecifier"],
            "variations": {"plural": {
                c: unit(forms[c]) for c in PLURAL_CATEGORIES if c in forms}},
        }
    return result


# ----------------------------------------------------------------- instructions
#
# Where a string appears, and how much room it has. Matched in order, first hit
# wins. `floor` is the smallest budget worth quoting for that spot — the real
# budget also takes the existing English and Dutch lengths into account, since
# a translation that already fits is the best evidence of what fits.

CONTEXTS = [
    (r"^character\.",
     "An animal's name. Appears on its own under the artwork and inside "
     "sentences such as \"3 more stars to unlock …\".", 14),
    (r"^common\.",
     "A button label, reused across the app.", 14),
    (r"^game\.combo",
     "A small banner that flashes over the game board. Very little room.", 14),
    (r"^game\.encouragement\.|^game\.end\.completionSubtitle",
     "One line under the result title, wrapping over at most two lines. These "
     "ten messages climb from a weak score to a strong one — keep that "
     "progression.", 30),
    (r"^game\.end\.|^result\.",
     "On the end-of-level card: a title, or a button under it.", 22),
    (r"^game\.intro\.|^levelIntro\.(addition|subtraction|tables|fractions|"
     r"percentages|mixed)\.title",
     "The level-intro card. Titles are set in a large heavy face and shrink "
     "rather than wrap, so short is better.", 20),
    (r"^levelIntro\.",
     "A bullet on the level-intro card, wrapping over two lines.", 62),
    (r"^game\.",
     "Shown over the game board while playing.", 22),
    (r"^goal|^settings\.(goalInfo|soundInfo|characterInfo)",
     "In the settings sheet. The info lines sit under a group and may wrap.", 90),
    (r"^settings\.",
     "A row or title in the settings sheet.", 30),
    (r"^home\.cardsRemaining|^home\.(level|totalLabel)$",
     "In the menu header, beside a number. Extremely tight — this line must "
     "never wrap or truncate, and the layout shrinks it to fit.", 12),
    (r"^home\.",
     "In the menu header.", 26),
    (r"^info\.",
     "The popup shown when a topic or mode button is tapped a second time.", 55),
    (r"^menu\.|^mode\.|^topic\.[a-z]+$",
     "A small button or pill in the menu. One line, no wrapping — the tightest "
     "spots in the app.", 12),
    (r"^topic\.",
     "The one-line explanation under a topic button.", 28),
    (r"^name\.|^onboarding\.",
     "Onboarding, seen once at first launch.", 45),
    (r"^notif\..*\.title",
     "A push-notification title. The lock screen truncates it, so put the "
     "point first.", 40),
    (r"^notif\.",
     "A push-notification body.", 110),
    (r"^parentGate\.",
     "The adult check shown before a purchase. Written for a grown-up, not a "
     "child.", 70),
    (r"^premium\.feature\..*subtitle",
     "The explanation under a premium feature.", 65),
    (r"^premium\.",
     "On the premium screen: a title, badge or button.", 30),
    (r"^streak\.",
     "The play-goal bar in the menu header.", 16),
    (r"^tutorial\.step|^tutorial\.(score|notice)",
     "A speech bubble during the guided first game, or the notice explaining "
     "why the tutorial cannot start.", 110),
    (r"^tutorial\.",
     "The tutorial toggle on the level-intro card.", 16),
]


def context_for(key):
    for pattern, text, floor in CONTEXTS:
        if re.search(pattern, key):
            return text, floor
    return "Shown in the app.", 40


def values_of(entry, language):
    """Every piece of text a language holds for a key, flattened."""
    localization = entry.get("localizations", {}).get(language)
    if not localization:
        return []
    found = []
    if "stringUnit" in localization:
        found.append(localization["stringUnit"]["value"])
    for form in localization.get("variations", {}).get("plural", {}).values():
        found.append(form["stringUnit"]["value"])
    for sub in localization.get("substitutions", {}).values():
        for form in sub.get("variations", {}).get("plural", {}).values():
            found.append(form["stringUnit"]["value"])
    return found


def representative(entry, kind):
    """One English value that stands for the key's placeholders. Every plural
    form of a string carries the same substitutions, so one of them is enough."""
    english = entry["localizations"]["en"]
    if kind == "plural":
        forms = english["variations"]["plural"]
        return forms.get("other", next(iter(forms.values())))["stringUnit"]["value"]
    return english["stringUnit"]["value"]


FORM_NOTES = {
    "other": "COUNTED TEXT — required. The wording for a plural count, and the "
             "one used whenever the 'one' row does not apply.",
    "one": "COUNTED TEXT — the wording for a count of one. Leave empty if your "
           "language words one no differently from the rest.",
}


def instruction_for(key, entry, kind, names, form):
    context, floor = context_for(key)
    parts = [context]

    if kind == "substitution" and not form:
        parts.append(
            "This row is the sentence itself. The rows under it are the parts "
            "that change with a number; %N$#@name@ marks where each one lands.")
    elif form:
        part, _, category = form.rpartition(":")
        note = FORM_NOTES.get(category, "COUNTED TEXT — an extra plural form.")
        parts.append(f"Part '{part}': {note}" if part else note)

    longest = max((len(v) for language in ("en", "nl")
                   for v in values_of(entry, language)), default=0)
    if floor is not None:
        budget = max(floor, int(math.ceil(longest * 1.3)))
        parts.append(f"Aim for {budget} characters or fewer.")

    english_values = values_of(entry, "en")
    english = " ".join(english_values)
    # Placeholders are counted in one representative form, never across all of
    # them: "one" and "other" each carry the same %lld, and adding them up would
    # tell a translator to write it twice.
    specifiers = SPECIFIER.findall(representative(entry, kind))
    if kind == "substitution":
        parts.append(
            "The 'text = …' line is the sentence; the other lines are the parts "
            "that change with a number. Keep every %N$… marker in the sentence "
            "and %arg in each part — move them wherever your language needs "
            "them, but do not delete or rename them.")
    elif specifiers:
        numbers = sum(1 for _, t in specifiers if t == "lld")
        texts = sum(1 for _, t in specifiers if t == "@")
        described = []
        if numbers:
            described.append(f"{numbers}× %lld (a number)")
        if texts:
            described.append(f"{texts}× %@ (text substituted at runtime)")
        parts.append("Keep " + " and ".join(described) + ".")
        if numbers + texts > 1:
            parts.append(
                "Several values are substituted, so number them: %1$…, %2$… in "
                "whatever order your language reads.")


    if "**" in english:
        parts.append(
            "**Double asterisks** mark bold. Keep exactly one pair, around "
            "whichever words carry the emphasis in your language — not "
            "necessarily the same words as in English.")

    if "\n" in english:
        parts.append("The line break inside this text is deliberate; keep it.")

    if "%" in english and not specifiers and kind == "plain":
        parts.append("The % here is a literal percent sign.")

    # A note in the catalog explains why a key that carries a number needs no
    # plural forms after all; a translator should see that reasoning too.
    if entry.get("comment"):
        parts.append(entry["comment"])

    return " ".join(parts)


# ---------------------------------------------------------------------- export


def export(args):
    catalog = load_catalog()
    languages = args.languages.split(",") if args.languages else LANGUAGES
    columns = FIXED_COLUMNS + [l for l in languages if l not in ("en", "nl")]
    translated = columns[len(FIXED_COLUMNS):]

    wanted = tuple(args.keys.split(",")) if getattr(args, "keys", None) else None

    rows = []
    for key in sorted(catalog["strings"], key=str.lower):
        if wanted and not key.startswith(wanted):
            continue
        entry = catalog["strings"][key]
        kind, names = structure_of(entry)
        localizations = entry.get("localizations", {})
        known = {language: dict(forms_of(localizations.get(language), kind))
                 for language in ["en", "nl"] + translated}

        for form in row_forms(entry, kind, names):
            row = {"key": key, "form": form,
                   "instruction": instruction_for(key, entry, kind, names, form)}
            for language in ["en", "nl"] + translated:
                row[language] = known[language].get(form, "")
            rows.append(row)

    with open(args.out, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns,
                                delimiter=DELIMITER, quoting=csv.QUOTE_ALL)
        writer.writeheader()
        writer.writerows(rows)

    keys = len({row["key"] for row in rows})
    print(f"{args.out}: {keys} keys over {len(rows)} rows × {len(columns)} "
          f"columns ({len(translated)} languages to fill)")


# ---------------------------------------------------------------------- import


def check(key, language, kind, english_localization, translated):
    """Structural checks a translation must pass. Returns a list of problems."""
    problems = []

    def compare(source, target, where):
        source_specs = SPECIFIER.findall(source)
        target_specs = SPECIFIER.findall(target)
        want = collections.Counter(t for _, t in source_specs)
        got = collections.Counter(t for _, t in target_specs)
        if want != got:
            problems.append(
                f"{where}: expected {dict(want) or 'no'} placeholder(s), "
                f"found {dict(got) or 'none'}")
        elif sum(want.values()) > 1 and not all(i for i, _ in target_specs):
            if any(i for i, _ in target_specs):
                problems.append(
                    f"{where}: some placeholders are numbered and some are not; "
                    f"number all of them (%1$…, %2$…) or none")
            else:
                # Unnumbered placeholders are filled in the order they appear.
                # That is still correct as long as the kinds line up with what
                # each argument actually is, which is what English's numbering
                # tells us. `normalise` writes the numbers in afterwards.
                by_position = [t for _, t in sorted(
                    (int(n or k + 1), t) for k, (n, t) in enumerate(source_specs))]
                if [t for _, t in target_specs] != by_position:
                    problems.append(
                        f"{where}: the placeholders are not numbered and do not "
                        f"come in the order {by_position}, so the wrong value "
                        f"would be filled in — number them (%1$…, %2$…)")
        if target.count("**") % 2:
            problems.append(f"{where}: unbalanced ** bold markers")

    if kind == "plain":
        compare(english_localization["stringUnit"]["value"],
                translated["stringUnit"]["value"], "text")
    elif kind == "plural":
        source = english_localization["variations"]["plural"]["other"]["stringUnit"]["value"]
        for category, form in translated["variations"]["plural"].items():
            compare(source, form["stringUnit"]["value"], category)
    else:
        skeleton = translated["stringUnit"]["value"]
        for name in english_localization["substitutions"]:
            if not any(n == name for _, n in SUBSTITUTION_REF.findall(skeleton)):
                problems.append(f"text: missing the %N$#@{name}@ marker")
            for category, form in \
                    translated["substitutions"][name]["variations"]["plural"].items():
                if "%arg" not in form["stringUnit"]["value"]:
                    problems.append(f"{name}.{category}: missing %arg")
        for _, name in SUBSTITUTION_REF.findall(skeleton):
            if name not in english_localization["substitutions"]:
                problems.append(f"text: unknown counted part %…#@{name}@")
    return problems


def normalise(localization):
    """Number any unnumbered placeholders, in the order they appear.

    Runtime behaviour is unchanged — unnumbered arguments are already filled in
    that order — but the catalog then states the mapping outright, so a later
    edit that moves a word cannot silently swap two values.
    """
    def rewrite(text):
        specs = SPECIFIER.findall(text)
        if len(specs) < 2 or any(index for index, _ in specs):
            return text
        counter = iter(range(1, len(specs) + 1))
        return SPECIFIER.sub(lambda m: f"%{next(counter)}${m.group(2)}", text)

    if "stringUnit" in localization:
        localization["stringUnit"]["value"] = rewrite(
            localization["stringUnit"]["value"])
    for form in localization.get("variations", {}).get("plural", {}).values():
        form["stringUnit"]["value"] = rewrite(form["stringUnit"]["value"])
    for sub in localization.get("substitutions", {}).values():
        for form in sub.get("variations", {}).get("plural", {}).values():
            form["stringUnit"]["value"] = rewrite(form["stringUnit"]["value"])


def do_import(args):
    catalog = load_catalog()
    strings = catalog["strings"]

    with open(args.csv, encoding="utf-8-sig", newline="") as handle:
        # Spreadsheets export with whichever separator their locale prefers, so
        # take the file as it comes rather than as it was written.
        first = handle.readline()
        handle.seek(0)
        delimiter = max(";,\t", key=first.count)
        reader = csv.DictReader(handle, delimiter=delimiter)
        if reader.fieldnames is None or "key" not in reader.fieldnames:
            sys.exit(f"{args.csv}: no 'key' column in the header row")
        if "form" not in reader.fieldnames:
            sys.exit(f"{args.csv}: no 'form' column — this file was made by an "
                     f"older version of this script; re-export and refill it.")
        languages = [c for c in reader.fieldnames
                     if c and c not in ("key", "form", "instruction")]
        rows = list(reader)

    # Gather every row belonging to a key before building anything: the forms of
    # one counted string are spread over several rows, and all of them are
    # needed together.
    gathered = collections.OrderedDict()
    problems = []
    for number, row in enumerate(rows, start=2):
        key = (row.get("key") or "").strip()
        if not key:
            continue
        if key not in strings:
            problems.append(f"row {number}: key {key!r} is not in the catalog")
            continue
        entry = gathered.setdefault(key, {"line": number, "forms": []})
        entry["forms"].append(((row.get("form") or "").strip(), row))

    written = collections.Counter()
    for key, gathering in gathered.items():
        entry = strings[key]
        kind, names = structure_of(entry)
        english = entry["localizations"]["en"]
        allowed = set(accepted_forms(entry, kind, names))
        line = gathering["line"]

        unexpected = {f for f, _ in gathering["forms"]} - allowed
        if unexpected:
            problems.append(
                f"row {line} [{key}]: unexpected form(s) {sorted(unexpected)}; "
                f"this string uses {sorted(allowed) or ['(none)']}")
            continue

        for language in languages:
            pairs = [(form, row.get(language) or "")
                     for form, row in gathering["forms"]]
            try:
                translated = build(pairs, kind, names, english)
            except ValueError as error:
                problems.append(f"row {line} [{key}] {language}: {error}")
                continue
            if translated is None:
                continue
            found = check(key, language, kind, english, translated)
            for problem in found:
                problems.append(f"row {line} [{key}] {language}: {problem}")
            if any(not p.startswith("warning:") for p in found):
                continue
            normalise(translated)
            entry.setdefault("localizations", {})[language] = translated
            written[language] += 1

    if problems:
        print("problems:", file=sys.stderr)
        for problem in problems:
            print("  " + problem, file=sys.stderr)
        print(file=sys.stderr)

    if written:
        print("translations read:")
        for language in sorted(written):
            print(f"  {language}: {written[language]}/{len(strings)} keys")
    else:
        print("no translations found in the file")

    fatal = [p for p in problems if "warning:" not in p]
    if args.dry_run:
        print("\ndry run — catalog not written")
    elif fatal and not args.force:
        sys.exit("\nnothing written: fix the problems above, or pass --force to "
                 "write everything that did pass")
    else:
        save_catalog(catalog)
        print(f"\nwritten to {os.path.relpath(CATALOG, ROOT)}")
        print("next: open the project in Xcode so the catalog recompiles, and "
              "check the new languages appear under Localizations.")


# ------------------------------------------------------------------------ main


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    exporter = commands.add_parser("export", help="catalog → CSV")
    exporter.add_argument("--out", default=os.path.join(ROOT, "Translations.csv"))
    exporter.add_argument("--languages",
                          help="comma-separated subset, e.g. fr,de,es")
    exporter.add_argument("--keys",
                          help="comma-separated key prefixes, e.g. notif.weekly "
                               "— for sending a correction round back out")
    exporter.set_defaults(func=export)

    importer = commands.add_parser("import", help="CSV → catalog")
    importer.add_argument("csv")
    importer.add_argument("--dry-run", action="store_true",
                          help="validate without writing")
    importer.add_argument("--force", action="store_true",
                          help="write the rows that passed even if others failed")
    importer.set_defaults(func=do_import)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
