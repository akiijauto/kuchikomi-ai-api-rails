require "json"
require "minitest/autorun"

# Isolated service tests: do not load Rails, authentication or the real SDK.
$LOADED_FEATURES << "anthropic.rb"
module Anthropic
  class Client
    def self.new(*) = raise("Real SDK access is forbidden in these tests")
  end
end
require_relative "../app/services/reply_generator"

class GeneratorCase < Minitest::Test
  Profile = Struct.new(:signature, :store_name, :tone, :industry, keyword_init: true)
  def setup
    @key = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "pdca-dummy"
  end
  def teardown
    @key ? ENV["ANTHROPIC_API_KEY"] = @key : ENV.delete("ANTHROPIC_API_KEY")
  end
  def valid_replies
    3.times.map { |i| { "label" => "案#{i + 1}", "text" => "合成の返信#{i + 1}" } }
  end
  def generator(payload, signature: "", blocks: nil)
    profile = Profile.new(signature: signature, store_name: "合成店", tone: "polite", industry: "fixture")
    result = ReplyGenerator.new(profile: profile, review_text: "合成の口コミです", rating: 5)
    content = blocks || [Struct.new(:type, :text).new(:text, JSON.generate(payload))]
    fake = Object.new
    fake.define_singleton_method(:messages) { self }
    fake.define_singleton_method(:create) { |**_args| Struct.new(:content).new(content) }
    result.define_singleton_method(:client) { fake }
    result
  end
end

# Optional machine report for the offline orchestrator, using only Minitest.
if ENV["PDCA_REPORT"]
  class PDCARubyReporter < Minitest::AbstractReporter
    def initialize; @results = []; end
    def record(result)
      @results << { name: result.name, passed: !!result.passed?, skipped: !!result.skipped?,
        error: !!result.error?, failures: result.failures.map(&:message) }
    end
    def report
      File.write(ENV.fetch("PDCA_REPORT"), JSON.generate(@results))
    end
  end
  module Minitest
    def self.plugin_pdca_init(_options)
      reporter << PDCARubyReporter.new
    end
  end
  Minitest.extensions << "pdca"
end
