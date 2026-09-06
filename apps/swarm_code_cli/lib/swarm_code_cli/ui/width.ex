defmodule SwarmCodeCLI.UI.Width do
  @moduledoc "Unicode 17.0.0 terminal-cell measurement without grapheme splitting."

  import Bitwise
  alias SwarmCodeCLI.UI.Width.Table

  @default 0x0000
  @line_feed 0x0001
  @emoji_modifier 0x0002
  @regional_indicator 0x0003
  @several_regional_indicator 0x0004
  @emoji_presentation 0x0005
  @zwj_emoji_presentation 0x1006
  @keycap_zwj_emoji_presentation 0x1007
  @regional_indicator_zwj_presentation 0x0009
  @even_regional_indicator_zwj_presentation 0x000A
  @odd_regional_indicator_zwj_presentation 0x000B
  @tag_end_zwj_emoji_presentation 0x0010
  @tag_d1_end_zwj_emoji_presentation 0x0011
  @tag_d2_end_zwj_emoji_presentation 0x0012
  @tag_d3_end_zwj_emoji_presentation 0x0013
  @tag_a1_end_zwj_emoji_presentation 0x0019
  @tag_a2_end_zwj_emoji_presentation 0x001A
  @tag_a3_end_zwj_emoji_presentation 0x001B
  @tag_a4_end_zwj_emoji_presentation 0x001C
  @tag_a5_end_zwj_emoji_presentation 0x001D
  @tag_a6_end_zwj_emoji_presentation 0x001E
  @kirat_rai_vowel_sign_e 0x0020
  @kirat_rai_vowel_sign_ai 0x0021
  @variation_selector_1_2_or_3 0x0200
  @variation_selector_15 0x4000
  @variation_selector_16 0x8000
  @joining_group_alef 0x30FF
  @combining_long_solidus_overlay 0x3CFF
  @solidus_overlay_alef 0x38FF
  @hebrew_letter_lamed 0x3800
  @buginese_letter_ya 0x3801
  @buginese_vowel_sign_i_zwj_letter_ya 0x3C02
  @tifinagh_consonant 0x3803
  @tifinagh_joiner_consonant 0x3C04
  @lisu_tone_letter_mya_na_jeu 0x3C05
  @old_turkic_letter_orkhon_i 0x3806
  @khmer_coeng_eligible_letter 0x3C07
  @ellipsis "…"

  @spec graphemes(binary()) :: [binary()]
  def graphemes(binary) when is_binary(binary), do: String.graphemes(binary)

  @spec cells(binary(), :narrow | :wide) :: non_neg_integer()
  def cells(binary, ambiguous) when is_binary(binary) and ambiguous in [:narrow, :wide] do
    binary
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.reduce({0, @default}, fn cp, {sum, next_info} ->
      {add, info} = width_in_string(cp, next_info, ambiguous)
      {sum + add, info}
    end)
    |> elem(0)
  end

  @spec take_cells(binary(), non_neg_integer(), :narrow | :wide) ::
          {binary(), binary(), non_neg_integer()}
  def take_cells(binary, limit, ambiguous)
      when is_binary(binary) and is_integer(limit) and limit >= 0 and
             ambiguous in [:narrow, :wide] do
    take_prefix(binary, limit, ambiguous, "", 0)
  end

  @spec wrap(binary(), pos_integer(), :narrow | :wide) :: [binary()]
  def wrap(binary, width, ambiguous)
      when is_binary(binary) and is_integer(width) and width > 0 and
             ambiguous in [:narrow, :wide] do
    if binary == "" do
      []
    else
      binary
      |> String.split(["\r\n", "\n"])
      |> Enum.flat_map(fn
        "" -> [""]
        line -> do_wrap(line, width, ambiguous, [])
      end)
    end
  end

  @spec elide(binary(), non_neg_integer(), :end | :middle, :narrow | :wide) :: binary()
  def elide(binary, limit, position, ambiguous)
      when is_binary(binary) and is_integer(limit) and limit >= 0 and position in [:end, :middle] and
             ambiguous in [:narrow, :wide] do
    if cells(binary, ambiguous) <= limit do
      binary
    else
      ellipsis_width = cells(@ellipsis, ambiguous)

      cond do
        limit < ellipsis_width -> ""
        position == :end -> end_elide(binary, limit - ellipsis_width, ambiguous)
        true -> middle_elide(binary, limit - ellipsis_width, ambiguous)
      end
    end
  end

  defp take_prefix(remaining, limit, ambiguous, prefix, used) do
    case String.next_grapheme(remaining) do
      nil ->
        {prefix, "", used}

      {grapheme, tail} ->
        candidate = prefix <> grapheme
        candidate_width = cells(candidate, ambiguous)

        if candidate_width <= limit,
          do: take_prefix(tail, limit, ambiguous, candidate, candidate_width),
          else: {prefix, remaining, used}
    end
  end

  defp do_wrap(<<>>, _width, _ambiguous, acc), do: Enum.reverse(acc)

  defp do_wrap(binary, width, ambiguous, acc) do
    {head, tail, _} = take_cells(binary, width, ambiguous)

    if head == "" do
      {first, rest} = String.next_grapheme(binary)
      do_wrap(rest, width, ambiguous, [first | acc])
    else
      do_wrap(tail, width, ambiguous, [head | acc])
    end
  end

  defp end_elide(binary, available, ambiguous) do
    {head, _, _} = take_cells(binary, available, ambiguous)
    head <> @ellipsis
  end

  defp middle_elide(binary, available, ambiguous) do
    left_target = div(available, 2)
    {left, _, left_width} = take_cells(binary, left_target, ambiguous)
    right_target = available - left_width

    # Keep the original grapheme boundaries: joining reversed flag sequences
    # and segmenting again can pair different regional indicators.
    right =
      binary
      |> graphemes()
      |> Enum.reverse()
      |> take_suffix(right_target, ambiguous, "")

    candidate = left <> @ellipsis <> right

    if cells(candidate, ambiguous) <= available + cells(@ellipsis, ambiguous),
      do: candidate,
      else: end_elide(binary, available, ambiguous)
  end

  defp take_suffix([], _limit, _ambiguous, suffix), do: suffix

  defp take_suffix([grapheme | rest], limit, ambiguous, suffix) do
    candidate = grapheme <> suffix

    if cells(candidate, ambiguous) <= limit,
      do: take_suffix(rest, limit, ambiguous, candidate),
      else: suffix
  end

  defp width_in_string(cp, next_info, mode) do
    next_info =
      if emoji_presentation?(next_info) and not Table.starts_emoji_presentation_seq?(cp),
        do: unset_emoji_presentation(next_info),
        else: next_info

    cond do
      emoji_presentation?(next_info) and Table.starts_emoji_presentation_seq?(cp) ->
        {if(zwj_emoji_presentation?(next_info), do: 0, else: 2), @emoji_presentation}

      mode == :wide and next_info in [@combining_long_solidus_overlay, @solidus_overlay_alef] and
          cp in [?<, ?=, ?>] ->
        {2, @default}

      cp <= 0xA0 ->
        case cp do
          ?\n -> {1, @line_feed}
          ?\r when next_info == @line_feed -> {0, @default}
          _ -> {1, @default}
        end

      true ->
        width_non_ascii(cp, next_info, mode)
    end
  end

  defp width_non_ascii(cp, next_info, mode) do
    cond do
      next_info != @default and cp == 0xFE0F ->
        {0, set_emoji_presentation(next_info)}

      next_info != @default and variation_1_2_or_3?(cp, mode) ->
        {0, set_vs1_2_3(next_info)}

      next_info != @default and mode == :narrow and cp == 0xFE0E ->
        {0, set_text_presentation(next_info)}

      text_presentation?(next_info) and Table.starts_non_ideographic_text_presentation_seq?(cp) ->
        {1, @default}

      vs1_2_3?(next_info) and cp in [0x2018, 0x2019, 0x201C, 0x201D] ->
        {if(mode == :narrow, do: 2, else: 1), @default}

      ligature_transparent?(next_info) and cp == 0x200D ->
        {0, set_zwj_bit(next_info)}

      ligature_transparent?(next_info) and Table.ligature_transparent?(cp) ->
        {0, next_info}

      true ->
        match_state(cp, clear_unmatched_variation(next_info), mode)
    end
  end

  defp match_state(cp, next_info, mode) do
    cond do
      mode == :wide and next_info == @combining_long_solidus_overlay and
          Table.solidus_transparent?(cp) ->
        {Table.width(cp, mode), @combining_long_solidus_overlay}

      mode == :wide and next_info == @joining_group_alef and cp == 0x338 ->
        {0, @solidus_overlay_alef}

      next_info in [@joining_group_alef, @solidus_overlay_alef] and lam?(cp) ->
        {0, @default}

      next_info == @joining_group_alef and Table.transparent_zero_width?(cp) ->
        {0, @joining_group_alef}

      next_info == set_zwj_bit(@hebrew_letter_lamed) and cp == 0x5D0 ->
        {0, @default}

      next_info == @khmer_coeng_eligible_letter and cp == 0x17D2 ->
        {-1, @default}

      next_info == set_zwj_bit(@buginese_letter_ya) and cp == 0x1A17 ->
        {0, @buginese_vowel_sign_i_zwj_letter_ya}

      next_info == @buginese_vowel_sign_i_zwj_letter_ya and cp == 0x1A15 ->
        {0, @default}

      next_info in [@tifinagh_consonant, set_zwj_bit(@tifinagh_consonant)] and cp == 0x2D7F ->
        {1, @tifinagh_joiner_consonant}

      next_info == set_zwj_bit(@tifinagh_consonant) and tifinagh_consonant?(cp) ->
        {0, @default}

      next_info == @tifinagh_joiner_consonant and tifinagh_consonant?(cp) ->
        {-1, @default}

      next_info == @lisu_tone_letter_mya_na_jeu and cp in 0xA4F8..0xA4FB ->
        {0, @default}

      next_info == set_zwj_bit(@old_turkic_letter_orkhon_i) and cp == 0x10C32 ->
        {0, @default}

      next_info == @emoji_modifier and Table.emoji_modifier_base?(cp) ->
        {0, @emoji_presentation}

      next_info in [@regional_indicator, @several_regional_indicator] and regional_indicator?(cp) ->
        {1, @several_regional_indicator}

      next_info in [
        @emoji_presentation,
        @several_regional_indicator,
        @even_regional_indicator_zwj_presentation,
        @odd_regional_indicator_zwj_presentation,
        @emoji_modifier
      ] and cp == 0x200D ->
        {0, @zwj_emoji_presentation}

      next_info == @zwj_emoji_presentation and cp == 0x20E3 ->
        {0, @keycap_zwj_emoji_presentation}

      next_info == set_emoji_presentation(@zwj_emoji_presentation) and
          Table.starts_emoji_presentation_seq?(cp) ->
        {0, @emoji_presentation}

      next_info == set_emoji_presentation(@keycap_zwj_emoji_presentation) and keycap_base?(cp) ->
        {0, @emoji_presentation}

      next_info == @zwj_emoji_presentation and regional_indicator?(cp) ->
        {1, @regional_indicator_zwj_presentation}

      next_info in [
        @regional_indicator_zwj_presentation,
        @odd_regional_indicator_zwj_presentation
      ] and
          regional_indicator?(cp) ->
        {-1, @even_regional_indicator_zwj_presentation}

      next_info == @even_regional_indicator_zwj_presentation and regional_indicator?(cp) ->
        {3, @odd_regional_indicator_zwj_presentation}

      next_info == @zwj_emoji_presentation and emoji_modifier?(cp) ->
        {0, @emoji_modifier}

      next_info == @zwj_emoji_presentation and cp == 0xE007F ->
        {0, @tag_end_zwj_emoji_presentation}

      next_info == @tag_end_zwj_emoji_presentation and tag_letter?(cp) ->
        {0, @tag_a1_end_zwj_emoji_presentation}

      next_info == @tag_a1_end_zwj_emoji_presentation and tag_letter?(cp) ->
        {0, @tag_a2_end_zwj_emoji_presentation}

      next_info == @tag_a2_end_zwj_emoji_presentation and tag_letter?(cp) ->
        {0, @tag_a3_end_zwj_emoji_presentation}

      next_info == @tag_a3_end_zwj_emoji_presentation and tag_letter?(cp) ->
        {0, @tag_a4_end_zwj_emoji_presentation}

      next_info == @tag_a4_end_zwj_emoji_presentation and tag_letter?(cp) ->
        {0, @tag_a5_end_zwj_emoji_presentation}

      next_info == @tag_a5_end_zwj_emoji_presentation and tag_letter?(cp) ->
        {0, @tag_a6_end_zwj_emoji_presentation}

      next_info in [
        @tag_end_zwj_emoji_presentation,
        @tag_a1_end_zwj_emoji_presentation,
        @tag_a2_end_zwj_emoji_presentation,
        @tag_a3_end_zwj_emoji_presentation,
        @tag_a4_end_zwj_emoji_presentation
      ] and tag_digit?(cp) ->
        {0, @tag_d1_end_zwj_emoji_presentation}

      next_info == @tag_d1_end_zwj_emoji_presentation and tag_digit?(cp) ->
        {0, @tag_d2_end_zwj_emoji_presentation}

      next_info == @tag_d2_end_zwj_emoji_presentation and tag_digit?(cp) ->
        {0, @tag_d3_end_zwj_emoji_presentation}

      next_info in [
        @tag_a3_end_zwj_emoji_presentation,
        @tag_a4_end_zwj_emoji_presentation,
        @tag_a5_end_zwj_emoji_presentation,
        @tag_a6_end_zwj_emoji_presentation,
        @tag_d3_end_zwj_emoji_presentation
      ] and cp == 0x1F3F4 ->
        {0, @emoji_presentation}

      next_info == @zwj_emoji_presentation and
          elem(Table.width_info(cp, mode), 1) == @emoji_presentation ->
        {0, @emoji_presentation}

      next_info == @kirat_rai_vowel_sign_e and cp == 0x16D63 ->
        {0, @default}

      next_info == @kirat_rai_vowel_sign_e and cp == 0x16D67 ->
        {0, @kirat_rai_vowel_sign_ai}

      next_info == @kirat_rai_vowel_sign_e and cp == 0x16D68 ->
        {1, @kirat_rai_vowel_sign_e}

      next_info == @kirat_rai_vowel_sign_e and cp == 0x16D69 ->
        {0, @default}

      next_info == @kirat_rai_vowel_sign_ai and cp == 0x16D63 ->
        {0, @default}

      true ->
        Table.width_info(cp, mode)
    end
  end

  defp clear_unmatched_variation(info) do
    cond do
      text_presentation?(info) -> unset_text_presentation(info)
      vs1_2_3?(info) -> unset_vs1_2_3(info)
      true -> info
    end
  end

  defp emoji_presentation?(info), do: (info &&& @variation_selector_16) == @variation_selector_16
  defp zwj_emoji_presentation?(info), do: (info &&& 0xB000) == 0x9000
  defp text_presentation?(info), do: (info &&& @variation_selector_15) == @variation_selector_15
  defp vs1_2_3?(info), do: (info &&& @variation_selector_1_2_or_3) == @variation_selector_1_2_or_3
  defp ligature_transparent?(info), do: (info &&& 0x0800) == 0x0800
  defp set_zwj_bit(info), do: info ||| 0x0400

  defp set_emoji_presentation(info) do
    if (info &&& 0x2000) == 0x2000 or (info &&& 0x9000) == 0x1000,
      do:
        (info ||| @variation_selector_16) &&&
          bnot(@variation_selector_15 ||| @variation_selector_1_2_or_3),
      else: @variation_selector_16
  end

  defp unset_emoji_presentation(info) do
    if (info &&& 0x2000) == 0x2000, do: info &&& bnot(@variation_selector_16), else: @default
  end

  defp set_text_presentation(info) do
    if (info &&& 0x2000) == 0x2000,
      do:
        (info ||| @variation_selector_15) &&&
          bnot(@variation_selector_16 ||| @variation_selector_1_2_or_3),
      else: @variation_selector_15
  end

  defp unset_text_presentation(info), do: info &&& bnot(@variation_selector_15)

  defp set_vs1_2_3(info) do
    if (info &&& 0x2000) == 0x2000,
      do:
        (info ||| @variation_selector_1_2_or_3) &&&
          bnot(@variation_selector_15 ||| @variation_selector_16),
      else: @variation_selector_1_2_or_3
  end

  defp unset_vs1_2_3(info), do: info &&& bnot(@variation_selector_1_2_or_3)
  defp variation_1_2_or_3?(cp, :narrow), do: cp == 0xFE01
  defp variation_1_2_or_3?(cp, :wide), do: cp in [0xFE00, 0xFE02]
  defp regional_indicator?(cp), do: cp in 0x1F1E6..0x1F1FF
  defp emoji_modifier?(cp), do: cp in 0x1F3FB..0x1F3FF
  defp keycap_base?(cp), do: cp in ?0..?9 or cp in [?#, ?*]
  defp tag_letter?(cp), do: cp in 0xE0061..0xE007A
  defp tag_digit?(cp), do: cp in 0xE0030..0xE0039

  defp lam?(cp),
    do: cp == 0x644 or cp in 0x6B5..0x6B8 or cp in [0x76A, 0x8A6, 0x8C7]

  defp tifinagh_consonant?(cp), do: cp in 0x2D31..0x2D65 or cp == 0x2D6F
end
