require_relative "pdca_generator_helper"

class ReplyContractTest < GeneratorCase
  def test_valid_output_keeps_three_variants
    result = generator({ "replies" => valid_replies }).call
    assert_equal valid_replies, result.replies
    assert_equal false, result.mock
  end
  def test_valid_output_appends_signature
    result = generator({ "replies" => valid_replies }, signature: "合成署名").call
    assert_equal valid_replies.map { |r| r.merge("text" => r["text"] + "\n\n合成署名") }, result.replies
  end
  def test_thinking_block_is_not_used_as_reply_text
    blocks = [Struct.new(:type, :text).new(:thinking, "synthetic thought"), Struct.new(:type, :text).new(:text, JSON.generate({ "replies" => valid_replies }))]
    assert_equal valid_replies, generator(nil, blocks: blocks).call.replies
  end
  def test_mock_still_returns_three_replies_without_sdk
    ENV.delete("ANTHROPIC_API_KEY")
    result = generator(nil).call
    assert_equal true, result.mock
    assert_equal 3, result.replies.length
  end
  def test_missing_text_block_is_an_error
    error = assert_raises(RuntimeError) { generator(nil, blocks: []).call }
    assert_match(/生成結果/, error.message)
  end
end
