#!/usr/bin/env ruby
# frozen_string_literal: true

# Replenishment Health Checker for C-41
# Detects chemistry degradation and crossover issues across multiple rolls

# Add a new roll to tracking
# ruby replenishment_check.rb add my_scan.csv --rolls 42 --film "Ultramax 400" --dev dev0937 --gray pavement
# (--gray is card|pavement|other; you'll be prompted if omitted)
# (trends are only computed between rolls sharing the same --dev tag)

# Analyze current chemistry health
# ruby replenishment_check.rb analyze

# View trend plots
# ruby replenishment_check.rb plot

# Generate full report
# ruby replenishment_check.rb report

require 'csv'
require 'json'
require 'date'

# Tracks C-41 developer health across rolls: compares each new scan's film-base and
# gray-derived ratios against a rolling median of earlier rolls from the same dev batch.
class ReplenishmentCheck
  # Thresholds for detecting chemistry issues
  CROSSOVER_WARNING = 0.03    # 3% shift in R/G ratio = early warning
  CROSSOVER_CRITICAL = 0.05   # 5% shift = serious crossover
  CONTRAST_DRIFT_WARNING = 0.04 # 4% loss in contrast
  BLUE_DRIFT_WARNING = 0.08 # 8% shift in blue behavior

  # How many prior rolls (same dev batch) feed the rolling-median reference
  REFERENCE_WINDOW = 5

  # Film-base-only ratios don't depend on the gray target, so they are the
  # primary trend signal. gray_* and *_contrast are secondary.
  BASE_KEYS = %w[base_rg base_rb base_gb].freeze

  # Film base utilization (percent) below which R or G makes a whole scan too thin to
  # trust. density_check flags THIN SCAN at 40%; 35% keeps borderline-but-usable scans.
  THIN_SCAN_UTILIZATION = 35.0

  # Blue is always the dimmest channel behind the orange mask. Below this, only the
  # blue-based ratios are skipped for that roll instead of discarding the whole roll.
  BLUE_THIN_UTILIZATION = 20.0
  BLUE_KEYS = %w[base_rb base_gb gray_rb gray_gb b_contrast].freeze

  # Rolls whose scan exposure differs by more than this many percentage points can show
  # film-base ratio shifts caused by exposure, not chemistry.
  EXPOSURE_MISMATCH_POINTS = 10.0

  BASE_LABELS = { 'base_rg' => 'base R/G', 'base_rb' => 'base R/B', 'base_gb' => 'base G/B' }.freeze

  GRAY_TARGETS = {
    '1' => 'card', 'card' => 'card',
    '2' => 'pavement', 'pavement' => 'pavement',
    '3' => 'other', 'other' => 'other'
  }.freeze
  GRAY_LABELS = {
    'card' => '18% gray card',
    'pavement' => 'pavement/concrete',
    'other' => 'other/non-standard target',
    'unknown' => 'unknown'
  }.freeze

  attr_reader :history_file, :baseline

  def initialize(history_file = 'replenishment_history.json')
    @history_file = history_file
    @history = load_history
    @baseline = calculate_baseline
  end

  def load_history
    return [] unless File.exist?(@history_file)

    JSON.parse(File.read(@history_file))
  rescue JSON::ParserError
    puts "⚠️  Warning: Could not parse history file, starting fresh"
    []
  end

  def save_history
    File.write(@history_file, JSON.pretty_generate(@history))
  end

  def add_roll(csv_file, rolls_since_mix: nil, film_type: 'consumer', notes: '', dev: nil, gray_target: nil,
               baseline: false)
    require_relative 'density_check' # Load the main validator

    gray_target = resolve_gray_target(gray_target)

    # Run standard analysis
    validator = DensityCheck.new
    results = validator.analyze_from_single_csv(csv_file, 'Consumer_Films', 12)

    # Extract key metrics for tracking
    entry = {
      'date' => Time.now.strftime('%Y-%m-%d %H:%M'),
      'rolls_since_mix' => rolls_since_mix,
      'film_type' => film_type,
      'dev' => dev,
      'gray_target' => gray_target,
      'csv_file' => csv_file,
      'notes' => notes,
      'metrics' => extract_key_metrics(results),
      'targets' => extract_target_status(results),
      'scan' => extract_scan_health(validator, results)
    }
    entry['baseline'] = true if baseline

    @history << entry
    save_history
    @baseline = calculate_baseline

    puts "\n✅ Roll added to replenishment history (#{@history.length} total rolls tracked)"
    puts "🎯 Gray target recorded: #{GRAY_LABELS[gray_target]}"
    if gray_target != 'card'
      puts "   Gray-derived metrics (gray_*, contrasts, blue) will be treated as low confidence."
      puts "   Film-base ratios drive the crossover verdict."
    end

    # Analyze if we have enough data in this dev batch
    analyze_replenishment_health if batch_history.length >= 2

    entry
  end

  def extract_key_metrics(results)
    ratios = results['ratio_analysis']['sample_ratios']

    {
      # Film-base ratios: independent of the gray target (primary signal)
      'base_rg' => ratios[:base_rg],
      'base_rb' => ratios[:base_rb],
      'base_gb' => ratios[:base_gb],

      # Gray-derived ratios (secondary, depend on gray target quality)
      'gray_rg' => ratios[:gray_rg],
      'gray_rb' => ratios[:gray_rb],
      'gray_gb' => ratios[:gray_gb],

      # Development strength indicators (gray / base)
      'r_contrast' => ratios[:r_contrast],
      'g_contrast' => ratios[:g_contrast],
      'b_contrast' => ratios[:b_contrast],

      # Timestamp for trend analysis
      'timestamp' => Time.now.to_i
    }
  end

  # How each ratio compares to its profile target (level + deviation), so
  # shifts can be judged against "where it should be", not only "where it was".
  def extract_target_status(results)
    results['ratio_analysis']['comparisons'].each_with_object({}) do |(name, comp), out|
      out[name.to_s] = {
        'level' => comp[:status][:level].to_s,
        'deviation_pct' => comp[:deviation_pct]
      }
    end
  end

  # Film base utilization per channel; thin scans give unreliable ratios.
  def extract_scan_health(validator, results)
    reference_white = results['reference_white'].to_f
    util = %w[r g b].to_h do |channel|
      [channel, (validator.film_base_data.send(channel).avg / reference_white * 100).round(1)]
    end
    { 'utilization' => util, 'thin' => util['r'] < THIN_SCAN_UTILIZATION || util['g'] < THIN_SCAN_UTILIZATION }
  end

  # Rolls belonging to the same developer batch as the most recent roll.
  # Mixing batches would compare unrelated chemistry.
  def batch_history
    return [] if @history.empty?

    dev = @history.last['dev']
    @history.select { |r| r['dev'] == dev }
  end

  # Computed from stored utilization so older history picks up the current cutoffs
  def thin_scan?(roll)
    util = roll.dig('scan', 'utilization')
    return roll.dig('scan', 'thin') ? true : false unless util

    util['r'] < THIN_SCAN_UTILIZATION || util['g'] < THIN_SCAN_UTILIZATION
  end

  def blue_thin?(roll)
    util = roll.dig('scan', 'utilization')
    util ? util['b'] < BLUE_THIN_UTILIZATION : false
  end

  # A roll's metrics with blue-based ones dropped when its blue channel is too thin
  def usable_metrics(roll)
    return roll['metrics'] unless blue_thin?(roll)

    roll['metrics'].except(*BLUE_KEYS)
  end

  # Largest R/G scan-exposure gap (percentage points) between the latest roll and the
  # median of the reference rolls
  def exposure_gap(latest_roll, prior)
    latest_util = latest_roll.dig('scan', 'utilization')
    return 0.0 unless latest_util

    %w[r g].map do |channel|
      reference = prior.last(REFERENCE_WINDOW).filter_map { |r| r.dig('scan', 'utilization', channel) }
      reference.empty? ? 0.0 : (latest_util[channel] - median(reference)).abs
    end.max
  end

  # Batch rolls whose scans are good enough to trust
  def usable_batch
    batch_history.reject { |r| thin_scan?(r) }
  end

  # Median of each metric over the last REFERENCE_WINDOW rolls given, so a
  # single bad sample doesn't trigger a false alarm.
  def rolling_reference(rolls)
    prior = rolls.last(REFERENCE_WINDOW).map { |r| usable_metrics(r) }
    keys = prior.flat_map(&:keys).uniq - ['timestamp']
    keys.each_with_object({}) do |key, ref|
      values = prior.map { |m| m[key] }.compact
      ref[key] = median(values) unless values.empty?
    end
  end

  # Rolls chosen with the `baseline` command (or `add --baseline`) win; otherwise
  # fall back to the first 3-5 usable rolls of the batch (assuming fresh chemistry).
  def baseline_rolls
    batch = usable_batch
    chosen = batch.select { |r| r['baseline'] }
    return chosen if chosen.any?

    batch.length < 3 ? [] : batch.first([5, batch.length].min)
  end

  def baseline_chosen?
    usable_batch.any? { |r| r['baseline'] }
  end

  def baseline_description
    return 'first 3-5 usable rolls' unless baseline_chosen?

    numbers = baseline_rolls.map { |r| r['rolls_since_mix'] || '?' }.join(', ')
    "chosen rolls: #{numbers}"
  end

  # Mark which rolls of a dev batch form the baseline (matched by --rolls number)
  def set_baseline(dev: nil, rolls: [], clear: false)
    dev ||= @history.last && @history.last['dev']
    batch = @history.select { |r| r['dev'] == dev }
    abort("Error: no rolls found for dev batch '#{dev}'") if batch.empty?

    if clear
      batch.each { |r| r.delete('baseline') }
    else
      abort("Error: --rolls N,N,... required (or --clear)") if rolls.empty?
      mark_baseline(batch, rolls, dev)
    end
    save_history
    @baseline = calculate_baseline
    puts clear ? "✅ Baseline reset to the default for dev #{dev}" : "✅ Baseline for dev #{dev}: #{baseline_description}"
  end

  def calculate_baseline
    batch = baseline_rolls
    return nil if batch.empty?

    metrics = batch.map { |r| usable_metrics(r) }

    keys = BASE_KEYS + %w[gray_rg gray_rb r_contrast g_contrast b_contrast]
    keys.each_with_object({}) do |key, base|
      values = metrics.map { |m| m[key] }.compact
      base[key] = avg(values) unless values.empty?
    end
  end

  def analyze_replenishment_health
    puts "\n#{'=' * 80}"
    puts "🧪 REPLENISHMENT HEALTH ANALYSIS"
    puts "=" * 80

    batch = batch_history
    if batch.length < 2
      puts "⚠️  Need at least 2 rolls in the same dev batch to analyze trends"
      return
    end

    latest_roll = batch.last
    gray_target = latest_roll['gray_target'] || 'unknown'

    print_batch_header(batch, latest_roll, gray_target)

    if thin_scan?(latest_roll)
      puts "\n🌑 Latest scan is THIN (film base < #{THIN_SCAN_UTILIZATION.round}% in R or G)."
      puts "   Ratios from thin scans are noisy, so no comparison was made. Rescan with more exposure."
      return
    end

    prior = usable_batch[0...-1]
    skipped = batch.length - 1 - prior.length
    puts "(#{skipped} earlier thin-scan roll#{'s' if skipped != 1} excluded from the reference)" if skipped.positive?
    if prior.empty?
      puts "\n⚠️  No earlier usable rolls in this dev batch to compare against"
      return
    end

    # Compare latest roll to the rolling median of earlier usable rolls
    latest = usable_metrics(latest_roll)
    previous = rolling_reference(prior)
    gap = exposure_gap(latest_roll, prior)
    targets = latest_roll['targets'] || {}
    low_confidence = gray_target != 'card'

    print_reference_notes(prior, gray_target)
    print_scan_notes(latest_roll, gap)

    # Primary: film-base ratios (independent of gray target)
    base_status = detect_base_crossover(latest, previous, targets, gap)

    # Secondary: gray-derived
    gray_status = detect_gray_rg_shift(latest, previous, targets, low_confidence)
    contrast_status = detect_contrast_loss(latest, previous, targets, low_confidence)
    blue_status = detect_blue_drift(latest, previous, targets, base_status, low_confidence)

    statuses = [base_status, gray_status, contrast_status, blue_status]
    print_overall_assessment(statuses)

    # Long-term trend analysis if we have baseline
    print_trend_analysis if @baseline && (baseline_chosen? || usable_batch.length >= 5)

    print_recommendations(base_status, gray_status, contrast_status, blue_status)
  end

  def print_batch_header(batch, latest_roll, gray_target)
    puts "\n📊 ROLLS TRACKED: #{@history.length}"
    puts "Dev batch: #{latest_roll['dev'] || '(untagged)'} (#{batch.length} rolls)"
    puts "Latest roll: #{latest_roll['date']}"
    puts "Rolls since fresh mix: #{latest_roll['rolls_since_mix']}" if latest_roll['rolls_since_mix']
    puts "Gray target: #{GRAY_LABELS[gray_target]}"
    print_scan_line(latest_roll)
  end

  def print_scan_notes(latest_roll, gap)
    if blue_thin?(latest_roll)
      puts "🌑 Blue channel is thin (< #{BLUE_THIN_UTILIZATION.round}%): blue-based ratios skipped for this roll"
    end
    return unless gap > EXPOSURE_MISMATCH_POINTS

    puts "⚠️  Scan exposure differs by #{gap.round(1)} pts from the reference rolls; " \
         "film-base ratio shifts may reflect exposure, not chemistry"
  end

  def print_reference_notes(prior, gray_target)
    count = [prior.length, REFERENCE_WINDOW].min
    puts "Reference: median of previous #{count} usable roll#{'s' if prior.length != 1}"
    mixed = prior.last(REFERENCE_WINDOW).map { |r| r['gray_target'] || 'unknown' }.uniq - [gray_target]
    return if mixed.empty?

    labels = mixed.map { |g| GRAY_LABELS[g] }.join(', ')
    puts "⚠️  Reference mixes gray targets (#{labels}); gray-derived comparisons are less reliable"
  end

  # Film-base R/G, R/B, G/B shift. This is the crossover signal that doesn't
  # rely on the gray target. A shift only escalates if the latest base ratio
  # is itself off its profile target.
  def detect_base_crossover(latest, previous, targets, exposure_gap = 0.0)
    shifts = BASE_KEYS.each_with_object({}) do |key, out|
      next unless latest[key] && previous[key]

      out[key] = (latest[key] - previous[key]) / previous[key]
    end

    status = {
      'shift_pct' => shifts.transform_values { |v| v * 100 },
      'level' => :good
    }

    if shifts.empty?
      status['level'] = :info
      status['message'] = "📊 INFO: No film-base data in reference rolls (re-add rolls to track base ratios)"
      return status
    end

    key, shift = shifts.max_by { |_, v| v.abs }
    label = BASE_LABELS[key]
    magnitude = shift.abs

    if magnitude > CROSSOVER_WARNING
      if off_target?(targets, key)
        status['level'] = magnitude > CROSSOVER_CRITICAL ? :critical : :warning
        shifted = "Film-base #{label} shifted #{signed_pct(shift)}% #{target_phrase(targets)}"
        status['message'] = if status['level'] == :critical
                              "❌ CRITICAL: #{shifted} - possible crossover"
                            else
                              "⚠️  WARNING: #{shifted} - monitor for crossover"
                            end
      else
        status['level'] = :info
        status['message'] =
          "📊 INFO: Film-base #{label} shifted #{signed_pct(shift)}% but is still within target (likely scan/light variation)"
      end
    else
      status['message'] = "✅ GOOD: Film-base ratios stable"
    end

    apply_exposure_caveat(status, exposure_gap)
    status
  end

  # A big exposure gap makes a base-ratio shift less trustworthy as a chemistry signal:
  # cap CRITICAL at WARNING and say why.
  def apply_exposure_caveat(status, gap)
    return unless gap > EXPOSURE_MISMATCH_POINTS && [:warning, :critical].include?(status['level'])

    if status['level'] == :critical
      status['level'] = :warning
      status['message'] = status['message'].sub('❌ CRITICAL:', '⚠️  WARNING:')
    end
    status['message'] += " [scan exposure differs by #{gap.round(1)} pts - may be exposure, not chemistry]"
  end

  def detect_gray_rg_shift(latest, previous, targets, low_confidence)
    shift = (latest['gray_rg'] - previous['gray_rg']) / previous['gray_rg']

    status = { 'gray_rg_shift_pct' => shift * 100, 'level' => :good }

    if shift.abs > CROSSOVER_WARNING
      if off_target?(targets, 'gray_rg')
        status['level'] = :warning
        status['message'] =
          "⚠️  WARNING: Gray R/G shifted #{signed_pct(shift)}% #{target_phrase(targets)}#{confidence_note(low_confidence)}"
      else
        status['level'] = :info
        status['message'] =
          "📊 INFO: Gray R/G shifted #{signed_pct(shift)}% but is still within target#{confidence_note(low_confidence)}"
      end
    else
      status['message'] = "✅ GOOD: Gray R/G stable"
    end

    status
  end

  def detect_contrast_loss(latest, previous, targets, low_confidence)
    # Development strength = density difference between gray and base
    r_loss = ((previous['r_contrast'] - latest['r_contrast']) / previous['r_contrast'])
    g_loss = ((previous['g_contrast'] - latest['g_contrast']) / previous['g_contrast'])

    avg_loss = (r_loss + g_loss) / 2.0

    status = {
      'r_contrast_change_pct' => r_loss * 100,
      'g_contrast_change_pct' => g_loss * 100,
      'avg_loss_pct' => avg_loss * 100,
      'level' => :good
    }

    if avg_loss > CONTRAST_DRIFT_WARNING
      if off_target?(targets, 'r_contrast', 'g_contrast')
        status['level'] = :warning
        status['message'] =
          "⚠️  WARNING: Development strength declining - check replenishment rate#{confidence_note(low_confidence)}"
      else
        status['level'] = :info
        status['message'] =
          "📊 INFO: Contrast down #{format('%.1f', avg_loss * 100)}% but still within target#{confidence_note(low_confidence)}"
      end
    elsif avg_loss < -0.03
      status['level'] = :info
      status['message'] = "📊 INFO: Development strength increasing slightly"
    else
      status['message'] = "✅ GOOD: Development strength stable"
    end

    status
  end

  # Blue contrast is the weakest, noisiest channel and leans hardest on the
  # gray target, so it is informational unless the gray target is a real card
  # or the film base corroborates the drift.
  def detect_blue_drift(latest, previous, targets, base_status, low_confidence)
    unless latest['b_contrast'] && previous['b_contrast']
      return { 'level' => :info, 'message' => "📊 INFO: Blue channel too thin to judge (this roll or its reference)" }
    end

    b_contrast_change = ((latest['b_contrast'] - previous['b_contrast']) / previous['b_contrast'])

    status = { 'b_contrast_change_pct' => b_contrast_change * 100, 'level' => :good }

    if b_contrast_change.abs > BLUE_DRIFT_WARNING
      corroborated = [:warning, :critical].include?(base_status['level'])
      if (corroborated || !low_confidence) && off_target?(targets, 'b_contrast')
        status['level'] = :warning
        status['message'] =
          "⚠️  WARNING: Blue channel behavior changing (#{signed_pct(b_contrast_change)}%) - possible oxidation"
      else
        status['level'] = :info
        why_not = low_confidence ? 'not corroborated by film base, gray target is not a card' : 'not corroborated by film base'
        status['message'] =
          "📊 INFO: Blue contrast moved #{signed_pct(b_contrast_change)}% - informational only (#{why_not})"
      end
    else
      status['message'] = "✅ GOOD: Blue channel stable"
    end

    status
  end

  def print_overall_assessment(statuses)
    puts "\n🎯 OVERALL CHEMISTRY STATUS:"
    statuses.each { |s| puts s['message'] }

    # Determine if chemistry needs attention (info-level items don't count)
    critical_count = statuses.count { |s| s['level'] == :critical }
    warning_count = statuses.count { |s| s['level'] == :warning }

    puts "\n#{'=' * 80}"
    if critical_count.positive?
      puts "🚨 ACTION REQUIRED: Chemistry showing critical degradation"
    elsif warning_count >= 2
      puts "⚠️  MONITOR CLOSELY: Multiple warning signs detected"
    elsif warning_count == 1
      puts "📊 MONITOR: One parameter trending outside normal range"
    else
      puts "✅ CHEMISTRY HEALTHY: No parameters off target and drifting"
    end
    puts "=" * 80
  end

  def print_trend_analysis
    puts "\n📈 LONG-TERM TREND ANALYSIS:"
    puts "Baseline (#{baseline_description}) vs Latest roll:"
    puts "-" * 80

    latest = usable_metrics(batch_history.last)

    [
      ['Base R/G', 'base_rg', CROSSOVER_WARNING],
      ['Base R/B', 'base_rb', CROSSOVER_WARNING],
      ['Base G/B', 'base_gb', CROSSOVER_WARNING],
      ['R/G Ratio (Gray)*', 'gray_rg', CROSSOVER_WARNING],
      ['R Contrast*', 'r_contrast', CONTRAST_DRIFT_WARNING],
      ['G Contrast*', 'g_contrast', CONTRAST_DRIFT_WARNING],
      ['B Contrast*', 'b_contrast', BLUE_DRIFT_WARNING]
    ].each do |label, key, threshold|
      baseline_val = @baseline[key]
      latest_val = latest[key]
      next unless baseline_val && latest_val

      drift_pct = ((latest_val - baseline_val) / baseline_val).abs * 100

      icon = drift_pct > (threshold * 100) ? '⚠️' : '✅'

      puts format("%-25s Baseline: %.3f  Latest: %.3f  Drift: %.1f%% %s", label, baseline_val, latest_val, drift_pct, icon)
    end
    puts "* gray-derived, depends on gray target quality"
  end

  def print_recommendations(base, gray, contrast, blue)
    puts "\n💡 RECOMMENDATIONS:"
    puts "-" * 80

    if base['level'] == :critical
      puts "❌ CROSSOVER DETECTED:"
      puts "   • Increase replenishment rate to 25-30ml per roll"
      puts "   • Check developer tank for air exposure"
      puts "   • Consider mixing fresh chemistry if >50 rolls processed"
      puts "   • Verify replenisher is fresh (not oxidized)"
    elsif base['level'] == :warning
      puts "⚠️  EARLY CROSSOVER WARNING:"
      puts "   • Monitor next 2-3 rolls closely"
      puts "   • Ensure proper tank sealing between sessions"
      puts "   • Consider increasing replenishment to 25ml/roll"
    end

    if contrast['level'] == :warning
      puts "\n⚠️  DEVELOPMENT STRENGTH DECLINING:"
      puts "   • Verify replenishment rate (should be 20-30ml/roll)"
      puts "   • Check developer temperature consistency"
      puts "   • Ensure replenisher is properly mixed"
    end

    if blue['level'] == :warning
      puts "\n⚠️  BLUE CHANNEL DRIFT (OXIDATION):"
      puts "   • Minimize air exposure in storage"
      puts "   • Check floating lid or nitrogen blanket"
      puts "   • Fresh chemistry may be needed soon"
    end

    if gray['level'] == :warning
      puts "\n⚠️  GRAY R/G OFF TARGET:"
      puts "   • Re-sample the gray target (same light, same spot) before acting on this"
    end

    all = [base, gray, contrast, blue]
    return unless all.none? { |s| [:warning, :critical].include?(s['level']) }

    puts "✅ No action needed - chemistry is performing well"
    puts "   • Current replenishment rate appears adequate"
    puts "   • Continue monitoring every 3-5 rolls"
    return unless all.any? { |s| s['level'] == :info }

    puts "   • Info items above are shifts that stayed within target or lacked corroboration"
  end

  def plot_trends
    batch = usable_batch
    return unless batch.length >= 5

    key = 'base_rg'
    batch = batch.select { |r| r['metrics'][key] }
    return unless batch.length >= 5

    puts "\n📊 RATIO TREND PLOT (dev #{batch.last['dev'] || 'untagged'}, last #{[batch.length, 10].min} usable rolls):"
    puts "-" * 80

    recent = batch.last(10)

    # Simple ASCII bar chart for film-base R/G (independent of gray target)
    values = recent.map { |r| r['metrics'][key] }
    min_val = values.min
    max_val = values.max
    range = max_val - min_val

    puts "Film base R/G Ratio (#{min_val.round(3)} to #{max_val.round(3)}):"

    values.each_with_index do |val, idx|
      roll_num = batch.length - recent.length + idx + 1
      normalized = range.positive? ? ((val - min_val) / range * 40).round : 20
      bar = '█' * normalized
      puts format("Roll %2d: %s %.3f", roll_num, bar, val)
    end
  end

  def generate_report(output_file = 'replenishment_report.txt')
    File.open(output_file, 'w') do |f|
      f.puts "C-41 REPLENISHMENT HEALTH REPORT"
      f.puts "Generated: #{Time.now.strftime('%Y-%m-%d %H:%M')}"
      f.puts "=" * 80
      f.puts "\nROLLS TRACKED: #{@history.length}"

      if @baseline
        f.puts "\nBASELINE METRICS (#{baseline_description}):"
        @baseline.each { |k, v| f.puts "  #{k}: #{v.round(3)}" }
      end

      f.puts "\nRECENT HISTORY:"
      recent = @history.last(10)
      recent.each_with_index do |roll, idx|
        f.puts "\n--- Roll #{@history.length - recent.length + idx + 1} ---"
        f.puts "Date: #{roll['date']}"
        f.puts "Dev: #{roll['dev']}" if roll['dev']
        f.puts "Film: #{roll['film_type']}"
        f.puts "Gray target: #{GRAY_LABELS[roll['gray_target'] || 'unknown']}"
        f.puts "Scan: THIN" if thin_scan?(roll)
        f.puts "Baseline roll" if roll['baseline']
        roll['metrics'].each { |k, v| f.puts "  #{k}: #{v.round(3)}" }
      end
    end

    puts "\n📄 Report saved to: #{output_file}"
  end

  private

  # Flags the matching rolls and returns them; aborts (changing nothing) if none match
  def mark_baseline(batch, rolls, dev)
    matched = batch.select { |r| rolls.include?(r['rolls_since_mix']) }
    if matched.empty?
      available = batch.filter_map { |r| r['rolls_since_mix'] }.join(', ')
      abort("❌ No rolls in dev #{dev} match --rolls #{rolls.join(',')} (available: #{available})")
    end

    batch.each { |r| matched.include?(r) ? r['baseline'] = true : r.delete('baseline') }
    missing = rolls - matched.map { |r| r['rolls_since_mix'] }
    puts "⚠️  Not found in dev #{dev}: #{missing.join(', ')}" if missing.any?
    thin = matched.select { |r| thin_scan?(r) }.map { |r| r['rolls_since_mix'] }
    puts "⚠️  Thin scans are ignored in the baseline: roll #{thin.join(', ')}" if thin.any?
    matched
  end

  def resolve_gray_target(value)
    if value
      return GRAY_TARGETS.fetch(value.to_s.downcase) do
        abort("Error: --gray must be one of: card, pavement, other")
      end
    end

    # Non-interactive runs (pipes, cron) can't be asked
    return 'unknown' unless $stdin.tty?

    last_used = @history.reverse.map { |r| r['gray_target'] }.find { |g| g && g != 'unknown' }
    prompt_gray_target(last_used)
  end

  def prompt_gray_target(default)
    puts "\n🎯 What did you sample as the gray target for this roll?"
    puts "   1) 18% gray card"
    puts "   2) pavement / concrete"
    puts "   3) other / not sure"
    default_choice = { 'card' => '1', 'pavement' => '2', 'other' => '3' }[default]
    print default_choice ? "Choice [#{default_choice}]: " : "Choice: "

    answer = $stdin.gets.to_s.strip
    answer = default_choice.to_s if answer.empty?

    target = GRAY_TARGETS[answer.downcase]
    unless target
      puts "Unrecognized answer, recording as 'other'"
      target = 'other'
    end
    target
  end

  def print_scan_line(roll)
    util = roll.dig('scan', 'utilization')
    return unless util

    puts "Scan exposure (film base): R #{util['r']}%  G #{util['g']}%  B #{util['b']}%#{'  🌑 THIN' if thin_scan?(roll)}"
  end

  # True when the latest value for any given ratio is outside tolerance.
  # With no target data (older history entries) don't suppress anything.
  def off_target?(targets, *keys)
    known = keys.map { |k| targets[k] }.compact
    return true if known.empty?

    known.any? { |t| %w[warning critical].include?(t['level']) }
  end

  def target_phrase(targets)
    targets.empty? ? '(no target data for this roll)' : 'and is off target'
  end

  def confidence_note(low_confidence)
    low_confidence ? ' (low confidence: gray target is not a card)' : ''
  end

  def signed_pct(fraction)
    format('%+.1f', fraction * 100)
  end

  def avg(array)
    array.sum / array.length.to_f
  end

  def median(array)
    sorted = array.sort
    mid = sorted.length / 2
    sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end
