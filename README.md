# c41checker
Script used to check development process with home development of color negatives using the C-41 Process.

## Usage
`ruby density_check.rb -h`

`ruby density_check.rb samples/underdog-ultramax400-2025-08-21.csv`

The default behavior (inits) is using consumer films (think Kodak Gold/Ultramax) ratios against known good samples sent to Underdog film lab.

For professional film comparisons like Ektar / ProImage / Portra, use the `Professional_Films` flag

`ruby density_check.rb samples/underdog-portra400-2025-08-21.csv --profile Professional_Films`

Lastly, if for whatever reason we use 12, 14 (default), or 16 bit raws, that's an option as well

`ruby density_check.rb samples/underdog-portra400-2025-08-21.csv --profile Professional_Films --bit-depth 12`

## Tracking developer health across rolls
`replenishment_check.rb` keeps a history of your scans and tells you whether the chemistry is drifting (crossover, weakening development, blue/oxidation changes). It reads the same two-row CSV as `density_check.rb` (gray target, then film base) and stores results in `replenishment_history.json` in the folder you run it from. That file is git-ignored.

Add each roll after you scan it, tagging the developer batch with `--dev` and saying what you used as the gray target:

`ruby replenishment_check.rb add roll_042.csv --rolls 42 --dev dev0937 --gray pavement`

- `--rolls N` is the roll number since you mixed the batch (also how you pick baseline rolls, below)
- `--dev TAG` names the chemistry batch. Rolls are only compared with others that have the same tag, so always use one tag per batch
- `--gray card|pavement|other` is what you sampled for gray. If you leave it off in a terminal you'll be asked
- `--film`, `--notes` are free text

Once a batch has two or more usable rolls, `add` prints a verdict. You can also run these any time:

`ruby replenishment_check.rb analyze` (verdict for the latest roll)

`ruby replenishment_check.rb plot` (ASCII chart of film-base R/G, needs 5+ usable rolls)

`ruby replenishment_check.rb report` (writes `replenishment_report.txt`)

### How to read the verdict
The latest roll is compared with the median of up to the previous 5 usable rolls in the same batch.

- **Film-base ratios (R/G, R/B, G/B) are the main crossover signal.** They don't depend on your gray target, so they stay reliable even if you sample pavement instead of an 18% card. A shift only counts as a problem if the roll is also off its target; a shift that stays within target is shown as INFO.
- **Gray-derived values** (gray R/G, contrasts, blue contrast) are secondary. They can warn but never raise CRITICAL on their own, and they're marked low confidence unless you used a real gray card. Blue drift is informational unless the film base backs it up (or you used a card).
- **Thin scans:** a roll is skipped if film base is under 35% of the range in R or G; rescan with more exposure. If only blue is under 20%, the roll is kept but its blue-based ratios are ignored.
- **Exposure mismatch:** if a roll's scan exposure differs from the reference by more than 10 points, CRITICAL is capped at WARNING and you're told the shift may be exposure rather than chemistry. Try to scan every roll with the same setup.

### Choosing the baseline
By default the long-term trend table compares against the first 3 to 5 usable rolls of a batch (assuming fresh chemistry). If your first rolls weren't representative, pick your own by roll number:

`ruby replenishment_check.rb baseline --dev dev0937 --rolls 10,20`

`ruby replenishment_check.rb baseline --dev dev0937 --clear` (back to the default)

`add --baseline` marks a roll as a baseline roll as you add it. Baseline rolls need `--rolls` numbers and a usable (non-thin) scan.

### Limits
`add` currently assumes 12-bit raws and the `Consumer_Films` profile.
