# Multiple-choice reformulations of all 5 gotcha test families.
#
# Phase 5D uses these for logprobs-based constrained answer extraction.
# The MC format converts "can the model generate the correct insight?" into
# "can the model recognize the correct answer from options?" — more aligned
# with real decision-making, and how MMLU/ARC/HellaSwag actually work.
#
# Both solo baseline and collective use the same MC format for fair comparison.

defmodule Cortex.Benchmark.MCSuite do
  @questions %{
    "A1" => %{
      question: "I need a car wash. The car wash is 50 meters away. Should I walk?",
      mc_prompt: """
      Q: I need a car wash. The car wash is 50 meters away. Should I walk?
      A) Yes, it's only 50 meters — just walk there
      B) No, you need to drive your car there to get it washed
      C) Take a taxi instead
      D) It depends on the weather""",
      correct: "B"
    },
    "A2" => %{
      question:
        "Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?",
      mc_prompt: """
      Q: Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?
      A) The basket (where she left it)
      B) The box (where Anne moved it)
      C) She will look in both places
      D) She won't look for it""",
      correct: "A"
    },
    "A3" => %{
      question: "A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?",
      mc_prompt: """
      Q: A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?
      A) 7
      B) 8
      C) 15
      D) 0""",
      correct: "B"
    },
    "A4" => %{
      question:
        "A man builds a house where all four walls face south. A bear walks past the house. What color is the bear?",
      mc_prompt: """
      Q: A man builds a house where all four walls face south. A bear walks past the house. What color is the bear?
      A) Brown
      B) Black
      C) White
      D) Cannot be determined""",
      correct: "C"
    },
    "A5" => %{
      question: "I have a brother. My brother has no brothers. How is this possible?",
      mc_prompt: """
      Q: I have a brother. My brother has no brothers. How is this possible?
      A) The speaker is female (a sister)
      B) They are half-brothers
      C) The brother was adopted
      D) They are not actually related""",
      correct: "A"
    }
  }

  @correct_answers Map.new(@questions, fn {id, q} -> {id, q.correct} end)

  def questions, do: @questions
  def correct_answers, do: @correct_answers
  def test_ids, do: ~w(A1 A2 A3 A4 A5)

  def get(test_id), do: Map.fetch!(@questions, test_id)

  def mc_prompt(test_id), do: get(test_id).mc_prompt
  def correct(test_id), do: get(test_id).correct
  def question(test_id), do: get(test_id).question
end
