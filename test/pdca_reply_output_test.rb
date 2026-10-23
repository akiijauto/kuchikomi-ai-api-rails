require_relative "pdca_generator_helper"

class ReplyOutputTest < GeneratorCase
  invalid = {
    null_replies: nil,
    string_replies: "unexpected",
    object_replies: { "label" => "案", "text" => "本文" },
    zero_replies: [],
    two_replies: [{ "label" => "案", "text" => "本文" }] * 2,
    four_replies: [{ "label" => "案", "text" => "本文" }] * 4,
    non_object_item: [nil, nil, nil],
    numeric_label: [{ "label" => 7, "text" => "本文" }] * 3,
    numeric_text: [{ "label" => "案", "text" => 7 }] * 3,
    blank_label: [{ "label" => " \t", "text" => "本文" }] * 3,
    blank_text: [{ "label" => "案", "text" => " \n" }] * 3,
    missing_text: [{ "label" => "案" }] * 3
  }
  invalid.each do |name, replies|
    define_method("test_rejects_#{name}") do
      error = assert_raises(RuntimeError) { generator({ "replies" => replies }).call }
      assert_match(/生成結果/, error.message)
    end
  end
end
