use std::io::{self, Write};
use swarm_terminal_port::output::Painter;

fn frame(
    columns: u16,
    rows: u16,
    wide: bool,
    mode: u8,
    palette: &[&[u8]],
    cursor: Option<(u16, u16, u8, bool)>,
    glyphs: &[(u16, u16, &str)],
) -> Vec<u8> {
    let mut b = vec![1, 3];
    b.extend(9u64.to_be_bytes());
    b.extend(7u64.to_be_bytes());
    b.extend(columns.to_be_bytes());
    b.extend(rows.to_be_bytes());
    b.extend([wide as u8, mode]);
    b.extend((palette.len() as u16).to_be_bytes());
    if let Some((x, y, shape, visible)) = cursor {
        b.push(1);
        b.extend(x.to_be_bytes());
        b.extend(y.to_be_bytes());
        b.extend([shape, visible as u8]);
    } else {
        b.push(0);
    }
    b.extend((glyphs.len() as u32).to_be_bytes());
    for p in palette {
        b.extend_from_slice(p);
    }
    for (width, palette, text) in glyphs {
        b.extend(width.to_be_bytes());
        b.extend(palette.to_be_bytes());
        b.extend((text.len() as u32).to_be_bytes());
        b.extend(text.as_bytes());
    }
    b
}
fn plain(columns: u16, rows: u16, glyphs: &[(u16, u16, &str)]) -> Vec<u8> {
    frame(columns, rows, false, 0, &[&[0, 0, 0]], None, glyphs)
}
fn draw(p: &mut Painter, bytes: &[u8]) -> String {
    let mut out = Vec::new();
    let meta = p.draw(bytes, &mut out).unwrap();
    assert_eq!((meta.sequence, meta.revision), (9, 7));
    String::from_utf8(out).unwrap()
}

#[test]
fn absolute_positions_follow_declared_width_for_both_policies() {
    for wide in [false, true] {
        let body = frame(
            8,
            1,
            wide,
            0,
            &[&[0, 0, 0]],
            None,
            &[(1, 0, "·"), (3, 0, "👩‍💻"), (3, 0, "abc"), (1, 0, "z")],
        );
        let out = draw(&mut Painter::new(), &body);
        // pass70 B8: a glyph whose advance is uncertain (wide or non-ASCII)
        // reserves its columns and re-anchors; ASCII advances implicitly.
        for expected in [
            "\x1b[1;1H\x1b[K·",
            "\x1b[1;2H   \x1b[1;2H👩‍💻",
            "\x1b[1;5Habcz",
        ] {
            assert!(out.contains(expected), "{out:?} missing {expected:?}");
        }
        assert!(!out.contains("?1049"));
        assert!(!out.contains("?7"));
    }
}

#[test]
fn replacement_clears_complete_old_wide_row_before_any_new_glyph() {
    let mut p = Painter::new();
    draw(&mut p, &plain(4, 1, &[(3, 0, "界"), (1, 0, "!")]));
    let out = draw(
        &mut p,
        &frame(
            4,
            1,
            false,
            1,
            &[&[1, 7, 1, 4, 0]],
            None,
            &[(1, 0, "a"), (1, 0, "b"), (1, 0, "c"), (1, 0, "d")],
        ),
    );
    // pass70 B8: the old wide glyph's columns are erased in place (ECH), not
    // the whole line, before any new glyph; the new run needs one move.
    let erase = out
        .find("\x1b[1;1H\x1b[4X")
        .expect("erase the old wide glyph");
    assert!(erase < out.find("abcd").unwrap());
    assert!(out.contains("\x1b[44m"));
    assert!(!out.contains("\x1b[K"));
}

#[test]
fn identical_frame_produces_no_bytes_even_when_transport_metadata_changes() {
    let mut p = Painter::new();
    let mut b = plain(1, 1, &[(1, 0, "x")]);
    draw(&mut p, &b);
    b[9] = 10;
    b[17] = 8;
    let mut out = Vec::new();
    let meta = p.draw(&b, &mut out).unwrap();
    assert_eq!((meta.sequence, meta.revision), (10, 8));
    assert!(out.is_empty());
}

#[test]
fn only_changed_rows_repaint_and_resize_forces_full_frame() {
    let mut p = Painter::new();
    draw(&mut p, &plain(2, 2, &[(2, 0, "aa"), (2, 0, "bb")]));
    let out = draw(&mut p, &plain(2, 2, &[(2, 0, "aa"), (2, 0, "cc")]));
    assert!(!out.contains("\x1b[1;1H"));
    assert!(out.contains("\x1b[2;1Hcc"));
    let out = draw(&mut p, &plain(3, 1, &[(3, 0, "aaa")]));
    assert!(out.contains("\x1b[1;1H\x1b[Kaaa"));
}

