#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'json'
require 'optparse'
require 'byebug'

# Enhanced C-41 Development Validation Tool
# Added blue channel diagnostics and DSLR scanning specific adjustments

ChannelStats = Struct.new(:min_val, :max_val, :avg, :std_dev)
MeasurementData = Struct.new(:r, :g, :b, :g2)

class C41Validator
  SOFT_TOLERANCE = 0.03
  
  # Enhanced film profiles with DSLR scanning considerations
  FILM_DENSITY_PROFILES = {
    'Ektar' => {
      gray_card_density: {
        'r' => [0.20, 0.40],
        'g' => [0.22, 0.42],
        'b' => [0.25, 0.45]
      },
      base_plus_fog: {
        'r' => [0.75, 0.95],
        'g' => [0.70, 0.90],
        'b' => [0.80, 1.00]
      },
      crossover_thresholds: {
        'rg_diff' => 0.15,
        'rb_diff' => 0.20,
        'gb_diff' => 0.15
      }
    },
    'Portra' => {
      gray_card_density: {
        'r' => [0.22, 0.36],
        'g' => [0.24, 0.38],
        'b' => [0.28, 0.42]
      },
      base_plus_fog: {
        'r' => [0.70, 0.90],
        'g' => [0.68, 0.88],
        'b' => [0.78, 0.98]
      },
      crossover_thresholds: {
        'rg_diff' => 0.08,
        'rb_diff' => 0.12,
        'gb_diff' => 0.08
      }
    },
    'Gold' => {
      gray_card_density: {
        'r' => [0.26, 0.42],
        'g' => [0.28, 0.45],
        'b' => [0.34, 0.50]
      },
      base_plus_fog: {
        'r' => [0.78, 0.98],
        'g' => [0.74, 0.94],
        'b' => [0.84, 1.05]
      },
      crossover_thresholds: {
        'rg_diff' => 0.12,
        'rb_diff' => 0.18,
        'gb_diff' => 0.12
      }
    },
    # New profile for DSLR scanning with adjusted blue channel expectations
    'DSLR_Generic' => {
      gray_card_density: {
        'r' => [0.20, 0.40],
        'g' => [0.22, 0.42],
        # 'b' => [0.50, 0.80]  # Higher blue density expected for DSLR scanning
        'b' => [0.50, 1.20]  # Higher blue density expected for DSLR scanning
      },
      base_plus_fog: {
        'r' => [0.75, 0.95],
        'g' => [0.70, 0.90],
        'b' => [1.00, 1.30]  # Higher blue base density for DSLR
      },
      crossover_thresholds: {
        'rg_diff' => 0.15,
        'rb_diff' => 0.35,  # Allow larger R-B difference
        'gb_diff' => 0.30   # Allow larger G-B difference
      }
    }
  }.freeze

  attr_accessor :gray_card_data, :film_base_data, :film_stock

  def initialize(film_stock = 'Gold')
    @gray_card_data = nil
    @film_base_data = nil
    @film_stock = film_stock
  end

  def input_measurements
    puts '=== C-41 Development Validation Tool ==='
    puts

    # Input gray card measurements
    puts '1. GRAY CARD MEASUREMENTS'
    puts 'Enter Raw Digger values for your 18% gray card:'
    @gray_card_data = input_channel_data('Gray Card')

    puts "\n#{'=' * 50}\n"

    # Input film base measurements
    puts '2. FILM BASE MEASUREMENTS'
    puts 'Enter Raw Digger values for film base layer:'
    @film_base_data = input_channel_data('Film Base')
  end

  def input_channel_data(_measurement_type)
    channels = {}

    %w[R G B G2].each do |channel|
      puts "\n#{channel} Channel:"
      print '  Min: '
      min_val = gets.chomp.to_f
      print '  Max: '
      max_val = gets.chomp.to_f
      print '  Avg: '
      avg = gets.chomp.to_f
      print '  σ (std dev): '
      std_dev = gets.chomp.to_f

      channels[channel.downcase] = ChannelStats.new(min_val, max_val, avg, std_dev)
    end

    MeasurementData.new(
      channels['r'],
      channels['g'],
      channels['b'],
      channels['g2']
    )
  end

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

    puts "📊 Using #{bit_depth}-bit (Reference White: #{reference_white})"

    [bit_depth, reference_white]
  end

  def calculate_density(measured_value, reference_white)
    return Float::INFINITY if measured_value <= 0
    Math.log10(reference_white / measured_value)
  end

  def analyze_development(bit_depth = 14)
    raise 'Both gray card and film base measurements required' unless @gray_card_data && @film_base_data

    bit_depth, reference_white = get_bit_depth_and_reference(bit_depth)
    results = {
      'bit_depth' => bit_depth,
      'reference_white' => reference_white,
      'gray_card_densities' => {},
      'film_base_densities' => {},
      'gray_card_validation' => {},
      'base_fog_validation' => {},
      'crossover_analysis' => {},
      'blue_channel_analysis' => {},  # New section
      'scanning_diagnostics' => {},   # New section
      'overall_status' => 'UNKNOWN'
    }

    # Calculate densities for gray card
    %w[r g b].each do |channel|
      gray_avg = @gray_card_data.send(channel).avg
      base_avg = @film_base_data.send(channel).avg

      gray_density = calculate_density(gray_avg, reference_white)
      base_density = calculate_density(base_avg, reference_white)
      net_density = gray_density - base_density

      results['gray_card_densities'][channel] = {
        'raw_density' => gray_density,
        'net_density' => net_density,
        'measured_value' => gray_avg
      }

      results['film_base_densities'][channel] = {
        'density' => base_density,
        'measured_value' => base_avg
      }

      # Validate against specs
      target_min, target_max = FILM_DENSITY_PROFILES[@film_stock][:gray_card_density][channel]
      results['gray_card_validation'][channel] = {
        'in_spec' => (target_min..target_max).cover?(net_density),
        'density' => net_density,
        'target_range' => [target_min, target_max],
        'deviation' => [net_density - target_min, target_max - net_density].map(&:abs).min
      }

      # Validate base + fog
      base_min, base_max = FILM_DENSITY_PROFILES[@film_stock][:base_plus_fog][channel]
      results['base_fog_validation'][channel] = {
        'in_spec' => (base_min..base_max).cover?(base_density),
        'density' => base_density,
        'target_range' => [base_min, base_max]
      }
    end

    # Enhanced blue channel analysis
    results['blue_channel_analysis'] = analyze_blue_channel_issues(results)
    
    # DSLR scanning diagnostics
    results['scanning_diagnostics'] = analyze_scanning_setup(results)

    # Analyze crossover
    r_density = results['gray_card_densities']['r']['net_density']
    g_density = results['gray_card_densities']['g']['net_density']
    b_density = results['gray_card_densities']['b']['net_density']

    rg_diff = (r_density - g_density).abs
    rb_diff = (r_density - b_density).abs
    gb_diff = (g_density - b_density).abs
    
    results['crossover_analysis'] = {
      'rg_difference' => rg_diff,
      'rb_difference' => rb_diff,
      'gb_difference' => gb_diff,
      'rg_crossover' => rg_diff > FILM_DENSITY_PROFILES[@film_stock][:crossover_thresholds]['rg_diff'],
      'rb_crossover' => rb_diff > FILM_DENSITY_PROFILES[@film_stock][:crossover_thresholds]['rb_diff'],
      'gb_crossover' => gb_diff > FILM_DENSITY_PROFILES[@film_stock][:crossover_thresholds]['gb_diff']
    }

    # Enhanced overall status calculation
    gray_card_status = check_measurements_with_soft_tolerance(results['gray_card_validation'], SOFT_TOLERANCE)
    base_fog_status = check_measurements_with_soft_tolerance(results['base_fog_validation'], SOFT_TOLERANCE)

    has_crossover = results['crossover_analysis'].values_at('rg_crossover', 'rb_crossover', 'gb_crossover').any?
    has_blue_issues = results['blue_channel_analysis']['has_issues']
    
    results['overall_status'] = determine_overall_status(gray_card_status, base_fog_status, has_crossover, has_blue_issues)

    results
  end

  def analyze_blue_channel_issues(results)
    r_net = results['gray_card_densities']['r']['net_density']
    g_net = results['gray_card_densities']['g']['net_density']
    b_net = results['gray_card_densities']['b']['net_density']
    
    r_base = results['film_base_densities']['r']['density']
    g_base = results['film_base_densities']['g']['density']
    b_base = results['film_base_densities']['b']['density']

    # Blue channel specific diagnostics
    blue_issues = []
    severity = 'none'

    # Check if blue is significantly higher than red/green
    rg_avg = (r_net + g_net) / 2.0
    blue_excess = b_net - rg_avg

    if blue_excess > 0.3
      blue_issues << "Blue density significantly higher than R/G average (#{blue_excess.round(3)} excess)"
      severity = 'high'
    elsif blue_excess > 0.2
      blue_issues << "Blue density moderately higher than R/G average (#{blue_excess.round(3)} excess)"
      severity = severity == 'high' ? 'high' : 'medium'
    end

    # Check blue base density
    rg_base_avg = (r_base + g_base) / 2.0
    blue_base_excess = b_base - rg_base_avg

    if blue_base_excess > 0.2
      blue_issues << "Blue base density unusually high (#{blue_base_excess.round(3)} above R/G average)"
      severity = 'high'
    end

    # Check for potential light source issues
    b_to_r_ratio = b_net / r_net
    if b_to_r_ratio > 2.0
      blue_issues << "Blue-to-red ratio very high (#{b_to_r_ratio.round(2)}:1) - possible light source mismatch"
      severity = 'high'
    elsif b_to_r_ratio > 1.5
      blue_issues << "Blue-to-red ratio elevated (#{b_to_r_ratio.round(2)}:1) - monitor light source"
      severity = severity == 'high' ? 'high' : 'medium'
    end

    {
      'has_issues' => !blue_issues.empty?,
      'severity' => severity,
      'issues' => blue_issues,
      'metrics' => {
        'blue_excess_over_rg' => blue_excess,
        'blue_base_excess' => blue_base_excess,
        'blue_to_red_ratio' => b_to_r_ratio,
        'blue_to_green_ratio' => b_net / g_net
      }
    }
  end

  def analyze_scanning_setup(results)
    r_raw = @gray_card_data.r.avg
    g_raw = @gray_card_data.g.avg
    b_raw = @gray_card_data.b.avg

    diagnostics = []
    recommendations = []

    # Check raw value distribution
    rg_avg = (r_raw + g_raw) / 2.0
    blue_raw_ratio = b_raw / rg_avg

    if blue_raw_ratio < 0.4
      diagnostics << "Blue channel severely underexposed in scan (#{(blue_raw_ratio * 100).round(1)}% of R/G average)"
      recommendations << "Increase blue channel exposure or check light source spectrum"
    elsif blue_raw_ratio < 0.6
      diagnostics << "Blue channel underexposed in scan (#{(blue_raw_ratio * 100).round(1)}% of R/G average)"
      recommendations << "Consider slight blue channel boost in scanning"
    end

    # Check for clipping
    bit_depth, reference_white = get_bit_depth_and_reference(14)
    clip_threshold = reference_white * 0.95

    %w[r g b].each do |channel|
      max_val = @gray_card_data.send(channel).max_val
      if max_val > clip_threshold
        diagnostics << "#{channel.upcase} channel near clipping (max: #{max_val})"
        recommendations << "Reduce exposure to prevent #{channel.upcase} clipping"
      end
    end

    # White balance assessment
    wb_diagnostics = assess_white_balance(results)
    diagnostics.concat(wb_diagnostics[:issues]) if wb_diagnostics[:issues]
    recommendations.concat(wb_diagnostics[:recommendations]) if wb_diagnostics[:recommendations]


    {
      'issues' => diagnostics,
      'recommendations' => recommendations,
      'metrics' => {
        'blue_raw_ratio' => blue_raw_ratio,
        'potential_clipping' => {
          'r' => @gray_card_data.r.max_val > clip_threshold,
          'g' => @gray_card_data.g.max_val > clip_threshold,
          'b' => @gray_card_data.b.max_val > clip_threshold
        }
      }
    }
  end

  def assess_white_balance(results)
    r_base = results['film_base_densities']['r']['measured_value']
    g_base = results['film_base_densities']['g']['measured_value']
    b_base = results['film_base_densities']['b']['measured_value']

    issues = []
    recommendations = []

    # Film base should have somewhat consistent values when properly white balanced
    # But with daylight WB on tungsten-balanced film, we expect blue to be low

    rg_ratio = r_base / g_base
    rb_ratio = r_base / b_base
    gb_ratio = g_base / b_base

    if rb_ratio < 1.3
      issues << "R/B ratio low (#{rb_ratio.round(2)}) - possible warm color cast"
      recommendations << "Consider cooler white balance or check light source temperature"
    elsif rb_ratio > 2.2
      issues << "R/B ratio high (#{rb_ratio.round(2)}) - possible cool color cast" 
      recommendations << "Consider warmer white balance"
    end

    if gb_ratio < 1.5
      issues << "G/B ratio low (#{gb_ratio.round(2)}) - green cast possible"
    elsif gb_ratio > 2.5
      issues << "G/B ratio high (#{gb_ratio.round(2)}) - magenta cast possible"
    end

    {
      'issues' => issues,
      'recommendations' => recommendations,
      'ratios' => {
        'rg' => rg_ratio,
        'rb' => rb_ratio,
        'gb' => gb_ratio
      }
    }
  end

  def determine_overall_status(gray_card_status, base_fog_status, has_crossover, has_blue_issues)
    if gray_card_status == :fail || base_fog_status == :fail
      'FAIL'
    elsif has_blue_issues
      if gray_card_status == :warning || base_fog_status == :warning
        'WARNING_BLUE_ISSUES'
      else
        'PASS_BLUE_ISSUES'
      end
    elsif gray_card_status == :warning || base_fog_status == :warning
      has_crossover ? 'WARNING_WITH_CROSSOVER' : 'WARNING'
    elsif has_crossover
      'PASS_WITH_CROSSOVER'
    else
      'PASS'
    end
  end

  def print_results(results)
    puts "\n#{'=' * 70}"
    puts '           C-41 DEVELOPMENT ANALYSIS RESULTS'
    puts('=' * 70)

    # Show bit depth detection
    puts "\n📊 SCAN PARAMETERS:"
    puts "Bit Depth: #{results['bit_depth']}-bit (Reference White: #{results['reference_white']})"
    puts "Film Stock Profile: #{@film_stock}"

    # Overall Status with new blue channel statuses
    status = results['overall_status']
    status_display = {
      'PASS' => '✅ PASS',
      'PASS_WITH_CROSSOVER' => '⚠️  PASS (with crossover)',
      'PASS_BLUE_ISSUES' => '🔵 PASS (blue channel issues)',
      'WARNING' => '⚠️  WARNING',
      'WARNING_WITH_CROSSOVER' => '⚠️  WARNING (with crossover)',
      'WARNING_BLUE_ISSUES' => '🔵 WARNING (blue channel issues)',
      'FAIL' => '❌ FAIL'
    }
    puts "\nOVERALL STATUS: #{status_display[status] || status}"

    # Blue Channel Analysis Section (NEW)
    blue_analysis = results['blue_channel_analysis']
    if blue_analysis['has_issues']
      puts "\n#{'BLUE CHANNEL ANALYSIS'.center(70, '-')}"
      puts "Severity: #{blue_analysis['severity'].upcase}"
      blue_analysis['issues'].each do |issue|
        puts "🔵 #{issue}"
      end
      
      metrics = blue_analysis['metrics']
      puts "\nBlue Channel Metrics:"
      puts "• Blue excess over R/G average: #{metrics['blue_excess_over_rg'].round(3)}"
      puts "• Blue base excess: #{metrics['blue_base_excess'].round(3)}"
      puts "• Blue-to-red ratio: #{metrics['blue_to_red_ratio'].round(2)}:1"
      puts "• Blue-to-green ratio: #{metrics['blue_to_green_ratio'].round(2)}:1"
    end

    # Scanning Diagnostics Section (NEW)
    scan_diag = results['scanning_diagnostics']
    if !scan_diag['issues'].empty?
      puts "\n#{'DSLR SCANNING DIAGNOSTICS'.center(70, '-')}"
      scan_diag['issues'].each do |issue|
        puts "📷 #{issue}"
      end
    end

    # Original sections with enhanced formatting
    print_density_analysis(results)
    print_crossover_analysis(results)
    print_debug_info(results)
    print_enhanced_recommendations(results)

    puts('=' * 70)
  end

  def print_density_analysis(results)
    puts "\n#{'GRAY CARD DENSITY ANALYSIS'.center(70, '-')}"
    puts format('%-8s %-8s %-15s %-8s %s', 'Channel', 'Density', 'Target Range', 'Status', 'Notes')
    puts '-' * 70

    %w[r g b].each do |channel|
      val = results['gray_card_validation'][channel]
      density = val['density']
      target_min, target_max = val['target_range']

      soft_min = target_min - SOFT_TOLERANCE
      soft_max = target_max + SOFT_TOLERANCE
      status_info = get_tolerance_status(density, target_min, target_max, soft_min, soft_max)

      notes = case status_info[:level]
              when :pass then ''
              when :soft_under then format('Slightly under by %.3f (within soft tolerance)', target_min - density)
              when :soft_over then format('Slightly over by %.3f (within soft tolerance)', density - target_max)
              when :hard_under then format('Under by %.3f - NEEDS ATTENTION', target_min - density)
              when :hard_over then format('Over by %.3f - NEEDS ATTENTION', density - target_max)
              end

      puts format('%-8s %-8.3f %-15s %-8s %s', channel.upcase, density, 
                  format('%.2f-%.2f', target_min, target_max), status_info[:icon], notes)
    end

    puts "\n#{'BASE + FOG ANALYSIS'.center(70, '-')}"
    puts format('%-8s %-8s %-15s %-8s %s', 'Channel', 'Density', 'Target Range', 'Status', 'Notes')
    puts '-' * 70

    %w[r g b].each do |channel|
      val = results['base_fog_validation'][channel]
      density = val['density']
      target_min, target_max = val['target_range']

      soft_min = target_min - SOFT_TOLERANCE
      soft_max = target_max + SOFT_TOLERANCE
      status_info = get_tolerance_status(density, target_min, target_max, soft_min, soft_max)

      notes = case status_info[:level]
              when :pass then ''
              when :soft_under, :soft_over then 'Within soft tolerance'
              when :hard_under, :hard_over then 'NEEDS ATTENTION'
              end

      puts format('%-8s %-8.3f %-15s %-8s %s', channel.upcase, density, 
                  format('%.2f-%.2f', target_min, target_max), status_info[:icon], notes)
    end
  end

  def print_crossover_analysis(results)
    puts "\n#{'CROSSOVER ANALYSIS'.center(70, '-')}"
    crossover = results['crossover_analysis']

    puts format('R-G Difference: %.3f (%s)', crossover['rg_difference'],
                crossover['rg_crossover'] ? '❌ CROSSOVER' : '✅ OK')
    puts format('R-B Difference: %.3f (%s)', crossover['rb_difference'],
                crossover['rb_crossover'] ? '❌ CROSSOVER' : '✅ OK')
    puts format('G-B Difference: %.3f (%s)', crossover['gb_difference'],
                crossover['gb_crossover'] ? '❌ CROSSOVER' : '✅ OK')
  end

  def print_debug_info(results)
    puts "\n#{'DEBUG INFO'.center(70, '-')}"
    puts format('Gray card measurements (RGB avg): %.1f, %.1f, %.1f', 
                @gray_card_data.r.avg, @gray_card_data.g.avg, @gray_card_data.b.avg)
    puts format('Film base measurements (RGB avg): %.1f, %.1f, %.1f', 
                @film_base_data.r.avg, @film_base_data.g.avg, @film_base_data.b.avg)
    puts format('Raw densities (RGB): %.3f, %.3f, %.3f', 
                results['gray_card_densities']['r']['raw_density'],
                results['gray_card_densities']['g']['raw_density'], 
                results['gray_card_densities']['b']['raw_density'])
    puts format('Base densities (RGB): %.3f, %.3f, %.3f', 
                results['film_base_densities']['r']['density'],
                results['film_base_densities']['g']['density'], 
                results['film_base_densities']['b']['density'])
  end

  def print_enhanced_recommendations(results)
    puts "\n#{'RECOMMENDATIONS'.center(70, '-')}"

    status = results['overall_status']
    blue_analysis = results['blue_channel_analysis']
    scan_diag = results['scanning_diagnostics']

    case status
    when 'PASS'
      puts '✅ Development is within specification. Proceed with confidence!'
    when 'PASS_WITH_CROSSOVER'
      puts '⚠️  Development timing is good but crossover detected.'
      puts '   Consider adjusting chemical balance or temperature control.'
    when 'PASS_BLUE_ISSUES', 'WARNING_BLUE_ISSUES'
      puts '🔵 Development chemistry appears good, but blue channel needs attention:'
      
      if blue_analysis['severity'] == 'high'
        puts '   CRITICAL BLUE ISSUES:'
        puts '   • Check light source: CRI 95 5600K should be good - verify actual output'
        puts '   • Try AUTO white balance instead of Daylight (5600K may not match your light exactly)'
        puts '   • Consider custom white balance using film base as reference'
        puts '   • Check for UV contamination - add UV filter if not present'
      else
        puts '   MINOR BLUE ADJUSTMENTS:'
        puts '   • Fine-tune white balance slightly warmer'
        puts '   • Monitor blue channel exposure in future scans'
      end

      # Add scanning-specific recommendations
      unless scan_diag['recommendations'].empty?
        puts '   SCANNING SETUP:'
        scan_diag['recommendations'].each { |rec| puts "   • #{rec}" }
      end

    when 'WARNING', 'WARNING_WITH_CROSSOVER'
      puts '⚠️  Development within soft tolerance but monitor closely.'
      print_specific_development_recommendations(results)
    else
      puts '❌ Development is out of specification. Recommendations:'
      print_specific_development_recommendations(results)
    end

    # Always show blue channel specific advice if there are issues
    if blue_analysis['has_issues']
      puts "\n🔵 BLUE CHANNEL SPECIFIC ADVICE:"
      puts "   Your setup: DSLR + CRI 95 5600K + Daylight WB"
      puts "   • Blue density #{blue_analysis['metrics']['blue_excess_over_rg'].round(3)} higher than R/G average"
      puts "   • This is common with DSLR scanning of orange-masked film"
      puts "   • Consider switching to 'DSLR_Generic' profile: --film DSLR_Generic"
      puts "   • Or try Tungsten white balance to shift blue response"
    end
  end

  def print_specific_development_recommendations(results)
    %w[r g b].each do |channel|
      val = results['gray_card_validation'][channel]
      next if val['in_spec']

      density = val['density']
      target_min, target_max = val['target_range']
      soft_min = target_min - SOFT_TOLERANCE
      soft_max = target_max + SOFT_TOLERANCE

      status_info = get_tolerance_status(density, target_min, target_max, soft_min, soft_max)

      case status_info[:level]
      when :soft_under
        puts "   • #{channel.upcase} channel: SLIGHTLY UNDERDEVELOPED - Minor increase in time/temp"
      when :soft_over
        puts "   • #{channel.upcase} channel: SLIGHTLY OVERDEVELOPED - Minor decrease in time/temp"
      when :hard_under
        puts "   • #{channel.upcase} channel: SIGNIFICANTLY UNDERDEVELOPED - Increase time or temperature"
      when :hard_over
        puts "   • #{channel.upcase} channel: SIGNIFICANTLY OVERDEVELOPED - Decrease time or temperature"
      end
    end
  end

  # def parse_raw_digger_csv(csv_file_path)
  #   raise "CSV file not found: #{csv_file_path}" unless File.exist?(csv_file_path)

  #   channel_data = {}

  #   CSV.foreach(csv_file_path, headers: true) do |row|
  #     # Parse R channel
  #     if row['Rmin'] && row['Ravg'] && row['Rmax'] && row['Rdev']
  #       channel_data['r'] = {
  #         'min' => row['Rmin'].to_f,
  #         'max' => row['Rmax'].to_f,
  #         'avg' => row['Ravg'].to_f,
  #         'std_dev' => row['Rdev'].to_f
  #       }
  #     end

  #     # Parse G channel
  #     if row['Gmin'] && row['Gavg'] && row['Gmax'] && row['Gdev']
  #       channel_data['g'] = {
  #         'min' => row['Gmin'].to_f,
  #         'max' => row['Gmax'].to_f,
  #         'avg' => row['Gavg'].to_f,
  #         'std_dev' => row['Gdev'].to_f
  #       }
  #     end

  #     # Parse B channel
  #     if row['Bmin'] && row['Bavg'] && row['Bmax'] && row['Bdev']
  #       channel_data['b'] = {
  #         'min' => row['Bmin'].to_f,
  #         'max' => row['Bmax'].to_f,
  #         'avg' => row['Bavg'].to_f,
  #         'std_dev' => row['Bdev'].to_f
  #       }
  #     end

  #     # Parse G2 channel
  #     if row['G2min'] && row['G2avg'] && row['G2max'] && row['G2dev']
  #       channel_data['g2'] = {
  #         'min' => row['G2min'].to_f,
  #         'max' => row['G2max'].to_f,
  #         'avg' => row['G2avg'].to_f,
  #         'std_dev' => row['G2dev'].to_f
  #       }
  #     end

  #     # We only need the first row for single sample analysis
  #     break
  #   end

  #   # Validate we got all required channels
  #   required_channels = %w[r g b g2]
  #   missing_channels = required_channels - channel_data.keys

  #   raise "Missing channels in CSV: #{missing_channels}" if missing_channels.any?

  #   channel_data
  # rescue StandardError => e
  #   raise "Error parsing CSV file: #{e.message}"
  # end

  def analyze_from_csv_files(gray_card_csv, film_base_csv)
    puts "Loading gray card measurements from: #{gray_card_csv}"
    gray_data = parse_raw_digger_csv(gray_card_csv)

    puts "Loading film base measurements from: #{film_base_csv}"
    base_data = parse_raw_digger_csv(film_base_csv)

    puts "✅ CSV files loaded successfully\n"

    # Convert to MeasurementData format and analyze
    @gray_card_data = dict_to_measurement_data(gray_data)
    @film_base_data = dict_to_measurement_data(base_data)

    # Analyze and print results
    results = analyze_development
    print_results(results)
    results
  end

  def analyze_from_single_csv(csv_file, bit_depth = 14)
    puts "Loading measurements from: #{csv_file}"

    raise "CSV file not found: #{csv_file}" unless File.exist?(csv_file)

    rows = CSV.read(csv_file, headers: true)

    raise 'CSV file must contain at least 2 rows (gray card + film base)' if rows.length < 2

    # Parse first row as gray card
    gray_row = rows[0]
    gray_data = parse_raw_digger_row(gray_row)

    # Parse second row as film base
    base_row = rows[1]
    base_data = parse_raw_digger_row(base_row)

    puts '✅ Parsed CSV with 2 samples:'
    puts "   Sample 1 (Gray Card): #{gray_row['Sample_Name'] || 'Unknown'}"
    puts "   Sample 2 (Film Base): #{base_row['Sample_Name'] || 'Unknown'}"
    puts

    @gray_card_data = dict_to_measurement_data(gray_data)
    @film_base_data = dict_to_measurement_data(base_data)

    results = analyze_development(bit_depth)
    print_results(results)
    results
  rescue StandardError => e
    raise "Error parsing CSV file: #{e.message}"
  end

  private

  def check_measurements_with_soft_tolerance(validation_data, soft_tolerance)
    statuses = %w[r g b].map do |channel|
      val = validation_data[channel]
      density = val['density']
      target_min, target_max = val['target_range']

      # Calculate soft tolerance ranges
      soft_min = target_min - soft_tolerance
      soft_max = target_max + soft_tolerance

      if density >= target_min && density <= target_max
        :pass
      elsif density >= soft_min && density <= soft_max
        :warning  # Within soft tolerance
      else
        :fail     # Beyond soft tolerance
      end
    end

    # Return the worst status
    if statuses.include?(:fail)
      :fail
    elsif statuses.include?(:warning)
      :warning
    else
      :pass
    end
  end

  def get_tolerance_status(density, target_min, target_max, soft_min, soft_max)
    if density >= target_min && density <= target_max
      { icon: '✅', level: :pass }
    elsif density >= soft_min && density < target_min
      { icon: '⚠️', level: :soft_under }
    elsif density > target_max && density <= soft_max
      { icon: '⚠️', level: :soft_over }
    elsif density < soft_min
      { icon: '❌', level: :hard_under }
    else # density > soft_max
      { icon: '❌', level: :hard_over }
    end
  end

  def parse_raw_digger_row(row)
    channel_data = {}

    # Parse each channel from the row
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

    # Validate all channels present
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

