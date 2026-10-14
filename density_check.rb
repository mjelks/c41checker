#!/usr/bin/env ruby
# frozen_string_literal: true

# Integrated DSLR C-41 Development Validator
# Combines flexible DSLR profiles with ratio-based analysis
# Focus: Cross-channel issues and over/under-development detection

require 'csv'
require 'json'
require 'optparse'
# require 'debug' # binding.break to use breakpoints

ChannelStats = Struct.new(:min_val, :max_val, :avg, :std_dev)
MeasurementData = Struct.new(:r, :g, :b, :g2)

# Validates C-41 development from DSLR scans of a gray card and film base,
# combining channel-ratio analysis (primary) with relaxed density checks (secondary).
class DensityCheck
  SOFT_TOLERANCE = 0.05 # Increased for DSLR flexibility

  attr_accessor :gray_card_data, :film_base_data, :film_stock, :ratio_profile

  def initialize(ratio_profile = 'Consumer_Films', config_path = File.join(__dir__, 'profiles.json'))
    @ratio_profile = ratio_profile
    load_config(config_path)
    @gray_card_data = nil
    @film_base_data = nil
    @film_stock = :DSLR_Flexible
  end

  def load_config(path)
    raise "Configuration file missing: #{path}. Please ensure profiles.json is in the root." unless File.exist?(path)

    config = JSON.parse(File.read(path), symbolize_names: true)
    @density_profiles = config[:FILM_DENSITY_PROFILES]
    @reference_ratios = config[:DSLR_REFERENCE_RATIOS]
  end

  def analyze_development(bit_depth = 14)
    raise 'Both gray card and film base measurements required' unless @gray_card_data && @film_base_data

    bit_depth, reference_white = get_bit_depth_and_reference(bit_depth)

    # Traditional density analysis (relaxed for DSLR)
    density_results = perform_density_analysis(reference_white)

    # Ratio-based analysis (primary focus)
    ratio_results = perform_ratio_analysis

    # Combined assessment prioritizing ratio analysis
    overall_status = determine_combined_status(density_results, ratio_results)

    {
      'analysis_type' => 'DSLR_INTEGRATED',
      'bit_depth' => bit_depth,
      'reference_white' => reference_white,
      'ratio_profile' => @ratio_profile,
      'density_analysis' => density_results,
      'ratio_analysis' => ratio_results,
      'overall_status' => overall_status
    }
  end

  def analyze_from_single_csv(csv_file, ratio_profile = 'Consumer_Films', bit_depth = 14)
    puts "📊 Loading DSLR scan data: #{csv_file}"
    puts "🎯 Using ratio profile: #{ratio_profile}"

    raise "CSV file not found: #{csv_file}" unless File.exist?(csv_file)

    rows = CSV.read(csv_file, headers: true)
    raise 'CSV file must contain at least 2 rows (gray card + film base)' if rows.length < 2

    # Parse data
    gray_data = parse_raw_digger_row(rows[0])
    base_data = parse_raw_digger_row(rows[1])

    puts "   Sample 1 (Gray Card): #{rows[0]['Sample_Name'] || 'Unknown'}"
    puts "   Sample 2 (Film Base): #{rows[1]['Sample_Name'] || 'Unknown'}"

    @gray_card_data = dict_to_measurement_data(gray_data)
    @film_base_data = dict_to_measurement_data(base_data)

    results = analyze_development(bit_depth)
    print_integrated_results(results)
    results
  end

  private

  def get_bit_depth_and_reference(bit_depth = 14)
    case bit_depth
    when 12
      reference_white = 4095
    when 14
      reference_white = 16_383
    when 16
      reference_white = 65_535
    else
      puts "⚠️  Unsupported bit depth: #{bit_depth}, defaulting to 14-bit"
      bit_depth = 14
      reference_white = 16_383
    end

    [bit_depth, reference_white]
  end

  def perform_density_analysis(reference_white)
    density_results = {
      'gray_card_densities' => {},
      'film_base_densities' => {},
      'validation' => {},
      'notes' => []
    }

    %w[r g b].each do |channel|
      gray_avg = @gray_card_data.send(channel).avg
      base_avg = @film_base_data.send(channel).avg

      gray_density = calculate_density(gray_avg, reference_white)
      base_density = calculate_density(base_avg, reference_white)
      net_density = gray_density - base_density

      density_results['gray_card_densities'][channel] = net_density
      density_results['film_base_densities'][channel] = base_density

      # Validate against relaxed DSLR profile
      target_min, target_max = @density_profiles[@film_stock][:gray_card_density][channel.to_sym]
      in_range = (target_min..target_max).cover?(net_density)

      density_results['validation'][channel] = {
        'in_spec' => in_range,
        'density' => net_density,
        'target_range' => [target_min, target_max]
      }

      # Add notes for out-of-range values (but don't fail)
      next if in_range

      side, bound = net_density < target_min ? ['under', "#{target_min}+"] : ['over', "#{target_max}-"]
      density_results['notes'] << "#{channel.upcase} slightly #{side} target " \
                                  "(#{net_density.round(3)} vs #{bound}) - monitor development time"
    end
    density_results
  end

  def perform_ratio_analysis
    # Calculate sample ratios
    gray_data = {
      r: @gray_card_data.r.avg,
      g: @gray_card_data.g.avg,
      b: @gray_card_data.b.avg
    }
    base_data = {
      r: @film_base_data.r.avg,
      g: @film_base_data.g.avg,
      b: @film_base_data.b.avg
    }

    sample_ratios = {
      gray_rg: gray_data[:r] / gray_data[:g],
      gray_rb: gray_data[:r] / gray_data[:b],
      gray_gb: gray_data[:g] / gray_data[:b],
      base_rg: base_data[:r] / base_data[:g],
      base_rb: base_data[:r] / base_data[:b],
      base_gb: base_data[:g] / base_data[:b],
      r_contrast: gray_data[:r] / base_data[:r],
      g_contrast: gray_data[:g] / base_data[:g],
      b_contrast: gray_data[:b] / base_data[:b]
    }

    # Compare against reference ratios
    reference = @reference_ratios[@ratio_profile.to_sym][:ratios]
    comparisons = {}
    issues = []
    critical_issues = []

    sample_ratios.each do |ratio_name, sample_value|
      ref_data = reference[ratio_name]
      target = ref_data[:target]
      tolerance = ref_data[:tolerance]

      deviation = (sample_value - target).abs / target
      within_tolerance = deviation <= tolerance

      status = if deviation <= tolerance * 0.5
                 { level: :excellent, icon: '✅', desc: 'Excellent' }
               elsif within_tolerance
                 { level: :good, icon: '✅', desc: 'Good' }
               elsif deviation <= tolerance * 1.5
                 { level: :warning, icon: '⚠️', desc: 'Warning' }
               else
                 { level: :critical, icon: '❌', desc: 'Critical' }
               end

      comparisons[ratio_name] = {
        sample: sample_value,
        target: target,
        deviation_pct: deviation * 100,
        within_tolerance: within_tolerance,
        status: status
      }

      # Flag development timing issues (most important)
      if [:r_contrast, :g_contrast].include?(ratio_name) && status[:level] == :critical
        critical_issues << "#{ratio_name.to_s.upcase.gsub('_', ' ')} ratio significantly off - check development timing"
      elsif [:r_contrast, :g_contrast].include?(ratio_name) && status[:level] == :warning
        issues << "#{ratio_name.to_s.upcase.gsub('_', ' ')} ratio slightly off - monitor development"
      end

      # Flag crossover issues
      if ratio_name == :gray_rg && status[:level] == :critical
        critical_issues << "R/G ratio critical - possible crossover or development imbalance"
      elsif ratio_name == :gray_rg && status[:level] == :warning
        issues << "R/G ratio off - monitor for crossover effects"
      end
    end

    {
      'sample_ratios' => sample_ratios,
      'comparisons' => comparisons,
      'issues' => issues,
      'critical_issues' => critical_issues
    }
  end

  def determine_combined_status(density_results, ratio_results)
    critical_count = ratio_results['critical_issues'].length
    warning_count = ratio_results['issues'].length
    density_issues = density_results['notes'].length

    if critical_count >= 2
      'CRITICAL - Multiple development issues detected'
    elsif critical_count == 1
      'WARNING - One critical ratio issue detected'
    elsif warning_count >= 3
      'WARNING - Multiple minor issues detected'
    elsif warning_count.positive? || density_issues > 1
      'MONITOR - Some parameters outside ideal range'
    else
      'GOOD - Development within expected parameters'
    end
  end

  def calculate_density(measured_value, reference_white)
    return Float::INFINITY if measured_value <= 0

    Math.log10(reference_white / measured_value)
  end

  def print_integrated_results(results)
    puts "\n#{'=' * 80}"
    puts "DSLR C-41 DEVELOPMENT ANALYSIS - INTEGRATED APPROACH"
    puts "=" * 80

    puts "\n📊 SCAN PARAMETERS:"
    puts "Bit Depth: #{results['bit_depth']}-bit"
    puts "Analysis Profile: #{results['ratio_profile']}"
    puts "Focus: Cross-channel balance & development timing"

    # Overall Status
    puts "\n🎯 OVERALL ASSESSMENT: #{results['overall_status']}"

    # Critical Issues First (most important)
    critical = results['ratio_analysis']['critical_issues']
    if critical.any?
      puts "\n#{'CRITICAL ISSUES'.center(80, '❌')}"
      critical.each { |issue| puts "❌ #{issue}" }
    end

    # Warnings
    warnings = results['ratio_analysis']['issues']
    if warnings.any?
      puts "\n#{'MONITORING POINTS'.center(80, '⚠')}"
      warnings.each { |issue| puts "⚠️  #{issue}" }
    end

    # Ratio Analysis (Primary)
    print_ratio_analysis_section(results['ratio_analysis'])

    # Density Analysis (Secondary - for reference)
    print_density_reference_section(results['density_analysis'])

    # DSLR-specific recommendations
    print_dslr_recommendations(results)
  end

  def print_ratio_analysis_section(ratio_analysis)
    puts "\n#{'RATIO ANALYSIS (PRIMARY)'.center(80, '-')}"
    puts "Ratio           Sample   Target   Dev%     Status   Notes"
    puts "-" * 80

    # Group ratios by importance
    critical_ratios = [:r_contrast, :g_contrast, :gray_rg]
    monitoring_ratios = [:gray_rb, :gray_gb, :base_rg, :b_contrast]
    reference_ratios = [:base_rb, :base_gb]

    [
      ["🎯 DEVELOPMENT TIMING", critical_ratios],
      ["📊 MONITORING", monitoring_ratios],
      ["📋 REFERENCE", reference_ratios]
    ].each do |section_name, ratios|
      puts "\n#{section_name}:"
      ratios.each do |ratio_name|
        next unless ratio_analysis['comparisons'][ratio_name]

        comp = ratio_analysis['comparisons'][ratio_name]
        puts format("%-15s %-8.3f %-8.3f %-8.1f %-8s %s", ratio_name.to_s.gsub('_', '-'), comp[:sample], comp[:target],
                    comp[:deviation_pct], comp[:status][:icon], comp[:status][:desc])
      end
    end
  end

  def print_density_reference_section(density_analysis)
    puts "\n#{'DENSITY REFERENCE (SECONDARY)'.center(80, '-')}"
    puts "Note: Density ranges are very relaxed for DSLR scanning"

    %w[r g b].each do |channel|
      val = density_analysis['validation'][channel]
      density = val['density']
      range = val['target_range']
      status = val['in_spec'] ? '✅' : '📋'

      puts "#{channel.upcase}: #{density.round(3)} (target: #{range[0]}-#{range[1]}) #{status}"
    end

    return unless density_analysis['notes'].any?

    puts "\nDensity Notes:"
    density_analysis['notes'].each { |note| puts "📋 #{note}" }
  end

  def analyze_scan_health(reference_white)
    health_report = {}

    %w[r g b].each do |channel|
      base_avg = @film_base_data.send(channel).avg
      gray_avg = @gray_card_data.send(channel).avg

      # 1. Sensor Utilization (How much of the bit-depth is used by the brightest point)
      utilization = (base_avg / reference_white.to_f) * 100

      # 2. Absolute Density (D-Min / Base Fog)
      # This measures the "thickness" of the orange mask relative to the sensor max
      abs_density = Math.log10(reference_white / base_avg)

      # 3. Dynamic Range used (in EV/Stops)
      # How much of the sensor's latitude the negative occupies
      range_ev = Math.log2(base_avg / gray_avg)

      health_report[channel] = {
        utilization: utilization,
        abs_density: abs_density,
        range_ev: range_ev,
        status: interpret_utilization(utilization)
      }
    end
    health_report
  end

  def interpret_utilization(pct)
    return { label: 'CLIPPING', icon: '🚫', color: :red } if pct > 95
    return { label: 'OPTIMAL', icon: '💎', color: :green } if pct >= 70
    return { label: 'ACCEPTABLE', icon: '⚠️', color: :yellow } if pct >= 40

    { label: 'THIN SCAN (NOISY)', icon: '🌑', color: :red }
  end

  def print_dslr_recommendations(results)
    puts "\n#{'📸 SCAN QUALITY & DENSITY TELEMETRY'.center(80, '-')}"

    health = analyze_scan_health(results['reference_white'])

    puts "Channel    Utilization     Abs Density  Range (EV)      Status    "
    puts "-" * 80

    %w[r g b].each do |ch|
      h = health[ch]
      puts format("%-10s %-15s %-12.2f %-15.2f %-10s %s",
                  ch.upcase, "#{h[:utilization].round(1)}%", h[:abs_density], h[:range_ev],
                  h[:status][:icon], h[:status][:label])
    end

    puts "\n💡 FIXING SCAN DENSITY:"

    # Logic for specific advice
    max_util = health.values.map { |v| v[:utilization] }.max

    if max_util < 50
      puts "👉 YOUR SCAN IS TOO DARK: You are wasting bit-depth."
      puts "   Action: Increase exposure (slower shutter/wider aperture) until Red or Green hits ~85%."
    elsif max_util > 95
      puts "👉 SCAN IS CLIPPING: You are losing film base detail."
      puts "   Action: Decrease exposure slightly. The film base must not hit the sensor ceiling."
    else
      puts "✅ EXPOSURE IS SOLID: You are maximizing the signal-to-noise ratio."
    end

    puts "\n🧪 DEVELOPMENT INSIGHTS:"
    # (Your existing development logic here...)
  end

  # Helper methods for CSV parsing
  def parse_raw_digger_row(row)
    channel_data = {}
    channels = [
      %w[r Rmin Ravg Rmax Rdev],
      %w[g Gmin Gavg Gmax Gdev],
      %w[b Bmin Bavg Bmax Bdev],
      %w[g2 G2min G2avg G2max G2dev]
    ]

    channels.each do |channel_key, min_col, avg_col, max_col, dev_col|
      next unless [min_col, avg_col, max_col, dev_col].all? { |col| row[col] }

      channel_data[channel_key] = {
        'min' => row[min_col].to_f,
        'max' => row[max_col].to_f,
        'avg' => row[avg_col].to_f,
        'std_dev' => row[dev_col].to_f
      }
    end

    missing = %w[r g b g2] - channel_data.keys
    raise "Missing channel data: #{missing}" if missing.any?

    channel_data
  end

  def dict_to_measurement_data(data_dict)
    MeasurementData.new(
      ChannelStats.new(data_dict['r']['min'], data_dict['r']['max'], data_dict['r']['avg'], data_dict['r']['std_dev']),
      ChannelStats.new(data_dict['g']['min'], data_dict['g']['max'], data_dict['g']['avg'], data_dict['g']['std_dev']),
      ChannelStats.new(data_dict['b']['min'], data_dict['b']['max'], data_dict['b']['avg'], data_dict['b']['std_dev']),
      ChannelStats.new(data_dict['g2']['min'], data_dict['g2']['max'], data_dict['g2']['avg'], data_dict['g2']['std_dev'])
    )
  end