#[test]
fn colors_modifiers_and_all_cursor_shapes_survive_projection() {
    let cases: &[(u8, &[u8], &[&str])] = &[
        (
            0,
            &[0, 0, 31],
            &["\x1b[1m", "\x1b[2m", "\x1b[3m", "\x1b[4m", "\x1b[7m"],
        ),
        (1, &[1, 9, 1, 4, 0], &["\x1b[91m", "\x1b[44m"]),
        (
            2,
            &[2, 200, 2, 123, 0],
            &["\x1b[38;5;200m", "\x1b[48;5;123m"],
        ),
        (
            3,
            &[3, 10, 20, 30, 3, 40, 50, 60, 0],
            &["\x1b[38;2;10;20;30m", "\x1b[48;2;40;50;60m"],
        ),
    ];
    for (mode, palette, expected) in cases {
        for (shape, escape) in [(0, "\x1b[2 q"), (1, "\x1b[6 q"), (2, "\x1b[4 q")] {
            let body = frame(
                2,
                1,
                false,
                *mode,
                &[*palette],
                Some((1, 0, shape, true)),
                &[(2, 0, "ab")],
            );
            let out = draw(&mut Painter::new(), &body);
            for s in *expected {
                assert!(out.contains(s), "{out:?} missing {s:?}");
            }
            assert!(out.contains(escape));
            // The cursor is placed and shown inside the synchronized update,
            // whose closing sequence is the last thing a painted frame writes.
            assert!(out.ends_with("\x1b[1;2H\x1b[?25h\x1b[?2026l"));
        }
    }
}

#[test]
fn cursor_only_change_avoids_grid_repaint_and_absent_hides_cursor() {
    let mut p = Painter::new();
    draw(
        &mut p,
        &frame(
            2,
            1,
            false,
            0,
            &[&[0, 0, 0]],
            Some((0, 0, 0, true)),
            &[(2, 0, "ab")],
        ),
    );
    let out = draw(
        &mut p,
        &frame(
            2,
            1,
            false,
            0,
            &[&[0, 0, 0]],
            Some((1, 0, 1, false)),
            &[(2, 0, "ab")],
        ),
    );
    assert!(!out.contains('a'));
    assert!(!out.contains("\x1b[K"));
    assert!(out.contains("\x1b[6 q"));
    assert!(out.contains("\x1b[?25l"));
    let out = draw(&mut p, &plain(2, 1, &[(2, 0, "ab")]));
    assert!(out.contains("\x1b[?25l"));
}

#[test]
fn invalid_frame_is_rejected_before_any_write_and_keeps_previous_state() {
    let mut p = Painter::new();
    let b = plain(1, 1, &[(1, 0, "x")]);
    draw(&mut p, &b);
    for end in 0..b.len() {
        let mut out = Vec::new();
        assert!(p.draw(&b[..end], &mut out).is_err());
        assert!(out.is_empty());
    }
    assert!(draw(&mut p, &b).is_empty());
}

struct Fail {
    remaining: usize,
    flush_fails: bool,
}
impl Write for Fail {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        if self.remaining == 0 {
            return Err(io::Error::other("injected"));
        }
        let n = b.len().min(self.remaining);
        self.remaining -= n;
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        if self.flush_fails {
            Err(io::Error::other("flush"))
        } else {
            Ok(())
        }
    }
}
#[test]
fn write_or_flush_failure_invalidates_previous_frame_for_retry() {
    for (remaining, flush_fails) in [(17, false), (usize::MAX, true)] {
        let mut p = Painter::new();
        let old = plain(2, 2, &[(2, 0, "aa"), (2, 0, "bb")]);
        draw(&mut p, &old);
        let new = plain(2, 2, &[(2, 0, "aa"), (2, 0, "cc")]);
        assert!(
            p.draw(
                &new,
                &mut Fail {
                    remaining,
                    flush_fails
                }
            )
            .is_err()
        );
        let out = draw(&mut p, &new);
        assert!(out.contains("\x1b[1;1H\x1b[Kaa"));
        assert!(out.contains("\x1b[2;1H\x1b[Kcc"));
    }
}

#[test]
fn maximum_grid_exceeds_u16_area_without_truncating_or_panicking() {
    let glyphs = vec![(500, 0, "x"); 200];
    let out = draw(&mut Painter::new(), &plain(500, 200, &glyphs));
    assert!(out.contains("\x1b[200;1Hx"));
}

