# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative '../replenishment_check'

RSpec.describe ReplenishmentCheck do
  def roll(dev: 'dev04', number: 1, util: { 'r' => 50.0, 'g' => 55.0, 'b' => 30.0 }, baseline: nil)
    entry = {
      'dev' => dev, 'rolls_since_mix' => number, 'gray_target' => 'pavement',
      'scan' => { 'utilization' => util },
      'metrics' => { 'base_rg' => 0.9, 'base_rb' => 1.6, 'base_gb' => 1.8, 'gray_rg' => 1.0,
                     'r_contrast' => 0.4, 'g_contrast' => 0.4, 'b_contrast' => 0.25, 'timestamp' => 1 }
    }
    entry['baseline'] = true if baseline
    entry
  end

  def checker_with(*rolls)
    path = File.join(@dir, 'history.json')
    File.write(path, JSON.generate(rolls))
    described_class.new(path)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  describe 'thin scan detection' do
    subject(:checker) { checker_with(roll) }

    it 'flags R or G below the cutoff and keeps borderline scans' do
      expect(checker.thin_scan?(roll(util: { 'r' => 34.9, 'g' => 55.0, 'b' => 30.0 }))).to be(true)
      expect(checker.thin_scan?(roll(util: { 'r' => 36.0, 'g' => 40.5, 'b' => 17.7 }))).to be(false)
    end

    it 'treats blue below its own cutoff as thin without discarding the roll' do
      thin_blue = roll(util: { 'r' => 36.0, 'g' => 40.5, 'b' => 17.7 })
      expect(checker.blue_thin?(thin_blue)).to be(true)
      expect(checker.usable_metrics(thin_blue).keys).not_to include(*described_class::BLUE_KEYS)
      expect(checker.usable_metrics(thin_blue)).to include('base_rg', 'r_contrast')
    end
  end

  describe '#exposure_gap' do
    it 'is the largest R/G utilization gap vs the reference median' do
      prior = [roll(util: { 'r' => 51.0, 'g' => 57.0, 'b' => 33.0 })]
      latest = roll(util: { 'r' => 39.0, 'g' => 46.0, 'b' => 21.0 })
      expect(checker_with(*prior).exposure_gap(latest, prior)).to be_within(0.01).of(12.0)
    end

    it 'is zero without utilization data' do
      expect(checker_with(roll).exposure_gap({}, [roll])).to eq(0.0)
    end
  end

  describe '#apply_exposure_caveat' do
    subject(:checker) { checker_with(roll) }

    it 'caps CRITICAL at WARNING when exposure differs a lot' do
      status = { 'level' => :critical, 'message' => '❌ CRITICAL: shifted' }
      checker.apply_exposure_caveat(status, 12.0)
      expect(status['level']).to eq(:warning)
      expect(status['message']).to include('WARNING', 'may be exposure, not chemistry')
    end

    it 'leaves the status alone when exposure is close' do
      status = { 'level' => :critical, 'message' => '❌ CRITICAL: shifted' }
      checker.apply_exposure_caveat(status, 5.0)
      expect(status).to eq({ 'level' => :critical, 'message' => '❌ CRITICAL: shifted' })
    end
  end

  describe 'baseline selection' do
    let(:rolls) { [roll(number: 10), roll(number: 20), roll(number: 28), roll(number: 30)] }

    it 'defaults to the first 3-5 usable rolls of the batch' do
      expect(checker_with(*rolls).baseline_rolls.map { |r| r['rolls_since_mix'] }).to eq([10, 20, 28, 30])
      many = (1..7).map { |n| roll(number: n) }
      expect(checker_with(*many).baseline_rolls.map { |r| r['rolls_since_mix'] }).to eq([1, 2, 3, 4, 5])
      expect(checker_with(*many.first(2)).baseline_rolls).to be_empty
    end

    it 'uses chosen rolls when set' do
      checker = checker_with(*rolls)
      checker.set_baseline(dev: 'dev04', rolls: [20, 30])
      expect(checker.baseline_rolls.map { |r| r['rolls_since_mix'] }).to eq([20, 30])
      expect(checker.baseline_description).to eq('chosen rolls: 20, 30')
    end

    it 'persists the choice and can be cleared' do
      checker = checker_with(*rolls)
      checker.set_baseline(dev: 'dev04', rolls: [20])
      expect(described_class.new(checker.history_file).baseline_chosen?).to be(true)
      checker.set_baseline(dev: 'dev04', clear: true)
      expect(described_class.new(checker.history_file).baseline_chosen?).to be(false)
    end

    it 'aborts without changing anything when no rolls match' do
      checker = checker_with(*rolls)
      expect { checker.set_baseline(dev: 'dev04', rolls: [99]) }.to raise_error(SystemExit).and output(/No rolls/).to_stderr
      expect(checker.baseline_chosen?).to be(false)
    end
  end
end