# Utility functions
def analyze_from_data(gray_card_data, film_base_data, film_stock = 'Gold')
  validator = C41Validator.new(film_stock)

  # Convert input data to MeasurementData format
  validator.gray_card_data = validator.send(:dict_to_measurement_data, gray_card_data)
  validator.film_base_data = validator.send(:dict_to_measurement_data, film_base_data)

  # Analyze and return results
  results = validator.analyze_development
  validator.print_results(results)
  results
end

# Quick test function for your current measurements
def test_your_measurements
  puts '=== TESTING YOUR CURRENT MEASUREMENTS ==='
  puts 'Gray card: R=749.1, G=734.7, B=223.3'
  puts 'Film base: R=1907.8, G=2216.8, B=1193.2'
  puts

  # Your actual measurements
  gray_data = {
    'r' => { 'min' => 700, 'max' => 800, 'avg' => 749.1, 'std_dev' => 25.0 },
    'g' => { 'min' => 680, 'max' => 790, 'avg' => 734.7, 'std_dev' => 28.0 },
    'b' => { 'min' => 200, 'max' => 250, 'avg' => 223.3, 'std_dev' => 12.0 },
    'g2' => { 'min' => 680, 'max' => 790, 'avg' => 734.7, 'std_dev' => 28.0 }
  }

  base_data = {
    'r' => { 'min' => 1850, 'max' => 1970, 'avg' => 1907.8, 'std_dev' => 30.0 },
    'g' => { 'min' => 2150, 'max' => 2280, 'avg' => 2216.8, 'std_dev' => 32.0 },
    'b' => { 'min' => 1150, 'max' => 1240, 'avg' => 1193.2, 'std_dev' => 22.0 },
    'g2' => { 'min' => 2150, 'max' => 2280, 'avg' => 2216.8, 'std_dev' => 32.0 }
  }

  puts "Testing with standard 'Gold' profile:"
  puts "="*70
  analyze_from_data(gray_data, base_data, 'Gold')

  puts "\n" + "="*70
  puts "\nTesting with DSLR-optimized profile:"
  puts "="*70
  analyze_from_data(gray_data, base_data, 'DSLR_Generic')