#[test]
fn reserved_columns_receive_the_glyph_style_before_the_glyph() {
    let out = draw(
        &mut Painter::new(),
        &frame(
            4,
            1,
            false,
            1,
            &[&[1, 7, 1, 4, 0], &[1, 1, 1, 2, 16]],
            None,
            &[(2, 0, "a"), (2, 1, "b")],
        ),
    );
    // Each reserved pair is filled with its own style, then the glyph lands
    // on its first column; only the changed attributes are written.
    assert!(out.contains("\x1b[37m\x1b[44m  \x1b[1;1Ha"), "{out:?}");
    assert!(
        out.contains("\x1b[31m\x1b[42m\x1b[7m\x1b[1;3H  \x1b[1;3Hb"),
        "{out:?}"
    );
}

#[test]
fn ansi16_uses_basic_sgr_without_requiring_indexed_color_support() {
    let colors: Vec<Vec<u8>> = (0..16).map(|i| vec![1, i, 1, i, 0]).collect();
    let palette: Vec<&[u8]> = colors.iter().map(Vec::as_slice).collect();
    let glyphs: Vec<_> = (0..16).map(|i| (1, i, "x")).collect();
    let out = draw(
        &mut Painter::new(),
        &frame(16, 1, false, 1, &palette, None, &glyphs),
    );
    for i in 0..16 {
        let foreground = if i < 8 { 30 + i } else { 90 + i - 8 };
        assert!(out.contains(&format!("\x1b[{foreground}m")));
        assert!(out.contains(&format!("\x1b[{}m", foreground + 10)));
    }
    assert!(!out.contains(";5;"));
}

// ---------------------------------------------------------------- pass70 B8
// Output volume (ux M9): only changed cells are written, one cursor move per
// changed span, SGR only on a style change, and budgets for the two hot paths
// at 160x45: a keystroke under 2 KB and a streamed delta under 50 KB.

fn owned(glyphs: &[(u16, u16, String)]) -> Vec<(u16, u16, &str)> {
    glyphs
        .iter()
        .map(|(w, p, t)| (*w, *p, t.as_str()))
        .collect()
}

#[test]
fn a_changed_run_is_one_move_and_one_style() {
    let mut p = Painter::new();
    let row = |text: &str| -> Vec<(u16, u16, String)> {
        text.chars().map(|c| (1, 0, c.to_string())).collect()
    };
    draw(&mut p, &plain(20, 1, &owned(&row("aaaaaaaaaaaaaaaaaaaa"))));
    let out = draw(&mut p, &plain(20, 1, &owned(&row("aaaaaxxxaaaaaaaaaaaa"))));
    assert_eq!(out.matches('H').count(), 1, "{out:?}");
    assert!(out.contains("\x1b[1;6Hxxx"), "{out:?}");
    assert!(!out.contains("\x1b[K"), "{out:?}");
    assert!(!out.contains('a'), "{out:?}");
}

#[test]
fn equal_styles_share_one_sgr_and_a_dropped_modifier_resets() {
    let palette: &[&[u8]] = &[&[0, 0, 1], &[0, 0, 0]];
    let glyphs = [(1, 0, "a"), (1, 0, "b"), (1, 0, "c"), (1, 1, "d")];
    let out = draw(
        &mut Painter::new(),
        &frame(4, 1, false, 0, palette, None, &glyphs),
    );
    assert_eq!(out.matches("\x1b[1m").count(), 1, "{out:?}");
    // Bold cannot be switched off portably: reset, then the plain glyph.
    assert!(out.contains("\x1b[1mabc\x1b[0md"), "{out:?}");
}

#[test]
fn a_span_widens_to_whole_glyphs_of_both_frames() {
    let mut p = Painter::new();
    draw(
        &mut p,
        &plain(4, 1, &[(1, 0, "a"), (2, 0, "界"), (1, 0, "b")]),
    );
    let out = draw(
        &mut p,
        &plain(4, 1, &[(1, 0, "a"), (1, 0, "c"), (1, 0, "d"), (1, 0, "b")]),
    );
    // The old wide glyph covered columns 2-3: both are erased, then repainted.
    assert!(out.contains("\x1b[1;2H\x1b[2X"), "{out:?}");
    assert!(out.contains("cd"), "{out:?}");
    assert!(!out.contains('a') && !out.contains('b'), "{out:?}");
}

#[test]
fn a_new_wide_glyph_erases_its_reserved_columns_first() {
    let mut p = Painter::new();
    draw(
        &mut p,
        &plain(4, 1, &[(1, 0, "a"), (1, 0, "b"), (1, 0, "c"), (1, 0, "d")]),
    );
    let out = draw(
        &mut p,
        &plain(4, 1, &[(2, 0, "界"), (1, 0, "c"), (1, 0, "d")]),
    );
    assert!(out.contains("\x1b[1;1H  \x1b[1;1H界"), "{out:?}");
    assert!(!out.contains('c') && !out.contains('d'), "{out:?}");
}

