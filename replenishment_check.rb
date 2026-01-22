#!/usr/bin/env ruby
# Replenishment Health Checker for C-41
# Detects chemistry degradation and crossover issues across multiple rolls

# Add a new roll to tracking
# ruby replenishment_check.rb add my_scan.csv --rolls 42 --film "Ultramax 400"

# Analyze current chemistry health
# ruby replenishment_check.rb analyze

# View trend plots
# ruby replenishment_check.rb plot

# Generate full report
# ruby replenishment_check.rb report

require 'csv'
require 'json'
require 'date'

class ReplenishmentCheck
  # Thresholds for detecting chemistry issues
  CROSSOVER_WARNING = 0.03    # 3% shift in R/G ratio = early warning
  CROSSOVER_CRITICAL = 0.05   # 5% shift = serious crossover
  CONTRAST_DRIFT_WARNING = 0.04   # 4% loss in contrast
  BLUE_DRIFT_WARNING = 0.08   # 8% shift in blue behavior
  
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
  
  def add_roll(csv_file, rolls_since_mix: nil, film_type: 'consumer', notes: '')
    require_relative 'density_check' # Load the main validator
    
    # Run standard analysis
    validator = DensityCheck.new
    results = validator.analyze_from_single_csv(csv_file, 'Consumer_Films', 12)
    
    # Extract key metrics for tracking
    entry = {
      'date' => Time.now.strftime('%Y-%m-%d %H:%M'),
      'rolls_since_mix' => rolls_since_mix,
      'film_type' => film_type,
      'csv_file' => csv_file,
      'notes' => notes,
      'metrics' => extract_key_metrics(results)
    }
    
    @history << entry
    save_history
    
    puts "\n✅ Roll added to replenishment history (#{@history.length} total rolls tracked)"
    
    # Analyze if we have enough data
    analyze_replenishment_health if @history.length >= 2
    
    entry
  end
  
  def extract_key_metrics(results)
    ratios = results['ratio_analysis']['sample_ratios']
    
    {
      # Critical crossover indicators
      'gray_rg' => ratios[:gray_rg],
      'gray_rb' => ratios[:gray_rb],
      'gray_gb' => ratios[:gray_gb],
      'base_rg' => ratios[:base_rg],
      
      # Development strength indicators
      'r_contrast' => ratios[:r_contrast],
      'g_contrast' => ratios[:g_contrast],
      'b_contrast' => ratios[:b_contrast],
      
      # Timestamp for trend analysis
      'timestamp' => Time.now.to_i
    }
  end
  
  def calculate_baseline
    return nil if @history.length < 3
    
    # Use first 3-5 rolls as baseline (assuming fresh chemistry)
    baseline_rolls = @history.first([5, @history.length].min)
    metrics = baseline_rolls.map { |r| r['metrics'] }
    
    # Calculate average baseline values
    {
      'gray_rg' => avg(metrics.map { |m| m['gray_rg'] }),
      'gray_rb' => avg(metrics.map { |m| m['gray_rb'] }),
      'r_contrast' => avg(metrics.map { |m| m['r_contrast'] }),
      'g_contrast' => avg(metrics.map { |m| m['g_contrast'] }),
      'b_contrast' => avg(metrics.map { |m| m['b_contrast'] })
    }
  end
  
  def analyze_replenishment_health
    puts "\n" + "="*80
    puts "🧪 REPLENISHMENT HEALTH ANALYSIS"
    puts "="*80
    
    if @history.length < 2
      puts "⚠️  Need at least 2 rolls to analyze trends"
      return
    end
    
    # Get recent metrics
    latest = @history.last['metrics']
    previous = @history[-2]['metrics']
    
    puts "\n📊 ROLLS TRACKED: #{@history.length}"
    puts "Latest roll: #{@history.last['date']}"
    if @history.last['rolls_since_mix']
      puts "Rolls since fresh mix: #{@history.last['rolls_since_mix']}"
    end
    
    # Detect crossover
    crossover_status = detect_crossover(latest, previous)
    
    # Detect development strength loss
    contrast_status = detect_contrast_loss(latest, previous)
    
    # Detect blue channel drift (oxidation indicator)
    blue_status = detect_blue_drift(latest, previous)
    
    # Overall assessment
    print_overall_assessment(crossover_status, contrast_status, blue_status)
    
    # Long-term trend analysis if we have baseline
    if @baseline && @history.length >= 5
      print_trend_analysis
    end
    
    # Recommendations
    print_recommendations(crossover_status, contrast_status, blue_status)
  end
  
  def detect_crossover(latest, previous)
    # R/G ratio shift is the PRIMARY crossover indicator
    gray_rg_shift = ((latest['gray_rg'] - previous['gray_rg']) / previous['gray_rg']).abs
    base_rg_shift = ((latest['base_rg'] - previous['base_rg']) / previous['base_rg']).abs
    
    # Check if ratios are trending toward neutral (crossover symptom)
    gray_rg_trending_up = latest['gray_rg'] > previous['gray_rg']
    
    status = {
      'gray_rg_shift_pct' => gray_rg_shift * 100,
      'base_rg_shift_pct' => base_rg_shift * 100,
      'level' => :good
    }
    
    if gray_rg_shift > CROSSOVER_CRITICAL || base_rg_shift > CROSSOVER_CRITICAL
      status['level'] = :critical
      status['message'] = "❌ CRITICAL: Severe R/G ratio shift detected - possible crossover"
    elsif gray_rg_shift > CROSSOVER_WARNING
      status['level'] = :warning
      status['message'] = "⚠️  WARNING: R/G ratio shifting - monitor for crossover"
    else
      status['message'] = "✅ GOOD: R/G ratios stable"
    end
    
    status['trending_neutral'] = gray_rg_trending_up
    status
  end
  
  def detect_contrast_loss(latest, previous)
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
      status['level'] = :warning
      status['message'] = "⚠️  WARNING: Development strength declining - check replenishment rate"
    elsif avg_loss < -0.03
      status['level'] = :info
      status['message'] = "📊 INFO: Development strength increasing slightly"
    else
      status['message'] = "✅ GOOD: Development strength stable"
    end
    
    status
  end
  
  def detect_blue_drift(latest, previous)
    # Blue channel is sensitive to oxidation
    b_contrast_change = ((latest['b_contrast'] - previous['b_contrast']) / previous['b_contrast'])
    gray_rb_change = ((latest['gray_rb'] - previous['gray_rb']) / previous['gray_rb'])
    
    status = {
      'b_contrast_change_pct' => b_contrast_change * 100,
      'gray_rb_change_pct' => gray_rb_change * 100,
      'level' => :good
    }
    
    if b_contrast_change.abs > BLUE_DRIFT_WARNING
      status['level'] = :warning
      status['message'] = "⚠️  WARNING: Blue channel behavior changing - possible oxidation"
    else
      status['message'] = "✅ GOOD: Blue channel stable"
    end
    
    status
  end
  
  def print_overall_assessment(crossover, contrast, blue)
    puts "\n🎯 OVERALL CHEMISTRY STATUS:"
    puts crossover['message']
    puts contrast['message']
    puts blue['message']
    
    # Determine if chemistry needs attention
    critical_count = [crossover, contrast, blue].count { |s| s['level'] == :critical }
    warning_count = [crossover, contrast, blue].count { |s| s['level'] == :warning }
    
    puts "\n" + "="*80
    if critical_count > 0
      puts "🚨 ACTION REQUIRED: Chemistry showing critical degradation"
    elsif warning_count >= 2
      puts "⚠️  MONITOR CLOSELY: Multiple warning signs detected"
    elsif warning_count == 1
      puts "📊 MONITOR: One parameter trending outside normal range"
    else
      puts "✅ CHEMISTRY HEALTHY: All parameters stable"
    end
    puts "="*80
  end
  
  def print_trend_analysis
    puts "\n📈 LONG-TERM TREND ANALYSIS:"
    puts "Baseline (first 3-5 rolls) vs Latest roll:"
    puts "-" * 80
    
    latest = @history.last['metrics']
    
    [
      ['R/G Ratio (Gray)', 'gray_rg', CROSSOVER_WARNING],
      ['R Contrast', 'r_contrast', CONTRAST_DRIFT_WARNING],
      ['G Contrast', 'g_contrast', CONTRAST_DRIFT_WARNING],
      ['B Contrast', 'b_contrast', BLUE_DRIFT_WARNING]
    ].each do |label, key, threshold|
      baseline_val = @baseline[key]
      latest_val = latest[key]
      drift_pct = ((latest_val - baseline_val) / baseline_val).abs * 100
      
      icon = drift_pct > (threshold * 100) ? '⚠️' : '✅'
      
      puts "%-25s Baseline: %.3f  Latest: %.3f  Drift: %+.1f%% %s" % 
        [label, baseline_val, latest_val, drift_pct, icon]
    end
  end
  
  def print_recommendations(crossover, contrast, blue)
    puts "\n💡 RECOMMENDATIONS:"
    puts "-" * 80
    
    if crossover['level'] == :critical
      puts "❌ CROSSOVER DETECTED:"
      puts "   • Increase replenishment rate to 25-30ml per roll"
      puts "   • Check developer tank for air exposure"
      puts "   • Consider mixing fresh chemistry if >50 rolls processed"
      puts "   • Verify replenisher is fresh (not oxidized)"
    elsif crossover['level'] == :warning
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
    
    if [crossover, contrast, blue].all? { |s| s['level'] == :good }
      puts "✅ No action needed - chemistry is performing well"
      puts "   • Current replenishment rate appears adequate"
      puts "   • Continue monitoring every 3-5 rolls"
    end
  end
  
  def plot_trends
    return unless @history.length >= 5
    
    puts "\n📊 RATIO TREND PLOT (last #{[@history.length, 10].min} rolls):"
    puts "-" * 80
    
    recent = @history.last(10)
    
    # Simple ASCII sparkline for R/G ratio
    values = recent.map { |r| r['metrics']['gray_rg'] }
    min_val = values.min
    max_val = values.max
    range = max_val - min_val
    
    puts "Gray R/G Ratio (#{min_val.round(3)} to #{max_val.round(3)}):"
    
    # Create simple bar chart
    values.each_with_index do |val, idx|
      roll_num = @history.length - recent.length + idx + 1
      normalized = range > 0 ? ((val - min_val) / range * 40).round : 20
      bar = '█' * normalized
      puts "Roll %2d: %s %.3f" % [roll_num, bar, val]
    end
  end
  
  def generate_report(output_file = 'replenishment_report.txt')
    File.open(output_file, 'w') do |f|
      f.puts "C-41 REPLENISHMENT HEALTH REPORT"
      f.puts "Generated: #{Time.now.strftime('%Y-%m-%d %H:%M')}"
      f.puts "="*80
      f.puts "\nROLLS TRACKED: #{@history.length}"
      
      if @baseline
        f.puts "\nBASELINE METRICS (first 3-5 rolls):"
        @baseline.each { |k, v| f.puts "  #{k}: #{v.round(3)}" }
      end
      
      f.puts "\nRECENT HISTORY:"
      @history.last(10).each_with_index do |roll, idx|
        f.puts "\n--- Roll #{@history.length - 10 + idx + 1} ---"
        f.puts "Date: #{roll['date']}"
        f.puts "Film: #{roll['film_type']}"
        roll['metrics'].each { |k, v| f.puts "  #{k}: #{v.round(3)}" }
      end
    end
    
    puts "\n📄 Report saved to: #{output_file}"
  end
  
  private
  
  def avg(array)
    array.sum / array.length.to_f
  end
