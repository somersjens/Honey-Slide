# Translation kit

```bash
python3 Tools/translations.py export              # catalog → Translations.csv
python3 Tools/translations.py import Translations.csv --dry-run
python3 Tools/translations.py import Translations.csv
```

Semicolon-separated, UTF-8 with BOM, every field quoted — opens straight into
Excel, Numbers and Google Sheets without an import dialog. Columns are `key`,
`form`, `instruction`, `en`, `nl`, then one per language.

**Every cell holds exactly one string.** Nothing is ever packed into a cell with
a separator, and no cell needs to be read alongside another to make sense.

Import matches on `key` + `form`, so the sheet can be sorted, filtered or split
without anything going astray. Empty cells are skipped rather than blanked, so a
file can come back holding a single language, or one language at a time.
`export --languages fr,de,es` writes a smaller file for one translator.

## Rows and the `form` column

Most strings do not change, and get one row with an empty `form`.

A string that changes with a count gets **two rows**, told apart by `form`:

| form | what to write |
|---|---|
| `one` | the wording for a count of one — "1 star", "1 ster" |
| `other` | required. The wording for a plural count, and what gets used whenever `one` does not apply |

Languages that word one no differently from the rest (Japanese, Chinese, Korean,
Thai, Vietnamese, Indonesian, Georgian…) can leave `one` empty.

This is deliberately simpler than the six forms CLDR defines. Polish, Arabic,
Russian, Welsh and about a dozen others really do distinguish more — Polish
words 22 differently from 25 — and with only two rows those land on the `other`
wording. In a children's game that is a fair trade for a sheet nobody has to
puzzle over. If a translator adds a `few` or `many` row of their own accord, the
importer honours it; it just is not asked for.

No string currently has two counts in one sentence. If one ever does, it gets a
row for the sentence itself plus a row per form of each counted part, marked
`minutes:one`, `days:other` and so on, with `%arg` where the number lands — the
importer already understands that shape.

## Whole sentences, not assembled fragments

Where a word used to be dropped into a borrowed sentence, each variant now has
its own full sentence — ten level-intro lines, one per food, rather than one
line with the food pasted in. It costs a few more keys and buys every language
the freedom to decline, reorder or reword.

Still assembled, and worth revisiting if a translator flags it: shape names
inside the two `parentGate` instructions.

## Rules the importer enforces

It refuses to write anything if a cell would break at runtime, and names the row
and the reason. Checked: placeholders present and of the right kind; numbered
placeholders (`%1$@`, `%2$lld`) wherever more than one value is substituted, so
a language can reorder the sentence; `**bold**` markers balanced; the `other` row
filled on every counted string; `%arg` present in every counted part; no form
used that the string does not have. Languages that usually need more than
`one`/`other` are not warned about — see above.

Word order, and which words carry the bold, are the translator's call — only the
markers themselves have to survive.
