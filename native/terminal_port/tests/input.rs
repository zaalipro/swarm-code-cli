use swarm_terminal_port::input::*;
fn text(s: &str) -> Event {
    Event::Text {
        phase: Phase::Press,
        text: s.into(),
        modifiers: Modifiers::NONE,
    }
}
fn key(k: Key) -> Event {
    Event::Key {
        phase: Phase::Press,
        key: k,
        modifiers: Modifiers::NONE,
    }
}
fn feed(p: &mut InputParser, mut bytes: &[u8]) -> Vec<Event> {
    let mut out = Vec::new();
    let mut zero = false;
    while !bytes.is_empty() {
        let step = p.advance(bytes);
        assert!(step.consumed <= bytes.len());
        assert!(!(zero && step.consumed == 0), "parser stalled");
        zero = step.consumed == 0;
        assert!(step.consumed > 0 || step.event.is_some());
        bytes = &bytes[step.consumed..];
        if let Some(e) = step.event {
            out.push(e)
        }
    }
    out
}
#[test]
fn all_scalar_and_navigation_splits() {
    let bytes = "a界\x1b[A".as_bytes();
    for a in 0..=bytes.len() {
        for b in a..=bytes.len() {
            let mut p = InputParser::new();
            let mut events = feed(&mut p, &bytes[..a]);
            events.extend(feed(&mut p, &bytes[a..b]));
            events.extend(feed(&mut p, &bytes[b..]));
            assert_eq!(events, vec![text("a"), text("界"), key(Key::Up)]);
        }
    }
}
#[test]
fn exact_prefix_and_escape_timeout() {
    let mut p = InputParser::new();
    assert_eq!(
        p.advance(b"ab"),
        Step {
            consumed: 1,
            event: Some(text("a"))
        }
    );
    assert_eq!(
        p.advance(b"\x1b"),
        Step {
            consumed: 1,
            event: None
        }
    );
    assert_eq!(
        p.advance(b""),
        Step {
            consumed: 0,
            event: None
        }
    );
    assert_eq!(p.expire_escape(), Some(key(Key::Escape)));
    assert_eq!(p.expire_escape(), None);
    feed(&mut p, b"\xe7");
    assert_eq!(p.expire_escape(), None);
    assert_eq!(p.finish(), Some(Event::Rejected(Rejection::InvalidUtf8)));
    assert_eq!(p.finish(), None);
    feed(&mut p, b"\x1b[12");
    assert_eq!(p.expire_escape(), None);
    assert_eq!(p.finish(), None);
    feed(&mut p, b"\x1b");
    assert_eq!(p.finish(), Some(key(Key::Escape)));
}
#[test]
fn paste_bound_checked_during_capture_and_released() {
    let mut p = InputParser::new();
    feed(&mut p, b"\x1b[200~");
    for _ in 0..64 {
        assert!(feed(&mut p, &[b'p'; 4096]).is_empty());
        assert!(p.retained_capacity() <= MAX_PASTE_BYTES + MAX_SEQUENCE_BYTES + 10);
    }
    assert_eq!(p.retained_bytes(), MAX_PASTE_BYTES);
    assert_eq!(
        feed(&mut p, b"\x1b[201~"),
        vec![Event::Paste("p".repeat(MAX_PASTE_BYTES))]
    );
    assert!(p.retained_capacity() <= MAX_SEQUENCE_BYTES + 10);
    feed(&mut p, b"\x1b[200~");
    feed(&mut p, &vec![b'p'; MAX_PASTE_BYTES]);
    assert_eq!(
        feed(&mut p, b"q"),
        vec![Event::Rejected(Rejection::PasteTooLarge)]
    );
    assert!(p.retained_bytes() <= 6);
    assert!(p.retained_capacity() <= MAX_SEQUENCE_BYTES + 10);
    assert!(feed(&mut p, &vec![b'p'; MAX_PASTE_BYTES * 2]).is_empty());
    assert_eq!(feed(&mut p, b"\x1b[201~x"), vec![text("x")]);
}
#[test]
fn every_paste_split_and_false_terminator_is_exact() {
    let payload = "界\x1b[201x\x1b[20\x1b[200~\x1b\x1b[201";
    let bytes = format!("\x1b[200~{payload}\x1b[201~x").into_bytes();
    for split in 0..=bytes.len() {
        let mut p = InputParser::new();
        let mut out = feed(&mut p, &bytes[..split]);
        out.extend(feed(&mut p, &bytes[split..]));
        assert_eq!(out, vec![Event::Paste(payload.into()), text("x")]);
    }
}
#[test]
fn paste_invalid_utf8_and_eof_never_insert_partial_text() {
    let mut p = InputParser::new();
    assert_eq!(
        feed(&mut p, b"\x1b[200~\xff\x1b[201~x"),
        vec![Event::Rejected(Rejection::InvalidUtf8), text("x")]
    );
    feed(&mut p, b"\x1b[200~private");
    assert_eq!(p.finish(), None);
    assert_eq!(p.retained_bytes(), 0);
    assert_eq!(feed(&mut p, b"x"), vec![text("x")]);
}
#[test]
fn malformed_utf8_recovers_without_losing_valid_scalar() {
    for bad in [
        vec![0xc2],
        vec![0xe7, 0x95],
        vec![0xff],
        vec![0x80],
        vec![0xf4, 0x90, 0x80, 0x80],
        vec![0xed, 0xa0, 0x80],
        vec![0xc0, 0xaf],
    ] {
        let mut bytes = bad;
        bytes.extend("a界".as_bytes());
        for split in 0..=bytes.len() {
            let mut p = InputParser::new();
            let mut out = feed(&mut p, &bytes[..split]);
            out.extend(feed(&mut p, &bytes[split..]));
            assert_eq!(
                out,
                vec![
                    Event::Rejected(Rejection::InvalidUtf8),
                    text("a"),
                    text("界")
                ]
            );
        }
    }
}
#[test]
fn controls_alt_and_modified_keys() {
    let mut p = InputParser::new();
    assert_eq!(
        feed(&mut p, b"\r\n\t\x08\x7f\0"),
        vec![
            key(Key::Enter),
            key(Key::Enter),
            key(Key::Tab),
            key(Key::Backspace),
            key(Key::Backspace),
            key(Key::Null)
        ]
    );
    assert_eq!(
        feed(&mut p, b"\x01\x1az"),
        vec![
            Event::Text {
                phase: Phase::Press,
                text: "a".into(),
                modifiers: Modifiers::from_bits(2).unwrap()
            },
            Event::Text {
                phase: Phase::Press,
                text: "z".into(),
                modifiers: Modifiers::from_bits(2).unwrap()
            },
            text("z")
        ]
    );
    assert_eq!(
        feed(&mut p, "\x1b界".as_bytes()),
        vec![Event::Text {
            phase: Phase::Press,
            text: "界".into(),
            modifiers: Modifiers::from_bits(4).unwrap()
        }]
    );
    assert_eq!(
        feed(&mut p, b"\x1b[1;6A"),
        vec![Event::Key {
            phase: Phase::Press,
            key: Key::Up,
            modifiers: Modifiers::from_bits(3).unwrap()
        }]
    );
}
#[test]
fn standard_csi_ss3_and_function_keys() {
    let cases: [(&[u8], Key); 26] = [
        (b"\x1b[A", Key::Up),
        (b"\x1b[B", Key::Down),
        (b"\x1b[C", Key::Right),
        (b"\x1b[D", Key::Left),
        (b"\x1b[H", Key::Home),
        (b"\x1b[F", Key::End),
        (b"\x1b[2~", Key::Insert),
        (b"\x1b[3~", Key::Delete),
        (b"\x1b[5~", Key::PageUp),
        (b"\x1b[6~", Key::PageDown),
        (b"\x1b[Z", Key::BackTab),
        (b"\x1bOE", Key::KeypadBegin),
        (b"\x1bOP", Key::F1),
        (b"\x1bOQ", Key::F2),
        (b"\x1bOR", Key::F3),
        (b"\x1bOS", Key::F4),
        (b"\x1b[15~", Key::F5),
        (b"\x1b[17~", Key::F6),
        (b"\x1b[18~", Key::F7),
        (b"\x1b[19~", Key::F8),
        (b"\x1b[20~", Key::F9),
        (b"\x1b[21~", Key::F10),
        (b"\x1b[23~", Key::F11),
        (b"\x1b[24~", Key::F12),
        (b"\x1bOH", Key::Home),
        (b"\x1bOF", Key::End),
    ];
    for (bytes, k) in cases {
        for split in 0..=bytes.len() {
            let mut p = InputParser::new();
            let mut out = feed(&mut p, &bytes[..split]);
            out.extend(feed(&mut p, &bytes[split..]));
            assert_eq!(out, vec![key(k)]);
        }
    }
}
#[test]
fn csi_u_phases_and_closed_modifiers() {
    let mut p = InputParser::new();
    assert_eq!(
        feed(&mut p, b"\x1b[97;7:2u\x1b[57352;9:3u\x1b[13u"),
        vec![
            Event::Text {
                phase: Phase::Repeat,
                text: "a".into(),
                modifiers: Modifiers::from_bits(6).unwrap()
            },
            Event::Key {
                phase: Phase::Release,
                key: Key::Up,
                modifiers: Modifiers::from_bits(8).unwrap()
            },
            key(Key::Enter)
        ]
    );
    for seq in [
        b"\x1b[97;257u".as_slice(),
        b"\x1b[97;1:4u",
        b"\x1b[1114112u",
        b"\x1b[57399u",
        b"\x1b[97:65u",
        b"\x1b[97;1;98u",
    ] {
        assert!(feed(&mut p, seq).is_empty());
    }
    assert!(Modifiers::from_bits(64).is_none());
}
#[test]
fn control_string_floods_and_csi_overflow_remain_constant() {
    for start in [b"\x1b]".as_slice(), b"\x1bP", b"\x1b_", b"\x1b^"] {
        let mut p = InputParser::new();
        feed(&mut p, start);
        for _ in 0..20 {
            assert!(feed(&mut p, &[b's'; 4096]).is_empty());
            assert!(p.retained_bytes() <= 1);
            assert!(p.retained_capacity() <= MAX_SEQUENCE_BYTES + 10);
        }
        assert_eq!(feed(&mut p, b"\x1b\\x"), vec![text("x")]);
    }
    let mut p = InputParser::new();
    assert_eq!(feed(&mut p, b"\x1b]secret\x07x"), vec![text("x")]);
    feed(&mut p, b"\x1b[");
    feed(&mut p, &[b'1'; MAX_SEQUENCE_BYTES]);
    assert!(p.retained_bytes() <= MAX_SEQUENCE_BYTES);
    feed(&mut p, &[b'1'; 4096]);
    assert!(p.retained_bytes() <= MAX_SEQUENCE_BYTES);
    assert_eq!(feed(&mut p, b"Ax"), vec![text("x")]);
    assert_eq!(
        feed(&mut p, b"\x1b[I\x1b[O"),
        vec![Event::FocusGained, Event::FocusLost]
    );
}
#[test]
fn ordered_ten_thousand_keys_and_hundred_pastes() {
    let mut p = InputParser::new();
    let input = "a界\x1b[A".repeat(3334);
    let events = feed(&mut p, input.as_bytes());
    assert_eq!(events.len(), 10002);
    for chunk in events.chunks(3) {
        assert_eq!(chunk, [text("a"), text("界"), key(Key::Up)]);
    }
    for _ in 0..100 {
        let payload = "界".repeat(4096);
        let bytes = format!("\x1b[200~{payload}\x1b[201~");
        assert_eq!(feed(&mut p, bytes.as_bytes()), vec![Event::Paste(payload)]);
        assert!(p.retained_capacity() <= MAX_SEQUENCE_BYTES + 10);
    }
}
#[test]
fn debug_redacts_input_and_owned_payloads() {
    let mut p = InputParser::new();
    feed(&mut p, b"\x1b[200~private secret");
    assert!(!format!("{p:?}").contains("private"));
    assert!(!format!("{:?}", Event::Paste("private".into())).contains("private"));
    assert!(!format!("{:?}", text("private")).contains("private"));
    assert!(
        !format!(
            "{:?}",
            Step {
                consumed: 1,
                event: Some(text("private"))
            }
        )
        .contains("private")
    );
    assert_eq!(p.retained_bytes(), 14);
}

