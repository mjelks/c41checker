# frozen_string_literal: true

require 'rspec'
require 'json'
require 'csv'
require_relative '../density_check' # Assumes your script is named density_check.rb

RSpec.describe DensityCheck do
  let(:mock_config) do
    {
      FILM_DENSITY_PROFILES: {
        DSLR_Flexible: {
          gray_card_density: { r: [0.4, 0.6], g: [0.3, 0.5], b: [0.2, 0.4] }
        }
      },
      DSLR_REFERENCE_RATIOS: {
        Consumer_Films: {
          ratios: {
            gray_rg: { target: 1.09, tolerance: 0.1 },
            gray_rb: { target: 3.34, tolerance: 0.1 },
            gray_gb: { target: 3.08, tolerance: 0.1 },
            base_rg: { target: 0.89, tolerance: 0.1 },
            base_rb: { target: 0.70, tolerance: 0.1 },
            base_gb: { target: 0.70, tolerance: 0.1 },
            r_contrast: { target: 0.51, tolerance: 0.1 },
            g_contrast: { target: 0.42, tolerance: 0.1 },
            b_contrast: { target: 0.30, tolerance: 0.1 }
          }
        }
      }
    }
  end

  let(:config_path) { 'test_profiles.json' }
  subject { DensityCheck.new('Consumer_Films', config_path) }

  before do
    # Mock the file system so we don't need a real profiles.json
    allow(File).to receive(:exist?).with(config_path).and_return(true)
    allow(File).to receive(:read).with(config_path).and_return(mock_config.to_json)
  end

  describe '#initialize' do
    it 'sets default values correctly' do
      expect(subject.ratio_profile).to eq('Consumer_Films')
      expect(subject.film_stock).to eq(:DSLR_Flexible)
    end

    it 'raises error if config is missing' do
      allow(File).to receive(:exist?).with('missing.json').and_return(false)
      expect { DensityCheck.new('Consumer_Films', 'missing.json') }.to raise_error(/Configuration file missing/)
    end
  end

  describe '#analyze_development' do
    let(:gray_data) { MeasurementData.new(*Array.new(4) { ChannelStats.new(500, 700, 600, 10) }) }
    let(:base_data) { MeasurementData.new(*Array.new(4) { ChannelStats.new(1500, 2500, 2000, 20) }) }

    before do
      subject.gray_card_data = gray_data
      subject.film_base_data = base_data
    end

    it 'performs a full analysis and returns a results hash' do
      results = subject.analyze_development(14)
      expect(results).to have_key('overall_status')
      expect(results['bit_depth']).to eq(14)
      expect(results['analysis_type']).to eq('DSLR_INTEGRATED')
    end

    it 'calculates correct bit depth references' do
      results16 = subject.analyze_development(16)
      expect(results16['reference_white']).to eq(65_535)
    end

    it 'raises error if data is missing' do
      subject.gray_card_data = nil
      expect { subject.analyze_development }.to raise_error(/measurements required/)
    end
  end

  describe 'Calculation Logic' do
    it 'correctly calculates density' do
      # Math.log10(16383 / 1638.3) should be 1.0
      expect(subject.send(:calculate_density, 1638.3, 16383)).to be_within(0.01).of(1.0)
    end

    it 'handles zero values in density calculation' do
      expect(subject.send(:calculate_density, 0, 16383)).to eq(Float::INFINITY)
    end
  end

  describe '#determine_combined_status' do
    let(:density_results) { { 'notes' => [] } }
    let(:ratio_results) { { 'issues' => [], 'critical_issues' => [] } }

    it 'returns GOOD when no issues are present' do
      status = subject.send(:determine_combined_status, density_results, ratio_results)
      expect(status).to include('GOOD')
    end

    it 'returns MONITOR when there are minor density notes' do
      density_results['notes'] = ['Red low', 'Blue high']
      status = subject.send(:determine_combined_status, density_results, ratio_results)
      expect(status).to include('MONITOR')
    end

    it 'returns WARNING when one critical ratio issue exists' do
      ratio_results['critical_issues'] = ['R/G ratio critical']
      status = subject.send(:determine_combined_status, density_results, ratio_results)
      expect(status).to include('WARNING - One critical ratio issue')
    end

    it 'returns CRITICAL when multiple critical issues exist' do
      ratio_results['critical_issues'] = ['R Contrast critical', 'G Contrast critical']
      status = subject.send(:determine_combined_status, density_results, ratio_results)
      expect(status).to include('CRITICAL')
    end

    it 'returns WARNING when there are 3 or more minor issues' do
      ratio_results['issues'] = ['Issue 1', 'Issue 2', 'Issue 3']
      status = subject.send(:determine_combined_status, density_results, ratio_results)
      expect(status).to include('WARNING - Multiple minor issues')
    end
  end

  describe '#analyze_from_single_csv' do
    let(:csv_path) { 'test.csv' }
    let(:csv_content) do
      [
        %w[Sample_Name Rmin Ravg Rmax Rdev Gmin Gavg Gmax Gdev Bmin Bavg Bmax Bdev G2min
           G2avg G2max G2dev],
        %w[GrayCard 600 650 700 5 500 550 600 5 100 150 200 5 500 550 600 5],
        %w[FilmBase 2000 2100 2200 10 2200 2300 2400 10 1300 1400 1500 10 2200 2300
           2400 10]
      ]
    end

    before do
      allow(File).to receive(:exist?).with(csv_path).and_return(true)
      allow(CSV).to receive(:read).with(csv_path, headers: true).and_return(
        csv_content[1..].map { |row| CSV::Row.new(csv_content[0], row) }
      )
      # Suppress puts output during tests
      allow(subject).to receive(:puts)
    end

    it 'parses CSV and runs analysis' do
      results = subject.analyze_from_single_csv(csv_path)
      expect(results['overall_status']).to be_a(String)
      expect(subject.gray_card_data.r.avg).to eq(650.0)
    end
  end
end
