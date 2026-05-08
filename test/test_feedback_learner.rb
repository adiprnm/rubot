# frozen_string_literal: true

require_relative "test_helper"

class TestFeedbackLearner < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @memory = Rubot::Memory.new(workspace: @workspace)
    @learner = Rubot::Tools::FeedbackLearner.new(memory: @memory)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_detects_no_corrections
    refute @learner.send(:correction?, "That's great, thanks!")
    refute @learner.send(:correction?, "OK")
    refute @learner.send(:correction?, "I understand")
    refute @learner.send(:correction?, "Can you help me with something else?")
    # Indonesian non-corrections
    refute @learner.send(:correction?, "Terima kasih")
    refute @learner.send(:correction?, "Oke, saya paham")
    refute @learner.send(:correction?, "Bisa bantu saya?")
    refute @learner.send(:correction?, "Saya suka ini")
  end

  def test_detects_no_pattern
    assert @learner.send(:correction?, "No, that's wrong")
    assert @learner.send(:correction?, "nope")
    assert @learner.send(:correction?, "Wrong answer")
    assert @learner.send(:correction?, "Not quite right")
  end

  def test_detects_i_meant_pattern
    assert @learner.send(:correction?, "I meant to say Python")
    assert @learner.send(:correction?, "I said use Ruby, not Python")
    assert @learner.send(:correction?, "As I mentioned before")
  end

  def test_detects_actually_pattern
    assert @learner.send(:correction?, "Actually, I use Ubuntu")
    assert @learner.send(:correction?, "No actually, that's not it")
    assert @learner.send(:correction?, "Wait no, try again")
  end

  def test_detects_dont_do_that_pattern
    assert @learner.send(:correction?, "Don't use that approach")
    assert @learner.send(:correction?, "Do not run that command")
    assert @learner.send(:correction?, "Don't say that")
  end

  def test_detects_try_again_pattern
    assert @learner.send(:correction?, "Try again")
    assert @learner.send(:correction?, "Try something else")
    assert @learner.send(:correction?, "Different approach please")
    assert @learner.send(:correction?, "Another way to do this")
  end

  def test_detects_you_forgot_pattern
    assert @learner.send(:correction?, "You forgot the important part")
    assert @learner.send(:correction?, "You missed something")
    assert @learner.send(:correction?, "You overlooked the error")
  end

  def test_detects_i_told_you_pattern
    assert @learner.send(:correction?, "I told you I use Mac")
    assert @learner.send(:correction?, "I already said that")
    assert @learner.send(:correction?, "I already told you twice")
  end

  # --- Bahasa Indonesia patterns ---

  def test_detects_bukan_pattern
    assert @learner.send(:correction?, "Bukan begitu")
    assert @learner.send(:correction?, "Bukan itu yang saya maksud")
    assert @learner.send(:correction?, "bukan seperti itu")
    assert @learner.send(:correction?, "bukan yang itu")
    assert @learner.send(:correction?, "Bukan")
  end

  def test_detects_salah_pattern
    assert @learner.send(:correction?, "Salah")
    assert @learner.send(:correction?, "Salah itu")
    assert @learner.send(:correction?, "jawabannya salah")
    assert @learner.send(:correction?, "itu salah")
    assert @learner.send(:correction?, "kurang tepat")
    assert @learner.send(:correction?, "tidak tepat")
  end

  def test_detects_maksud_saya_pattern
    assert @learner.send(:correction?, "Maksud saya bukan begitu")
    assert @learner.send(:correction?, "maksud gue beda")
    assert @learner.send(:correction?, "yang saya maksud itu")
    assert @learner.send(:correction?, "bukan itu yang saya maksud")
  end

  def test_detects_sebenarnya_pattern
    assert @learner.send(:correction?, "Sebenarnya saya pakai Linux")
    assert @learner.send(:correction?, "tapi sebenarnya bukan")
    assert @learner.send(:correction?, "seharusnya pakai Ruby")
  end

  def test_detects_jangan_pattern
    assert @learner.send(:correction?, "Jangan begitu")
    assert @learner.send(:correction?, "jangan lakukan itu")
    assert @learner.send(:correction?, "stop")
    assert @learner.send(:correction?, "berhenti")
    assert @learner.send(:correction?, "cukup")
  end

  def test_detects_coba_lagi_pattern
    assert @learner.send(:correction?, "Coba lagi")
    assert @learner.send(:correction?, "coba lain")
    assert @learner.send(:correction?, "cara lain")
    assert @learner.send(:correction?, "ganti cara")
    assert @learner.send(:correction?, "pakai cara lain")
  end

  def test_detects_udah_saya_bilang_pattern
    assert @learner.send(:correction?, "Udah saya bilang")
    assert @learner.send(:correction?, "sudah saya bilang")
    assert @learner.send(:correction?, "udah saya kasih tahu")
    assert @learner.send(:correction?, "sudah saya katakan")
  end

  def test_detects_kamu_salah_pattern
    assert @learner.send(:correction?, "Kamu lupa")
    assert @learner.send(:correction?, "kamu salah")
    assert @learner.send(:correction?, "kau salah")
    assert @learner.send(:correction?, "lo salah")
    assert @learner.send(:correction?, "elo salah")
  end

  def test_detects_tidak_bukan_combination
    assert @learner.send(:correction?, "Tidak, bukan itu")
    assert @learner.send(:correction?, "nggak salah itu")
    assert @learner.send(:correction?, "enggak begitu")
    assert @learner.send(:correction?, "gak tepat")
  end

  def test_stores_correction_in_memory
    turns = [
      { "role" => "user", "content" => "What language do I use?" },
      { "role" => "assistant", "content" => "You use Python." }
    ]

    result = @learner.process("No, I use Ruby, not Python", turns)
    assert result

    content = @memory.read
    assert_includes content, "Learned Corrections"
    assert_includes content, "What language do I use?"
    assert_includes content, "I use Ruby, not Python"
  end

  def test_stores_correction_in_indonesian
    turns = [
      { "role" => "user", "content" => "Saya pakai bahasa apa?" },
      { "role" => "assistant", "content" => "Anda pakai bahasa Inggris." }
    ]

    result = @learner.process("Salah, saya pakai bahasa Indonesia", turns)
    assert result

    content = @memory.read
    assert_includes content, "Learned Corrections"
    assert_includes content, "Saya pakai bahasa apa?"
    assert_includes content, "bahasa Indonesia"
  end

  def test_does_not_store_without_previous_turns
    turns = []
    result = @learner.process("No that's wrong", turns)
    refute result
  end

  def test_does_not_store_non_correction
    turns = [
      { "role" => "user", "content" => "What language do I use?" },
      { "role" => "assistant", "content" => "You use Python." }
    ]

    result = @learner.process("Thanks, that helps!", turns)
    refute result
  end

  def test_system_prompt_empty_when_no_corrections
    prompt = @learner.to_system_prompt
    assert_empty prompt
  end

  def test_system_prompt_includes_corrections
    @memory.append("Learned Corrections", "Test correction example")
    prompt = @learner.to_system_prompt
    assert_includes prompt, "Learned Corrections"
    assert_includes prompt, "Test correction example"
    assert_includes prompt, "avoid the mistake"
  end

  def test_execute_is_not_callable_by_llm
    result = @learner.execute({})
    assert_includes result, "Internal tool"
  end

  def test_truncates_long_corrections
    long_request = "x" * 300
    long_response = "y" * 300
    long_correction = "z" * 300

    turns = [
      { "role" => "user", "content" => long_request },
      { "role" => "assistant", "content" => long_response }
    ]

    @learner.process(long_correction, turns)
    content = @memory.read

    # Each should be truncated to 200 + "..."
    refute_includes content, long_request
    refute_includes content, long_response
    refute_includes content, long_correction
  end

  def test_no_memory_configured
    learner = Rubot::Tools::FeedbackLearner.new(memory: nil)
    turns = [
      { "role" => "user", "content" => "test" },
      { "role" => "assistant", "content" => "response" }
    ]
    result = learner.process("No, wrong", turns)
    refute result
  end
end