#[test]
fn exact_sequence_limit_counts_final_and_overflow_discards_until_final() {
    let mut p = InputParser::new();
    let accepted = format!("\x1b[{}1A", "0".repeat(MAX_SEQUENCE_BYTES - 2));
    assert_eq!(feed(&mut p, accepted.as_bytes()), vec![key(Key::Up)]);
    let rejected = format!("\x1b[{}1Ax", "0".repeat(MAX_SEQUENCE_BYTES - 1));
    assert_eq!(feed(&mut p, rejected.as_bytes()), vec![text("x")]);
    let ss3 = format!("\x1bO{}1A", "0".repeat(MAX_SEQUENCE_BYTES - 2));
    assert_eq!(feed(&mut p, ss3.as_bytes()), vec![key(Key::Up)]);
}
#[test]
fn all_modifiers_phases_and_scalar_boundaries() {
    for wire_bits in 0u8..64 {
        for (phase_code, phase) in [(1, Phase::Press), (2, Phase::Repeat), (3, Phase::Release)] {
            let mods = Modifiers::from_bits(
                (wire_bits & !6) | ((wire_bits & 2) << 1) | ((wire_bits & 4) >> 1),
            )
            .unwrap();
            let mut p = InputParser::new();
            let seq = format!("\x1b[30028;{}:{phase_code}u", u32::from(wire_bits) + 1);
            let mut out = Vec::new();
            for byte in seq.bytes() {
                out.extend(feed(&mut p, &[byte]));
            }
            assert_eq!(
                out,
                vec![Event::Text {
                    phase,
                    text: "界".into(),
                    modifiers: mods
                }]
            );
            for (bit, modifier) in [
                Modifier::Shift,
                Modifier::Control,
                Modifier::Alt,
                Modifier::Super,
                Modifier::Hyper,
                Modifier::Meta,
            ]
            .into_iter()
            .enumerate()
            {
                assert_eq!(mods.contains(modifier), mods.bits() & (1 << bit) != 0);
            }
        }
    }
    for scalar in [
        '\u{80}',
        '\u{7ff}',
        '\u{800}',
        '\u{d7ff}',
        '\u{e000}',
        '\u{ffff}',
        '\u{10000}',
        '\u{10ffff}',
        '\u{301}',
    ] {
        let mut buf = [0u8; 4];
        let bytes = scalar.encode_utf8(&mut buf).as_bytes();
        for split in 0..=bytes.len() {
            let mut p = InputParser::new();
            let mut out = feed(&mut p, &bytes[..split]);
            out.extend(feed(&mut p, &bytes[split..]));
            assert_eq!(out, vec![text(&scalar.to_string())]);
        }
    }
}
#[test]
fn bytewise_control_strings_ignore_embedded_sequences_and_bel_rules() {
    for (start, end) in [
        ("\x1b]", "\x07"),
        ("\x1b]", "\x1b\\"),
        ("\x1bP", "\x1b\\"),
        ("\x1b_", "\x1b\\"),
        ("\x1b^", "\x1b\\"),
    ] {
        let payload = if start == "\x1b]" {
            "secret\x1b[A\x1b\x1b"
        } else {
            "secret\x07\x1b[A\x1b\x1b"
        };
        let bytes = format!("{start}{payload}{end}x");
        let mut p = InputParser::new();
        let mut out = Vec::new();
        for byte in bytes.bytes() {
            out.extend(feed(&mut p, &[byte]));
            assert!(p.retained_bytes() <= 1);
        }
        assert_eq!(out, vec![text("x")]);
    }
}
#[test]
fn overflow_on_false_marker_has_one_rejection_and_no_truncated_paste() {
    for margin in 0..6 {
        let mut p = InputParser::new();
        feed(&mut p, b"\x1b[200~");
        feed(&mut p, &vec![b'p'; MAX_PASTE_BYTES - margin]);
        let out = feed(&mut p, b"\x1b[201x\x1b[201~x");
        assert_eq!(
            out,
            vec![Event::Rejected(Rejection::PasteTooLarge), text("x")]
        );
        assert!(p.retained_capacity() <= MAX_SEQUENCE_BYTES);
    }
}
#[test]
fn zero_consumed_rejection_resets_state_before_reprocessing_scalar() {
    let mut p = InputParser::new();
    assert_eq!(
        p.advance(b"\xe7\x95"),
        Step {
            consumed: 2,
            event: None
        }
    );
    assert_eq!(
        p.advance(b"x"),
        Step {
            consumed: 0,
            event: Some(Event::Rejected(Rejection::InvalidUtf8))
        }
    );
    assert_eq!(
        p.advance(b"x"),
        Step {
            consumed: 1,
            event: Some(text("x"))
        }
    );
}
#[test]
fn alt_space_is_a_text_key() {
    let mut p = InputParser::new();
    assert_eq!(
        feed(&mut p, b"\x1b x"),
        vec![
            Event::Text {
                phase: Phase::Press,
                text: " ".into(),
                modifiers: Modifiers::from_bits(4).unwrap()
            },
            text("x")
        ]
    );
}

