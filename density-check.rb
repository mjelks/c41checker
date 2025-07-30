#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'json'
require 'optparse'

# C-41 Development Validation Tool in Ruby
#
# This script helps validate C-41 film development by analyzing gray card and film base
# measurements to ensure development is within tolerance and avoid crossover issues.

# Channel statistics structure
ChannelStats = Struct.new(:min_val, :max_val, :avg, :std_dev)

# Measurement data for all channels
MeasurementData = Struct.new(:r, :g, :b, :g2)

class C41Validator
  # C-41 specification ranges for SCANNED NEGATIVES (typical values)
  # These are lower because we're measuring transmitted light through the negative

  # from claude:
  #   Great question! I should be transparent about this - I derived those values by working backwards from your "properly developed" sample data, not from authoritative C-41 specifications.
  # Here's what happened:

  # Your original targets (0.65-0.85, etc.) were clearly for transmission densitometry - measuring how much light film blocks when you shine light through it in a lab setting.
  # Your scanned values (0.235, 0.255, 0.371 for gray card; 0.787, 0.749, 0.844 for base) were much different because scanning measures digital values converted to density.
  # I reverse-engineered reasonable ranges by:

  # Taking your "known good" gray card values and giving them ±0.1 to ±0.2 tolerance
  # Taking your base values and giving them similar tolerances
  # The crossover thresholds I kept from your original script (those are more universal)

  # The honest answer: These are educated guesses based on your sample, not official Kodak specifications. For production use, you'd want to:

  # Test with multiple properly developed samples from a trusted lab
  # Consult actual C-41 process control documentation
  # Possibly contact film/scanning equipment manufacturers for their recommended ranges
  # Build up your own database of "good" vs "bad" development examples

  # I made reasonable assumptions, but you should validate these ranges against more samples and possibly adjust them based on your specific scanning setup, film stocks, and quality standards.

  # GRAY_CARD_DENSITY_TARGETS = {
  #   'r' => [0.20, 0.40],  # Red density range for 18% gray on negative
  #   'g' => [0.22, 0.42],  # Green density range on negative
  #   'b' => [0.25, 0.45]   # Blue density range on negative
  # }.freeze

  # BASE_PLUS_FOG_LIMITS = {
  #   'r' => [0.75, 0.95],  # Base + fog density limits for scanned negative
  #   'g' => [0.70, 0.90],
  #   'b' => [0.80, 1.00]
  # }.freeze

  # # Crossover indicators (density differences between channels)
  # CROSSOVER_THRESHOLDS = {
  #   'rg_diff' => 0.15,  # R-G difference threshold
  #   'rb_diff' => 0.20,  # R-B difference threshold
  #   'gb_diff' => 0.15   # G-B difference threshold
  # }.freeze
  SOFT_TOLERANCE = 0.03
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
    # Default to 14-bit, but allow override
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
    # Calculate optical density from digital values
    # Density = log10(reference_white / measured_value)
    return Float::INFINITY if measured_value <= 0

    Math.log10(reference_white / measured_value)
  end

  def analyze_development(bit_depth = 14)
    raise 'Both gray card and film base measurements required' unless @gray_card_data && @film_base_data

    # Get bit depth and reference white value
    bit_depth, reference_white = get_bit_depth_and_reference(bit_depth)
    results = {
      'bit_depth' => bit_depth,
      'reference_white' => reference_white,
      'gray_card_densities' => {},
      'film_base_densities' => {},
      'gray_card_validation' => {},
      'base_fog_validation' => {},
      'crossover_analysis' => {},
      'overall_status' => 'UNKNOWN'
    }

    # Calculate densities for gray card
    %w[r g b].each do |channel|
      gray_avg = @gray_card_data.send(channel).avg
      base_avg = @film_base_data.send(channel).avg

      # Calculate densities using the correct reference_white parameter
      gray_density = calculate_density(gray_avg, reference_white)
      base_density = calculate_density(base_avg, reference_white)

      # Net density = gray_density - base_density
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

    # Enhanced overall status calculation with soft tolerance
    gray_card_status = check_measurements_with_soft_tolerance(results['gray_card_validation'], SOFT_TOLERANCE)
    base_fog_status = check_measurements_with_soft_tolerance(results['base_fog_validation'], SOFT_TOLERANCE)

    # Check for crossover
    has_crossover = results['crossover_analysis'].values_at('rg_crossover', 'rb_crossover', 'gb_crossover').any?

    # Determine overall status with soft tolerance
    results['overall_status'] = if gray_card_status == :fail || base_fog_status == :fail
                                  'FAIL'
                                elsif gray_card_status == :warning || base_fog_status == :warning
                                  has_crossover ? 'WARNING_WITH_CROSSOVER' : 'WARNING'
                                elsif has_crossover
                                  'PASS_WITH_CROSSOVER'
                                else
                                  'PASS'
                                end

    results
  end

  # def print_results(results)
  #   puts "\n#{'=' * 60}"
  #   puts "           C-41 DEVELOPMENT ANALYSIS RESULTS"
  #   puts "#{'=' * 60}"

  #   # Show bit depth detection
  #   puts "\n📊 SCAN PARAMETERS:"
  #   puts "Bit Depth: #{results['bit_depth']}-bit (Reference White: #{results['reference_white']})"

  #   # Overall Status
  #   status = results['overall_status']
  #   status_display = {
  #     'PASS' => '✅ PASS',
  #     'PASS_WITH_CROSSOVER' => '⚠️  PASS (with crossover)',
  #     'FAIL' => '❌ FAIL'
  #   }
  #   puts "\nOVERALL STATUS: #{status_display[status] || status}"

  #   # Gray Card Analysis
  #   puts "\n#{'GRAY CARD DENSITY ANALYSIS'.center(60, '-')}"
  #   puts "%-8s %-8s %-15s %-8s %s" % ['Channel', 'Density', 'Target Range', 'Status', 'Notes']
  #   puts "-" * 60

  #   %w[r g b].each do |channel|
  #     val = results['gray_card_validation'][channel]
  #     density = val['density']
  #     target_min, target_max = val['target_range']
  #     status_icon = val['in_spec'] ? "✅" : "❌"

  #     notes = if density < target_min
  #               "Under by %.3f" % (target_min - density)
  #             elsif density > target_max
  #               "Over by %.3f" % (density - target_max)
  #             else
  #               ""
  #             end

  #     puts "%-8s %-8.3f %-15s %-8s %s" % [
  #       channel.upcase,
  #       density,
  #       "%.2f-%.2f" % [target_min, target_max],
  #       status_icon,
  #       notes
  #     ]
  #   end

  #   # Base + Fog Analysis
  #   puts "\n#{'BASE + FOG ANALYSIS'.center(60, '-')}"
  #   puts "%-8s %-8s %-15s %s" % ['Channel', 'Density', 'Target Range', 'Status']
  #   puts "-" * 60

  #   %w[r g b].each do |channel|
  #     val = results['base_fog_validation'][channel]
  #     density = val['density']
  #     target_min, target_max = val['target_range']
  #     status_icon = val['in_spec'] ? "✅" : "❌"

  #     puts "%-8s %-8.3f %-15s %s" % [
  #       channel.upcase,
  #       density,
  #       "%.2f-%.2f" % [target_min, target_max],
  #       status_icon
  #     ]
  #   end

  #   # Crossover Analysis
  #   puts "\n#{'CROSSOVER ANALYSIS'.center(60, '-')}"
  #   crossover = results['crossover_analysis']

  #   puts "R-G Difference: %.3f (%s)" % [
  #     crossover['rg_difference'],
  #     crossover['rg_crossover'] ? '❌ CROSSOVER' : '✅ OK'
  #   ]
  #   puts "R-B Difference: %.3f (%s)" % [
  #     crossover['rb_difference'],
  #     crossover['rb_crossover'] ? '❌ CROSSOVER' : '✅ OK'
  #   ]
  #   puts "G-B Difference: %.3f (%s)" % [
  #     crossover['gb_difference'],
  #     crossover['gb_crossover'] ? '❌ CROSSOVER' : '✅ OK'
  #   ]

  #   # Debug information
  #   puts "\n#{'DEBUG INFO'.center(60, '-')}"
  #   puts "Gray card measurements (RGB avg): %.1f, %.1f, %.1f" % [
  #     @gray_card_data.r.avg, @gray_card_data.g.avg, @gray_card_data.b.avg
  #   ]
  #   puts "Film base measurements (RGB avg): %.1f, %.1f, %.1f" % [
  #     @film_base_data.r.avg, @film_base_data.g.avg, @film_base_data.b.avg
  #   ]
  #   puts "Raw densities (RGB): %.3f, %.3f, %.3f" % [
  #     results['gray_card_densities']['r']['raw_density'],
  #     results['gray_card_densities']['g']['raw_density'],
  #     results['gray_card_densities']['b']['raw_density']
  #   ]
  #   puts "Base densities (RGB): %.3f, %.3f, %.3f" % [
  #     results['film_base_densities']['r']['density'],
  #     results['film_base_densities']['g']['density'],
  #     results['film_base_densities']['b']['density']
  #   ]

  #   # Recommendations
  #   puts "\n#{'RECOMMENDATIONS'.center(60, '-')}"

  #   case results['overall_status']
  #   when 'PASS'
  #     puts "✅ Development is within specification. Proceed with confidence!"
  #   when 'PASS_WITH_CROSSOVER'
  #     puts "⚠️  Development timing is good but crossover detected."
  #     puts "   Consider adjusting chemical balance or temperature control."
  #   else
  #     puts "❌ Development is out of specification. Recommendations:"

  #     # Specific recommendations based on issues
  #     %w[r g b].each do |channel|
  #       val = results['gray_card_validation'][channel]
  #       next if val['in_spec']

  #       density = val['density']
  #       target_min, target_max = val['target_range']

  #       if density < target_min
  #         puts "   • #{channel.upcase} channel: UNDERDEVELOPED - Increase time or temperature"
  #       elsif density > target_max
  #         puts "   • #{channel.upcase} channel: OVERDEVELOPED - Decrease time or temperature"
  #       end
  #     end

  #     base_issues = %w[r g b].select { |ch| !results['base_fog_validation'][ch]['in_spec'] }
  #     if base_issues.any?
  #       puts "   • Base + fog issues in #{base_issues.map(&:upcase).join(', ')} - Check chemistry freshness"
  #     end
  #   end

  #   puts "#{'=' * 60}"
  # end

  def print_results(results)
    puts "\n#{'=' * 60}"
    puts '           C-41 DEVELOPMENT ANALYSIS RESULTS'
    puts('=' * 60)

    # Show bit depth detection
    puts "\n📊 SCAN PARAMETERS:"
    puts "Bit Depth: #{results['bit_depth']}-bit (Reference White: #{results['reference_white']})"

    # Overall Status
    status = results['overall_status']
    status_display = {
      'PASS' => '✅ PASS',
      'PASS_WITH_CROSSOVER' => '⚠️  PASS (with crossover)',
      'WARNING' => '⚠️  WARNING',
      'WARNING_WITH_CROSSOVER' => '⚠️  WARNING (with crossover)',
      'FAIL' => '❌ FAIL'
    }
    puts "\nOVERALL STATUS: #{status_display[status] || status}"

    # Gray Card Analysis with soft tolerance
    puts "\n#{'GRAY CARD DENSITY ANALYSIS'.center(60, '-')}"
    puts format('%-8s %-8s %-15s %-8s %s', 'Channel', 'Density', 'Target Range', 'Status', 'Notes')
    puts '-' * 60

    %w[r g b].each do |channel|
      val = results['gray_card_validation'][channel]
      density = val['density']
      target_min, target_max = val['target_range']

      # Calculate soft tolerance ranges
      soft_min = target_min - SOFT_TOLERANCE
      soft_max = target_max + SOFT_TOLERANCE

      # Determine status with soft tolerance
      status_info = get_tolerance_status(density, target_min, target_max, soft_min, soft_max)

      notes = case status_info[:level]
              when :pass
                ''
              when :soft_under
                format('Slightly under by %.3f (within soft tolerance)', target_min - density)
              when :soft_over
                format('Slightly over by %.3f (within soft tolerance)', density - target_max)
              when :hard_under
                format('Under by %.3f - NEEDS ATTENTION', target_min - density)
              when :hard_over
                format('Over by %.3f - NEEDS ATTENTION', density - target_max)
              end

      puts format('%-8s %-8.3f %-15s %-8s %s', channel.upcase, density, format('%.2f-%.2f', target_min, target_max),
                  status_info[:icon], notes)
    end

    # Base + Fog Analysis with soft tolerance
    puts "\n#{'BASE + FOG ANALYSIS'.center(60, '-')}"
    puts format('%-8s %-8s %-15s %-8s %s', 'Channel', 'Density', 'Target Range', 'Status', 'Notes')
    puts '-' * 60

    %w[r g b].each do |channel|
      val = results['base_fog_validation'][channel]
      density = val['density']
      target_min, target_max = val['target_range']

      # Calculate soft tolerance ranges
      soft_min = target_min - SOFT_TOLERANCE
      soft_max = target_max + SOFT_TOLERANCE

      # Determine status with soft tolerance
      status_info = get_tolerance_status(density, target_min, target_max, soft_min, soft_max)

      notes = case status_info[:level]
              when :pass
                ''
              when :soft_under, :soft_over
                'Within soft tolerance'
              when :hard_under, :hard_over
                'NEEDS ATTENTION'
              end

      puts format('%-8s %-8.3f %-15s %-8s %s', channel.upcase, density, format('%.2f-%.2f', target_min, target_max),
                  status_info[:icon], notes)
    end

    # Crossover Analysis
    puts "\n#{'CROSSOVER ANALYSIS'.center(60, '-')}"
    crossover = results['crossover_analysis']

    puts format('R-G Difference: %.3f (%s)', crossover['rg_difference'],
                crossover['rg_crossover'] ? '❌ CROSSOVER' : '✅ OK')
    puts format('R-B Difference: %.3f (%s)', crossover['rb_difference'],
                crossover['rb_crossover'] ? '❌ CROSSOVER' : '✅ OK')
    puts format('G-B Difference: %.3f (%s)', crossover['gb_difference'],
                crossover['gb_crossover'] ? '❌ CROSSOVER' : '✅ OK')

    # Debug information
    puts "\n#{'DEBUG INFO'.center(60, '-')}"
    puts format('Gray card measurements (RGB avg): %.1f, %.1f, %.1f', @gray_card_data.r.avg, @gray_card_data.g.avg,
                @gray_card_data.b.avg)
    puts format('Film base measurements (RGB avg): %.1f, %.1f, %.1f', @film_base_data.r.avg, @film_base_data.g.avg,
                @film_base_data.b.avg)
    puts format('Raw densities (RGB): %.3f, %.3f, %.3f', results['gray_card_densities']['r']['raw_density'],
                results['gray_card_densities']['g']['raw_density'], results['gray_card_densities']['b']['raw_density'])
    puts format('Base densities (RGB): %.3f, %.3f, %.3f', results['film_base_densities']['r']['density'],
                results['film_base_densities']['g']['density'], results['film_base_densities']['b']['density'])

    # Enhanced Recommendations with soft tolerance consideration
    puts "\n#{'RECOMMENDATIONS'.center(60, '-')}"

    case results['overall_status']
    when 'PASS'
      puts '✅ Development is within specification. Proceed with confidence!'
    when 'PASS_WITH_CROSSOVER'
      puts '⚠️  Development timing is good but crossover detected.'
      puts '   Consider adjusting chemical balance or temperature control.'
    when 'WARNING'
      puts '⚠️  Development is within soft tolerance but monitor closely.'
      puts '   Results are acceptable but consider minor adjustments for optimal quality.'
    when 'WARNING_WITH_CROSSOVER'
      puts '⚠️  Development within soft tolerance but crossover detected.'
      puts '   Monitor both timing and chemical balance closely.'
    else
      puts '❌ Development is out of specification. Recommendations:'

      # Specific recommendations based on issues
      %w[r g b].each do |channel|
        val = results['gray_card_validation'][channel]
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

      # Check base + fog with soft tolerance
      base_hard_issues = []
      base_soft_issues = []

      %w[r g b].each do |channel|
        val = results['base_fog_validation'][channel]
        density = val['density']
        target_min, target_max = val['target_range']
        soft_min = target_min - SOFT_TOLERANCE
        soft_max = target_max + SOFT_TOLERANCE

        status_info = get_tolerance_status(density, target_min, target_max, soft_min, soft_max)

        case status_info[:level]
        when :soft_under, :soft_over
          base_soft_issues << channel.upcase
        when :hard_under, :hard_over
          base_hard_issues << channel.upcase
        end
      end

      if base_hard_issues.any?
        puts "   • Significant base + fog issues in #{base_hard_issues.join(', ')} - Check chemistry freshness"
      elsif base_soft_issues.any?
        puts "   • Minor base + fog issues in #{base_soft_issues.join(', ')} - Monitor chemistry"
      end
    end

    puts('=' * 60)
  end

  def parse_raw_digger_csv(csv_file_path)
    # Parse Raw Digger CSV export file
    # Expected CSV format from Raw Digger:
    # "Id","Sample_Name","Rmin","Ravg","Rmax","Rdev","Gmin","Gavg","Gmax","Gdev","Bmin","Bavg","Bmax","Bdev","G2min","G2avg","G2max","G2dev"

    raise "CSV file not found: #{csv_file_path}" unless File.exist?(csv_file_path)

    channel_data = {}

    CSV.foreach(csv_file_path, headers: true) do |row|
      # Parse R channel
      if row['Rmin'] && row['Ravg'] && row['Rmax'] && row['Rdev']
        channel_data['r'] = {
          'min' => row['Rmin'].to_f,
          'max' => row['Rmax'].to_f,
          'avg' => row['Ravg'].to_f,
          'std_dev' => row['Rdev'].to_f
        }
      end

      # Parse G channel
      if row['Gmin'] && row['Gavg'] && row['Gmax'] && row['Gdev']
        channel_data['g'] = {
          'min' => row['Gmin'].to_f,
          'max' => row['Gmax'].to_f,
          'avg' => row['Gavg'].to_f,
          'std_dev' => row['Gdev'].to_f
        }
      end

      # Parse B channel
      if row['Bmin'] && row['Bavg'] && row['Bmax'] && row['Bdev']
        channel_data['b'] = {
          'min' => row['Bmin'].to_f,
          'max' => row['Bmax'].to_f,
          'avg' => row['Bavg'].to_f,
          'std_dev' => row['Bdev'].to_f
        }
      end

      # Parse G2 channel
      if row['G2min'] && row['G2avg'] && row['G2max'] && row['G2dev']
        channel_data['g2'] = {
          'min' => row['G2min'].to_f,
          'max' => row['G2max'].to_f,
          'avg' => row['G2avg'].to_f,
          'std_dev' => row['G2dev'].to_f
        }
      end

      # We only need the first row for single sample analysis
      break
    end

    # Validate we got all required channels
    required_channels = %w[r g b g2]
    missing_channels = required_channels - channel_data.keys

    raise "Missing channels in CSV: #{missing_channels}" if missing_channels.any?

    channel_data
  rescue StandardError => e
    raise "Error parsing CSV file: #{e.message}"
  end

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
      ChannelStats.new(data_dict['g2']['min'], data_dict['g2']['max'], data_dict['g2']['avg'],
                       data_dict['g2']['std_dev'])
    )
  end