end

# Test function for ProImage 100
def test_proimage_100
  puts "🧪 Testing ProImage 100 Analysis"
  puts "=" * 80

  # ProImage 100 data
  proimage_gray = { r: 671.76, g: 590.52, b: 155.98 }
  proimage_base = { r: 2125.40, g: 2354.93, b: 1430.95 }

  puts "\n📊 RAW VALUES:"
  puts "Gray Card: R=#{proimage_gray[:r]}, G=#{proimage_gray[:g]}, B=#{proimage_gray[:b]}"
  puts "Film Base: R=#{proimage_base[:r]}, G=#{proimage_base[:g]}, B=#{proimage_base[:b]}"

  # Calculate ratios manually for quick analysis
  gray_rg = proimage_gray[:r] / proimage_gray[:g]
  gray_rb = proimage_gray[:r] / proimage_gray[:b]
  gray_gb = proimage_gray[:g] / proimage_gray[:b]
  base_rg = proimage_base[:r] / proimage_base[:g]
  r_contrast = proimage_gray[:r] / proimage_base[:r]
  g_contrast = proimage_gray[:g] / proimage_base[:g]

  puts "\n📈 KEY RATIOS:"
  puts "Gray R/G: #{gray_rg.round(3)} (Consumer target: ~1.09, Pro target: ~1.30)"
  puts "Gray R/B: #{gray_rb.round(3)} (Consumer target: ~3.34, Pro target: ~5.26)"
  puts "Gray G/B: #{gray_gb.round(3)} (Consumer target: ~3.08, Pro target: ~4.05)"
  puts "Base R/G: #{base_rg.round(3)} (Consumer target: ~0.89, Pro target: ~0.93)"
  puts "R Contrast: #{r_contrast.round(3)} (Consumer target: ~0.51, Pro target: ~0.48)"
  puts "G Contrast: #{g_contrast.round(3)} (Consumer target: ~0.42, Pro target: ~0.35)"

  puts "\n🎯 PROFILE RECOMMENDATION:"
  if gray_rg < 1.2 && gray_rb < 4.5 && r_contrast > 0.45
    puts "✅ Use Consumer_Films profile - ProImage behaves like consumer film"
  else
    puts "📊 Use Professional_Films profile - ProImage shows pro film characteristics"
  end

  puts "\n🔵 BLUE CHANNEL ANALYSIS:"
  blue_raw_ratio = proimage_gray[:b] / ((proimage_gray[:r] + proimage_gray[:g]) / 2.0)
  puts "Blue vs R/G average: #{(blue_raw_ratio * 100).round(1)}% (#{(-Math.log2(1 / blue_raw_ratio)).round(1)} EV deficit)"

  if blue_raw_ratio < 0.3
    puts "⚠️  Significant blue underexposure - typical for DSLR scanning"
  else
    puts "✅ Blue exposure reasonable for DSLR scanning"
  end

  puts "\n#{'=' * 80}"