end

def analyze_from_csv_workflow
  puts '=== CSV IMPORT ANALYSIS ==='
  puts
  puts 'Options:'
  puts 'A. Two separate CSV files (gray card + film base)'
  puts 'B. Single CSV file with both samples'

  print "\nSelect option (A/B): "
  choice = gets.chomp.upcase

  print "Enter film profile (Gold/Portra/Ektar/DSLR_Generic, default: Gold): "
  film_choice = gets.chomp
  film_choice = 'Gold' if film_choice.empty?

  validator = C41Validator.new(film_choice)

  case choice
  when 'A'
    print 'Enter path to gray card CSV file: '
    gray_csv = gets.chomp

    print 'Enter path to film base CSV file: '
    base_csv = gets.chomp

    unless File.exist?(gray_csv)
      puts "❌ Gray card CSV file not found: #{gray_csv}"
      return
    end

    unless File.exist?(base_csv)
      puts "❌ Film base CSV file not found: #{base_csv}"
      return
    end

    validator.analyze_from_csv_files(gray_csv, base_csv)

  when 'B'
    print 'Enter path to CSV file with both samples: '
    csv_file = gets.chomp

    unless File.exist?(csv_file)
      puts "❌ CSV file not found: #{csv_file}"
      return
    end

    print 'Enter bit depth (12/14/16, default: 14): '
    bit_depth_input = gets.chomp
    bit_depth = bit_depth_input.empty? ? 14 : bit_depth_input.to_i

    validator.analyze_from_single_csv(csv_file, bit_depth)

  else
    puts 'Invalid choice. Please select A or B.'
  end