end

# Utility functions
def analyze_from_data(gray_card_data, film_base_data)
  validator = C41Validator.new

  # Convert input data to MeasurementData format
  validator.gray_card_data = validator.send(:dict_to_measurement_data, gray_card_data)
  validator.film_base_data = validator.send(:dict_to_measurement_data, film_base_data)

  # Analyze and return results
  results = validator.analyze_development
  validator.print_results(results)
  results
end

def quick_analysis
  puts '=== QUICK ANALYSIS OF YOUR CURRENT MEASUREMENTS ==='
  puts

  # Your measurements from the screenshots
  gray_card = {
    'r' => { 'min' => 394, 'max' => 676, 'avg' => 557.6, 'std_dev' => 27.4 },
    'g' => { 'min' => 382, 'max' => 712, 'avg' => 564.5, 'std_dev' => 30.2 },
    'b' => { 'min' => 108, 'max' => 256, 'avg' => 175.4, 'std_dev' => 15.6 },
    'g2' => { 'min' => 358, 'max' => 712, 'avg' => 567.5, 'std_dev' => 30.1 }
  }

  film_base = {
    'r' => { 'min' => 1312, 'max' => 1572, 'avg' => 1497.3, 'std_dev' => 25.2 },
    'g' => { 'min' => 1640, 'max' => 1852, 'avg' => 1772.2, 'std_dev' => 21.3 },
    'b' => { 'min' => 662, 'max' => 858, 'avg' => 762.7, 'std_dev' => 23.3 },
    'g2' => { 'min' => 1650, 'max' => 1858, 'avg' => 1778.0, 'std_dev' => 21.1 }
  }

  analyze_from_data(gray_card, film_base)