end

# Command line interface
def main
  if ARGV.length.positive?
    options = { bit_depth: 14, profile: 'Consumer_Films' }

    OptionParser.new do |opts|
      opts.banner = 'Usage: ruby dslr_validator.rb <csv_file> [options]'
      opts.on('--bit-depth N', Integer, 'Bit depth (default: 14)') { |n| options[:bit_depth] = n }
      opts.on('--profile NAME', String, 'Ratio profile: Consumer_Films or Professional_Films') { |name| options[:profile] = name }
      opts.on('-h', '--help', 'Show this help') do
        puts opts
        puts "\nRatio Profiles:"
        puts "  Consumer_Films - For Ultramax, Gold, etc. (default)"
        puts "  Professional_Films - For Portra, Ektar, etc."
        puts "\nFocus: Cross-channel balance and development timing for DSLR scanning"
        exit
      end
    end.parse!(ARGV)

    csv_file = ARGV.shift
    abort("Error: CSV file required") if csv_file.nil?
    abort("❌ File not found: #{csv_file}") unless File.exist?(csv_file)

    validator = DensityCheck.new(options[:profile])
    validator.analyze_from_single_csv(csv_file, options[:profile], options[:bit_depth])
  else
    puts "DSLR C-41 Development Validator"
    puts "Usage: ruby dslr_validator.rb <csv_file> [--profile Consumer_Films|Professional_Films]"
    puts "Focus: Development timing and cross-channel balance"
    puts "\nTest Functions:"
    puts "• Run 'test_proimage_100' to analyze ProImage 100 characteristics"
  end

  # Quick test for ProImage 100 if requested
  test_proimage_100 if ARGV.include?('test_proimage')
rescue StandardError => e
  puts "Error: #{e.message}"
  exit(1)
end

main if __FILE__ == $PROGRAM_NAME
