# DSLR C-41 Validator Project Instructions

## Coding Standards
- **Linter:** RuboCop must pass for `density-check.rb`.
- **Formatting:** Use 2-space indentation. 
- **Documentation:** Avoid heavy RDoc; use concise comments for scientific logic.

## Project Structure
- `density-check.rb`: The main entry point.
- `/samples`: Contains `.csv` files for testing. **Never** include these in linting or analysis.

## Logic Constraints
- When adding new "Profiles", maintain the `FILM_DENSITY_PROFILES` hash structure.
- When adding CLI flags, always use `OptionParser`.
- Ensure all CSV parsing uses the `RawDigger` column headers (`Rmin`, `Ravg`, etc.).