end

# Command line interface
def main
  if ARGV.empty?
    puts "C-41 Replenishment Health Checker"
    puts "\nUsage:"
    puts "  ruby replenishment_check.rb add <csv_file> [--rolls N] [--film TYPE] [--notes 'text']"
    puts "  ruby replenishment_check.rb analyze"
    puts "  ruby replenishment_check.rb report"
    puts "  ruby replenishment_check.rb plot"
    puts "\nExample:"
    puts "  ruby replenishment_check.rb add roll_042.csv --rolls 42 --film 'Ultramax 400'"
    exit
  end
  
  command = ARGV.shift
  checker = ReplenishmentCheck.new
  
  case command
  when 'add'
    csv_file = ARGV.shift
    abort("Error: CSV file required") unless csv_file
    abort("Error: File not found: #{csv_file}") unless File.exist?(csv_file)
    
    options = { rolls_since_mix: nil, film_type: 'consumer', notes: '' }
    
    # Parse options
    while ARGV.any?
      case ARGV.shift
      when '--rolls'
        options[:rolls_since_mix] = ARGV.shift.to_i
      when '--film'
        options[:film_type] = ARGV.shift
      when '--notes'
        options[:notes] = ARGV.shift
      end
    end
    
    checker.add_roll(csv_file, **options)
    
  when 'analyze'
    checker.analyze_replenishment_health
    
  when 'plot'
    checker.plot_trends
    
  when 'report'
    checker.generate_report
    
  else
    puts "Unknown command: #{command}"
    puts "Use: add, analyze, plot, or report"
  end
  
rescue StandardError => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace if ENV['DEBUG']
  exit(1)
end

main if __FILE__ == $PROGRAM_NAME