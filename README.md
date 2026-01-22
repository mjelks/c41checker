# c41checker
Script used to check development process with home development of color negatives using the C-41 Process.

## Usage
`ruby density_check.rb -h`

`ruby density_check.rb samples/underdog-ultramax400-2025-08-21.csv`

The default behavior (inits) is using consumer films (think Kodak Gold/Ultramax) ratios against known good samples sent to Underdog film lab.

For professional film comparisons like Ektar / ProImage / Portra, use the `Professional_Films` flag

`ruby density_check.rb samples/underdog-portra400-2025-08-21.csv --profile Professional_Films`