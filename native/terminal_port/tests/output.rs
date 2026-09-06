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
        for expected in ["\x1b[1;1H·", "\x1b[1;2H👩‍💻", "\x1b[1;5Habc", "\x1b[1;8Hz"] {
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
    let clear = out.find("\x1b[K").expect("clear old complete row");
    assert!(clear < out.find("\x1b[1;1Ha").unwrap());
    assert!(out.contains("\x1b[44m"));
    assert!(out.contains("\x1b[1;4Hd"));
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
    assert!(out.contains("\x1b[1;1Haaa"));
    assert!(out.contains("\x1b[K"));
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
            assert!(out.ends_with("\x1b[1;2H\x1b[?25h"));
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
        assert!(out.contains("\x1b[1;1Haa"));
        assert!(out.contains("\x1b[2;1Hcc"));
    }
}

#[test]
fn maximum_grid_exceeds_u16_area_without_truncating_or_panicking() {
    let glyphs = vec![(500, 0, "x"); 200];
    let out = draw(&mut Painter::new(), &plain(500, 200, &glyphs));
    assert!(out.contains("\x1b[200;1Hx"));
}

#[test]
fn reserved_columns_receive_each_desired_background_before_glyphs() {
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
    let first_fill = out.find("\x1b[1;1H  ").unwrap();
    let second_fill = out.find("\x1b[1;3H  ").unwrap();
    let first_glyph = out.find("\x1b[1;1Ha").unwrap();
    assert!(first_fill < second_fill && second_fill < first_glyph);
    let style = &out[first_fill..second_fill];
    assert!(style.contains("\x1b[42m"));
    assert!(style.contains("\x1b[7m"));
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