end

def main
  # Check if CSV file was provided as command line argument
  if ARGV.length.positive?
    options = { bit_depth: 14, film: 'Gold' }

    OptionParser.new do |opts|
      opts.banner = 'Usage: ruby script.rb <csv_file> [options]'
      opts.on('--bit-depth N', Integer, 'Bit depth (default: 14)') { |n| options[:bit_depth] = n }
      opts.on('--film NAME', String, 'Film stock profile (Gold/Portra/Ektar/DSLR_Generic)') { |name| options[:film] = name }
      opts.on('-h', '--help', 'Show this help') do
        puts opts
        puts "\nAvailable film profiles:"
        puts "  Gold - Kodak Gold (default)"
        puts "  Portra - Kodak Portra series"
        puts "  Ektar - Kodak Ektar"
        puts "  DSLR_Generic - Optimized for DSLR scanning with relaxed blue channel"
        exit
      end
    end.parse!(ARGV)

    csv_file = ARGV.shift
    if csv_file.nil?
      abort("Error: CSV file path is required.\nUsage: ruby script.rb <csv_file> [--bit-depth N] [--film NAME]")
    end

    unless File.exist?(csv_file)
      abort("❌ CSV file not found: #{csv_file}")
    end

    validator = C41Validator.new(options[:film])
    puts "Enhanced C-41 Development Validation Tool"
    puts "CSV: #{csv_file}"
    puts "Bit Depth: #{options[:bit_depth]}"
    puts "Film Stock Profile: #{validator.film_stock}"
    puts

    validator.analyze_from_single_csv(csv_file, options[:bit_depth])
    return
  end

  puts 'Enhanced C-41 Development Validation Tool'
  puts 'Options:'
  puts '0. Test your current measurements (with blue channel analysis)'
  puts '1. Import from Raw Digger CSV files'
  puts '2. Interactive measurement input'

  print "\nSelect option (0/1/2): "
  choice = gets.chomp

  case choice
  when '0'
    test_your_measurements
  when '1'
    analyze_from_csv_workflow
  when '2'
    puts "\nInteractive mode:"
    puts "Available film profiles: Gold, Portra, Ektar, DSLR_Generic"
    print "Enter film profile (default: Gold): "
    film_choice = gets.chomp
    film_choice = 'Gold' if film_choice.empty?
    
    validator = C41Validator.new(film_choice)
    validator.input_measurements
    results = validator.analyze_development
    validator.print_results(results)

    # Ask if user wants to save results
    print "\nSave results to file? (y/n): "
    save = gets.chomp.downcase

    if %w[y yes].include?(save)
      print 'Enter filename (without extension): '
      filename = gets.chomp
      filename = 'c41_analysis' if filename.strip.empty?

      File.open("#{filename}.txt", 'w') do |f|
        f.puts 'Enhanced C-41 Development Analysis Results'
        f.puts '=' * 70

        # Write raw data
        f.puts "\nGray Card Measurements:"
        %w[r g b g2].each do |ch|
          data = validator.gray_card_data.send(ch)
          f.puts "  #{ch.upcase}: Min=#{data.min_val}, Max=#{data.max_val}, Avg=#{data.avg}, σ=#{data.std_dev}"
        end

        f.puts "\nFilm Base Measurements:"
        %w[r g b g2].each do |ch|
          data = validator.film_base_data.send(ch)
          f.puts "  #{ch.upcase}: Min=#{data.min_val}, Max=#{data.max_val}, Avg=#{data.avg}, σ=#{data.std_dev}"
        end

        # Write analysis results
        f.puts "\nAnalysis Results:"
        f.puts "Film Profile: #{validator.film_stock}"
        f.puts "Overall Status: #{results['overall_status']}\n"

        f.puts 'Gray Card Densities:'
        %w[r g b].each do |ch|
          val = results['gray_card_validation'][ch]
          f.puts "  #{ch.upcase}: #{'%.3f' % val['density']} #{val['in_spec'] ? '(IN SPEC)' : '(OUT OF SPEC)'}"
        end

        f.puts "\nCrossover Analysis:"
        crossover = results['crossover_analysis']
        f.puts "  R-G: #{'%.3f' % crossover['rg_difference']} #{crossover['rg_crossover'] ? '(CROSSOVER)' : '(OK)'}"
        f.puts "  R-B: #{'%.3f' % crossover['rb_difference']} #{crossover['rb_crossover'] ? '(CROSSOVER)' : '(OK)'}"
        f.puts "  G-B: #{'%.3f' % crossover['gb_difference']} #{crossover['gb_crossover'] ? '(CROSSOVER)' : '(OK)'}"

        # Write blue channel analysis if present
        if results['blue_channel_analysis']['has_issues']
          f.puts "\nBlue Channel Issues:"
          results['blue_channel_analysis']['issues'].each { |issue| f.puts "  • #{issue}" }
        end

        # Write scanning diagnostics if present
        unless results['scanning_diagnostics']['issues'].empty?
          f.puts "\nScanning Diagnostics:"
          results['scanning_diagnostics']['issues'].each { |issue| f.puts "  • #{issue}" }
        end
      end

      puts "Results saved to #{filename}.txt"
    end
  else
    puts 'Invalid choice. Please select 0, 1, or 2.'
  end
rescue Interrupt
  puts "\n\nOperation cancelled by user."
  exit(0)
rescue StandardError => e
  puts "\nError: #{e.message}"
  puts e.backtrace if ENV['DEBUG']
  exit(1)
end

# Run the main function if this file is executed directly
main if __FILE__ == $PROGRAM_NAME