/// A 160x45 workspace in truecolor: a styled header, a transcript beside an
/// agents panel split by a rule, a boxed composer and a status line. Every
/// glyph is one character, the projector's worst case.
struct Workspace {
    transcript: Vec<String>,
    draft: String,
    tokens: u32,
}

const PALETTE: [&[u8]; 6] = [
    &[0, 0, 0],                             // plain
    &[3, 250, 250, 250, 3, 30, 60, 110, 1], // header, bold
    &[3, 140, 140, 150, 0, 2],              // dim
    &[3, 90, 200, 220, 0, 0],               // accent
    &[3, 80, 80, 90, 0, 0],                 // rules
    &[3, 20, 20, 20, 3, 200, 200, 210, 16], // status, reversed
];

impl Workspace {
    fn new() -> Self {
        Self {
            transcript: (0..60)
                .map(|i| {
                    format!(
                        "line {i}: the agent read lib/swarm_code/engine.ex and found {i} callers"
                    )
                })
                .collect(),
            draft: String::new(),
            tokens: 5_200,
        }
    }

    fn frame(&self) -> Vec<u8> {
        let (columns, rows) = (160usize, 45usize);
        let mut glyphs: Vec<(u16, u16, String)> = Vec::with_capacity(columns * rows);
        let mut put = |segments: &[(&str, u16)]| {
            let mut used = 0;
            for (text, palette) in segments {
                for c in text.chars() {
                    if used < columns {
                        glyphs.push((1, *palette, c.to_string()));
                        used += 1;
                    }
                }
            }
            let pad = segments.last().map_or(0, |(_, p)| *p);
            for _ in used..columns {
                glyphs.push((1, pad, " ".to_string()));
            }
        };
        let header = format!(
            " SWARMCODE  ailogic · Build · deepseek-v4-pro · {:.1}k tokens · $0.02",
            self.tokens as f32 / 1000.0
        );
        put(&[(&header, 1)]);
        put(&[(" 3 Reply with exactly the word  ", 3), ("done · 00:04", 2)]);
        let rule_row = "─".repeat(columns);
        let body = 37;
        let first = self.transcript.len().saturating_sub(body);
        for y in 0..body {
            let text = self.transcript.get(first + y).map_or("", String::as_str);
            let left = format!("  {text:<113}");
            let panel = format!(
                " agent {y:>2} · running · {:>5} tok",
                self.tokens + y as u32
            );
            put(&[(&left[..115], 0), ("│", 4), (&panel, 2)]);
        }
        put(&[(&rule_row, 4)]);
        let draft = format!("│ {}", self.draft);
        put(&[(&draft, 0)]);
        put(&[("", 0)]);
        put(&[("", 0)]);
        put(&[(&rule_row, 4)]);
        put(&[(
            " Focus: composer  Enter Send  Esc Back out  Ctrl-P Palette",
            5,
        )]);
        let cursor = (2 + self.draft.chars().count() as u16, 40u16, 1u8, true);
        frame(160, 45, false, 3, &PALETTE, Some(cursor), &owned(&glyphs))
    }
}

fn bytes(p: &mut Painter, body: &[u8]) -> usize {
    let mut out = Vec::new();
    p.draw(body, &mut out).unwrap();
    out.len()
}

#[test]
fn a_keystroke_writes_under_two_kilobytes_at_160x45() {
    let mut p = Painter::new();
    let mut workspace = Workspace::new();
    let full = bytes(&mut p, &workspace.frame());
    let mut worst = 0;
    for c in "fix the failing test in engine_test.exs".chars() {
        workspace.draft.push(c);
        worst = worst.max(bytes(&mut p, &workspace.frame()));
    }
    assert!(
        worst < 2_048,
        "a keystroke wrote {worst} bytes (full frame {full})"
    );
    assert!(worst < 100, "one character and the cursor: {worst} bytes");
}

#[test]
fn a_streamed_delta_writes_under_fifty_kilobytes_at_160x45() {
    let mut p = Painter::new();
    let mut workspace = Workspace::new();
    let full = bytes(&mut p, &workspace.frame());
    let mut worst = 0;
    for i in 0..20 {
        // A new transcript line scrolls every row of the body, and the token
        // gauges in the header and the agents panel move with it.
        workspace.transcript.push(format!(
            "streamed {i}: the reply grows by one more line of text"
        ));
        workspace.tokens += 37;
        worst = worst.max(bytes(&mut p, &workspace.frame()));
    }
    assert!(
        worst < 51_200,
        "a streamed delta wrote {worst} bytes (full frame {full})"
    );
}