end

# Command line interface
def main
  if ARGV.empty?
    puts "C-41 Replenishment Health Checker"
    puts "\nUsage:"
    puts '  ruby replenishment_check.rb add <csv_file> [--rolls N] [--film TYPE] [--dev TAG] ' \
         "[--gray card|pavement|other] [--notes 'text']"
    puts "  (add also takes --baseline to mark that roll as part of the baseline)"
    puts "  ruby replenishment_check.rb baseline [--dev TAG] --rolls N,N,... | --clear"
    puts "  ruby replenishment_check.rb analyze"
    puts "  ruby replenishment_check.rb report"
    puts "  ruby replenishment_check.rb plot"
    puts "\nExample:"
    puts "  ruby replenishment_check.rb add roll_042.csv --rolls 42 --film 'Ultramax 400' --dev dev0937 --gray pavement"
    exit
  end

  command = ARGV.shift
  checker = ReplenishmentCheck.new

  case command
  when 'add'
    csv_file = ARGV.shift
    abort("Error: CSV file required") unless csv_file
    abort("Error: File not found: #{csv_file}") unless File.exist?(csv_file)

    options = { rolls_since_mix: nil, film_type: 'consumer', notes: '', dev: nil, gray_target: nil, baseline: false }

    # Parse options
    while ARGV.any?
      case ARGV.shift
      when '--rolls'
        options[:rolls_since_mix] = ARGV.shift.to_i
      when '--film'
        options[:film_type] = ARGV.shift
      when '--dev'
        options[:dev] = ARGV.shift
      when '--gray'
        options[:gray_target] = ARGV.shift
      when '--notes'
        options[:notes] = ARGV.shift
      when '--baseline'
        options[:baseline] = true
      end
    end

    checker.add_roll(csv_file, **options)

  when 'baseline'
    options = { dev: nil, rolls: [], clear: false }
    while ARGV.any?
      case ARGV.shift
      when '--dev'
        options[:dev] = ARGV.shift
      when '--rolls'
        options[:rolls] = ARGV.shift.to_s.split(',').map(&:to_i)
      when '--clear'
        options[:clear] = true
      end
    end
    checker.set_baseline(**options)

  when 'analyze'
    checker.analyze_replenishment_health

  when 'plot'
    checker.plot_trends

  when 'report'
    checker.generate_report

  else
    puts "Unknown command: #{command}"
    puts "Use: add, baseline, analyze, plot, or report"
  end
rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace if ENV['DEBUG']
  exit(1)
end

main if __FILE__ == $PROGRAM_NAME