#[test]
fn arbitrary_byte_streams_are_packetization_invariant_and_bounded() {
    // Deterministic hostile input exercises transitions, not a mock or RNG dependency.
    let mut seed = 0x5eed_u64;
    for _ in 0..100 {
        let mut bytes = Vec::with_capacity(1024);
        for _ in 0..1024 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            bytes.push((seed >> 32) as u8);
        }
        let mut whole = InputParser::new();
        let mut expected = feed(&mut whole, &bytes);
        expected.extend(whole.finish());
        let mut split = InputParser::new();
        let mut actual = Vec::new();
        for byte in bytes {
            actual.extend(feed(&mut split, &[byte]));
            assert!(split.retained_bytes() <= MAX_PASTE_BYTES + 6);
            assert!(split.retained_capacity() <= MAX_PASTE_BYTES + MAX_SEQUENCE_BYTES);
        }
        actual.extend(split.finish());
        assert_eq!(actual, expected);
        assert_eq!(split.retained_bytes(), 0);
    }
}

#[test]
fn sos_control_strings_discard_at_every_split_and_only_st_terminates() {
    let bytes = b"\x1bXsecret\x07\x1b[A\x1b\x1b\\x";
    for split in 0..=bytes.len() {
        let mut parser = InputParser::new();
        let mut events = feed(&mut parser, &bytes[..split]);
        events.extend(feed(&mut parser, &bytes[split..]));
        assert_eq!(events, vec![text("x")]);
        assert_eq!(parser.retained_bytes(), 0);
    }
    let mut parser = InputParser::new();
    assert!(feed(&mut parser, b"\x1bX").is_empty());
    for _ in 0..100 {
        assert!(feed(&mut parser, &[b's'; 4096]).is_empty());
        assert!(feed(&mut parser, b"\x07\x1b[A").is_empty());
        assert!(parser.retained_bytes() <= 1);
        assert!(parser.retained_capacity() <= MAX_SEQUENCE_BYTES);
    }
    assert_eq!(parser.expire_escape(), None);
    assert!(feed(&mut parser, b"\x1b").is_empty());
    assert_eq!(parser.expire_escape(), None);
    assert_eq!(feed(&mut parser, b"\\x"), vec![text("x")]);
    assert!(feed(&mut parser, b"\x1bXunterminated").is_empty());
    assert_eq!(parser.finish(), None);
    assert_eq!(feed(&mut parser, b"x"), vec![text("x")]);
}