end

def test_your_csv
  puts '=== TESTING YOUR CSV DATA ==='
  puts

  # Your CSV data from the document
  gray_data = {
    'r' => { 'min' => 156.00, 'max' => 1378.00, 'avg' => 1074.75, 'std_dev' => 66.992 },
    'g' => { 'min' => 164.00, 'max' => 1632.00, 'avg' => 1363.00, 'std_dev' => 96.070 },
    'b' => { 'min' => 56.000, 'max' => 692.00, 'avg' => 511.52, 'std_dev' => 44.057 },
    'g2' => { 'min' => 168.00, 'max' => 1640.00, 'avg' => 1367.83, 'std_dev' => 95.916 }
  }

  base_data = {
    'r' => { 'min' => 1224.00, 'max' => 1490.00, 'avg' => 1369.66, 'std_dev' => 35.617 },
    'g' => { 'min' => 1602.00, 'max' => 1754.00, 'avg' => 1677.34, 'std_dev' => 20.676 },
    'b' => { 'min' => 614.00, 'max' => 774.00, 'avg' => 690.46, 'std_dev' => 22.080 },
    'g2' => { 'min' => 1602.00, 'max' => 1752.00, 'avg' => 1681.80, 'std_dev' => 20.793 }
  }

  puts 'Sample 1 (Gray Card): 4319:1799-439x529'
  puts 'Sample 2 (Film Base): 1289:9-339x119'
  puts

  analyze_from_data(gray_data, base_data)
