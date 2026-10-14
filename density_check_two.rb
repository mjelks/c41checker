#!/usr/bin/env ruby
# DSLR C-41 Lab-Grade Validator | Optimized for RawDigger CSV Exports
# Targeted for Sony a7R IV (14-bit) & 20ml Replenishment Workflows

require 'csv'

ChannelStats = Struct.new(:avg)
MeasurementData = Struct.new(:r, :g, :b, :g2)

class LabValidator
  def initialize
    @targets = {
      r_contrast: 0.51,
      g_contrast: 0.42,
      b_contrast: 0.26,
      gray_rg: 1.09
    }
  end

  def run(csv_path, bit_depth = 14)
    unless File.exist?(csv_path)
      puts "❌ Error: File not found #{csv_path}"
      return
    end

    # Explicitly handling the CSV format from your snippet
    rows = CSV.read(csv_path, headers: true)
    @gray = dict_to_measure(parse_row(rows[0]))
    @base = dict_to_measure(parse_row(rows[1]))
    
    ref_white = (2**bit_depth) - 1
    
    print_header(bit_depth)
    render_scan_health(ref_white)
    render_chemistry_analysis
    render_replenishment_report
  end

  private

  def parse_row(row)
    {
      'r'  => row['Ravg'].to_f,
      'g'  => row['Gavg'].to_f,
      'b'  => row['Bavg'].to_f,
      'g2' => row['G2avg'].to_f
    }
  end

  def dict_to_measure(dict)
    MeasurementData.new(
      ChannelStats.new(dict['r']),
      ChannelStats.new(dict['g']),
      ChannelStats.new(dict['b']),
      ChannelStats.new(dict['g2'])
    )
  end

  def print_header(bits)
    puts "\n" + "="*80
    puts "🔬 C-41 LABORATORY CONTROL REPORT | BITS: #{bits}".center(80)
    puts "="*80
  end

  def render_scan_health(ref_white)
    puts "\n📸 SCAN TELEMETRY (HARDWARE)"
    puts "-"*80
    puts "%-10s %-15s %-15s %-15s" % ["Channel", "Utilization", "Abs Density", "Status"]
    
    # We use the Base (Row 2) to check the brightest point of the scan
    channels = { "R" => @base.r.avg, "G" => @base.g.avg, "B" => @base.b.avg }
    
    channels.each do |ch, val|
      util = (val / ref_white.to_f) * 100
      dens = Math.log10(ref_white / val)
      status = util < 40 ? "⚠️  THIN" : (util > 92 ? "🚫 CLIPPING" : "✅ OPTIMAL")
      puts "%-10s %-15s %-15.2f %-15s" % [ch, "#{util.round(1)}%", dens.round(2), status]
    end

    max_u = [@base.r.avg, @base.g.avg].max / ref_white.to_f * 100
    stops = Math.log2(85.0 / max_u).round(1)
    
    puts "\n👉 ADVICE: Increase exposure by +#{stops} stops for the next scan."
    puts "   This will move your Green/Red channels from ~10% to 85% utilization."
  end

  def render_chemistry_analysis
    puts "\n🧪 CHEMISTRY & RATIO ANALYSIS"
    puts "-"*80
    puts "%-15s %-10s %-10s %-10s %-10s" % ["Metric", "Sample", "Target", "Dev %", "Status"]
    
    @results = {
      r_contrast: @gray.r.avg / @base.r.avg,
      g_contrast: @gray.g.avg / @base.g.avg,
      b_contrast: @gray.b.avg / @base.b.avg,
      gray_rg: @gray.r.avg / @gray.g.avg
    }

    @results.each do |key, val|
      target = @targets[key]
      dev = ((val - target) / target * 100).round(1)
      status = dev.abs < 15 ? "✅" : "❌"
      puts "%-15s %-10.3f %-10.3f %-10.1f %-10s" % [key.to_s.upcase, val, target, dev, status]
    end
  end

  def render_replenishment_report
    puts "\n♻️  REPLENISHMENT & CROSSOVER"
    puts "-"*80
    
    # Potency check
    avg_dev = ((@results[:r_contrast] - @targets[:r_contrast]) / @targets[:r_contrast] + 
               (@results[:g_contrast] - @targets[:g_contrast]) / @targets[:g_contrast]) / 2.0 * 100

    if avg_dev < -10
      puts "📉 POTENCY: LOW. Developer tiring. Check 20ml replenishment rate."
    elsif avg_dev > 10
      puts "📈 POTENCY: HIGH. Over-active chemistry."
    else
      puts "💎 POTENCY: STABLE. Replenishment equilibrium reached."
    end

    # Crossover check
    spread = ((@results[:r_contrast] / @targets[:r_contrast]) - (@results[:g_contrast] / @targets[:g_contrast])).abs * 100
    if spread > 8
      puts "🌈 CROSSOVER: DETECTED (#{spread.round(1)}% drift)."
    else
      puts "🌈 PARALLELISM: EXCELLENT."
    end
  end
end

# CLI
if ARGV[0]
  LabValidator.new.run(ARGV[0], ARGV[1] ? ARGV[1].to_i : 14)
else
  puts "Usage: ruby validator.rb <csv> [bit_depth]"
end