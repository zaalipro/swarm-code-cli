use swarm_terminal_port::frame::{Color, DrawFrame, FrameError};

fn sample() -> Vec<u8> {
    let mut b = vec![1, 3];
    b.extend_from_slice(&9u64.to_be_bytes());
    b.extend_from_slice(&7u64.to_be_bytes());
    b.extend_from_slice(&3u16.to_be_bytes());
    b.extend_from_slice(&1u16.to_be_bytes());
    b.extend_from_slice(&[0, 3, 0, 2, 1, 0, 2, 0, 0, 1, 1]);
    b.extend_from_slice(&2u32.to_be_bytes());
    b.extend_from_slice(&[3, 255, 128, 0, 0, 1, 2, 200, 1, 4, 16]);
    b.extend_from_slice(&[0, 2, 0, 0, 0, 0, 0, 3]);
    b.extend_from_slice("界".as_bytes());
    b.extend_from_slice(&[0, 1, 0, 1, 0, 0, 0, 1, b'x']);
    b
}

#[test]
fn exact_cross_language_fixture_carries_declared_cells() {
    let bytes = sample();
    let f = DrawFrame::decode(&bytes).unwrap();
    assert_eq!((f.sequence, f.revision, f.columns, f.rows), (9, 7, 3, 1));
    assert_eq!(f.glyphs.len(), 2);
    assert_eq!(f.glyphs[0].text, "界");
    assert_eq!((f.glyphs[0].x, f.glyphs[0].y, f.glyphs[0].width), (0, 0, 2));
    assert_eq!((f.glyphs[1].x, f.glyphs[1].palette), (2, 1));
    assert_eq!(f.palette[0].foreground, Color::Rgb(255, 128, 0));
    assert_eq!(f.palette[1].background, Color::Ansi(4));
    assert_eq!(f.cursor.unwrap().x, 2);
    assert!(!format!("{f:?}").contains('界'));
}

#[test]
fn every_truncation_rejects_and_trailing_bytes_do_not_form_another_frame() {
    let bytes = sample();
    for end in 0..bytes.len() {
        assert!(DrawFrame::decode(&bytes[..end]).is_err(), "end {end}");
    }
    let mut extra = bytes;
    extra.push(0);
    assert_eq!(DrawFrame::decode(&extra).unwrap_err(), FrameError::Invalid);
}

#[test]
fn counts_geometry_enums_colors_and_glyphs_are_checked_before_use() {
    // Offsets follow terminal-port-wire-v1.md independently of the decoder.
    for (offset, value) in [
        (0, 2),
        (1, 99),
        (18, 2),
        (20, 1),
        (22, 2),
        (23, 4),
        (24, 17),
        (26, 2),
        (28, 3),
        (31, 3),
        (32, 2),
        (36, 0),
        (37, 4),
        (42, 32),
        (47, 32),
        (48, 4),
        (50, 2),
        (55, 0),
        (55, 0xff),
    ] {
        let mut b = sample();
        b[offset] = value;
        assert!(
            DrawFrame::decode(&b).is_err(),
            "offset {offset} value {value}"
        );
    }
    let mut mono = sample();
    mono[23] = 0;
    assert!(DrawFrame::decode(&mono).is_err());
    let mut wide = sample();
    wide[22] = 1;
    assert!(DrawFrame::decode(&wide).is_ok());
    let mut control = sample();
    let last = control.len() - 1;
    control[last] = 27;
    assert!(DrawFrame::decode(&control).is_err());
}

#[test]
fn body_capacity_is_rejected_before_reading_any_fields() {
    let bytes = vec![0u8; 33_554_433];
    assert_eq!(DrawFrame::decode(&bytes).unwrap_err(), FrameError::Capacity);
}