end

def analyze_from_csv_workflow
  puts '=== CSV IMPORT ANALYSIS ==='
  puts
  puts 'Options:'
  puts 'A. Two separate CSV files (gray card + film base)'
  puts 'B. Single CSV file with both samples'

  print "\nSelect option (A/B): "
  choice = gets.chomp.upcase

  validator = C41Validator.new

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

    validator.analyze_from_single_csv(csv_file)

  else
    puts 'Invalid choice. Please select A or B.'
  end
end

def main
  # Check if CSV file was provided as command line argument
  if ARGV.length.positive?
    # csv_file = ARGV[0]
    # bit_depth = ARGV[1] ? ARGV[1].to_i : 14  # Default to 14-bit if not specified

    # unless File.exist?(csv_file)
    #   puts "❌ CSV file not found: #{csv_file}"
    #   exit(1)
    # end

    # puts "C-41 Development Validation Tool"
    # puts "Analyzing CSV file: #{csv_file}"
    # puts "Bit depth: #{bit_depth}-bit"
    # puts

    # Default values
    options = {
      bit_depth: 14,
      film: 'Gold'
    }

    # Parse flags after CSV
    OptionParser.new do |opts|
      opts.banner = 'Usage: ruby script.rb <csv_file> [options]'

      opts.on('--bit-depth N', Integer, 'Bit depth (default: 14)') do |n|
        options[:bit_depth] = n
      end

      opts.on('--film NAME', String, 'Film stock (default: Ektar)') do |name|
        options[:film] = name
      end
    end.parse!(ARGV)

    # # First positional argument is the CSV file
    # if ARGV.empty?
    #   abort("Error: CSV file path is required.\nUsage: ruby script.rb <csv_file> [--bit-depth N] [--film NAME]")
    # end

    csv_file = ARGV.shift # Removes CSV path from ARGV
    bit_depth = options[:bit_depth]
    film_stock = options[:film]
    validator = C41Validator.new(film_stock)

    # Debug
    puts "CSV: #{csv_file}"
    puts "Bit Depth: #{bit_depth}"
    puts "Film Stock: #{validator.film_stock}"

    validator.analyze_from_single_csv(csv_file, bit_depth)
    return
  end

  puts 'C-41 Development Validation Tool'
  puts '0. Import from Raw Digger CSV files'
  puts '1. Interactive measurement input'
  puts '2. Quick analysis of your current measurements'
  puts '3. Test your CSV data'
  puts '4. Custom data analysis'

  print "\nSelect option (0/1/2/3/4): "
  choice = gets.chomp

  case choice
  when '0'
    analyze_from_csv_workflow
  when '1'
    validator = C41Validator.new
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
        f.puts 'C-41 Development Analysis Results'
        f.puts '=' * 60

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
      end

      puts "Results saved to #{filename}.txt"
    end

  when '2'
    quick_analysis
  when '3'
    test_your_csv
  when '4'
    puts "\nFor custom data analysis, use the analyze_from_data() function."
    puts 'Example:'
    puts "gray_data = {'r' => {'min' => 394, 'max' => 676, 'avg' => 557.6, 'std_dev' => 27.4}, ...}"
    puts "base_data = {'r' => {'min' => 1312, 'max' => 1572, 'avg' => 1497.3, 'std_dev' => 25.2}, ...}"
    puts 'results = analyze_from_data(gray_data, base_data)'
  else
    puts 'Invalid choice. Please select 0-4.'
  end
rescue Interrupt
  puts "\n\nOperation cancelled by user."
  exit(0)
rescue StandardError => e
  puts "\nError: #{e.message}"
  exit(1)
end

# Run the main function if this file is executed directly
main if __FILE__ == $PROGRAM_NAME
