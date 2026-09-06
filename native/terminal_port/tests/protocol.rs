use swarm_terminal_port::input::{Event, Key, Modifiers, Phase, Rejection};
use swarm_terminal_port::protocol::{
    Command, ProtocolError, decode_command, encode_event, failure, painted, ready, resize,
    restored, resume_needed, skipped,
};
fn packet(body: &[u8]) -> Vec<u8> {
    let mut p = (body.len() as u32).to_be_bytes().to_vec();
    p.extend_from_slice(body);
    p
}
#[test]
fn fixed_commands_are_exact_and_closed() {
    let mut b = vec![1, 1];
    b.extend_from_slice(&7u64.to_be_bytes());
    b.push(7);
    assert_eq!(
        decode_command(&b).unwrap(),
        Command::Init {
            generation: 7,
            flags: 7
        }
    );
    for (tag, operation) in [
        (2, "credit"),
        (4, "shutdown"),
        (5, "suspend"),
        (6, "resume"),
    ] {
        let mut b = vec![1, tag];
        b.extend_from_slice(&7u64.to_be_bytes());
        b.extend_from_slice(&9u64.to_be_bytes());
        let c = decode_command(&b).unwrap();
        assert_eq!(c.generation(), Some(7));
        assert_eq!(c.token(), Some(9));
        assert_eq!(c.operation(), operation);
        b.push(0);
        assert_eq!(decode_command(&b), Err(ProtocolError));
    }
    for b in [vec![1, 99], vec![2, 1], vec![1, 1, 0], {
        let mut b = b.clone();
        b[10] = 8;
        b
    }] {
        assert!(decode_command(&b).is_err());
    }
}
#[test]
fn response_bytes_match_elixir_fixtures() {
    let mut base = vec![1, 17];
    base.extend_from_slice(&7u64.to_be_bytes());
    base.extend_from_slice(&9u64.to_be_bytes());
    for (event, payload) in [
        (
            Event::Key {
                phase: Phase::Repeat,
                key: Key::Up,
                modifiers: Modifiers::from_bits(63).unwrap(),
            },
            vec![0, 1, 4, 63],
        ),
        (
            Event::Key {
                phase: Phase::Press,
                key: Key::F12,
                modifiers: Modifiers::NONE,
            },
            vec![0, 0, 43, 0],
        ),
        (
            Event::Text {
                phase: Phase::Release,
                text: "界".into(),
                modifiers: Modifiers::from_bits(4).unwrap(),
            },
            vec![1, 2, 4, 0, 3, 0xe7, 0x95, 0x8c],
        ),
        (
            Event::Paste("\x1b[2J\n".into()),
            vec![2, 0, 0, 0, 5, 27, 91, 50, 74, 10],
        ),
        (Event::Rejected(Rejection::PasteTooLarge), vec![3, 2]),
        (Event::FocusGained, vec![4]),
        (Event::FocusLost, vec![5]),
    ] {
        let mut b = base.clone();
        b.extend_from_slice(&payload);
        assert_eq!(encode_event(7, 9, &event).unwrap(), packet(&b));
    }
    let mut b = vec![1, 16];
    b.extend_from_slice(&7u64.to_be_bytes());
    b.extend_from_slice(&[0, 120, 0, 40, 7]);
    assert_eq!(ready(7, 120, 40, 7).unwrap(), packet(&b));
    let mut b = vec![1, 18];
    b.extend_from_slice(&7u64.to_be_bytes());
    b.extend_from_slice(&9u64.to_be_bytes());
    b.extend_from_slice(&11u64.to_be_bytes());
    assert_eq!(painted(7, 9, 11), packet(&b));
    b[1] = 23;
    assert_eq!(skipped(7, 9, 11), packet(&b));
    let mut b = vec![1, 19];
    b.extend_from_slice(&7u64.to_be_bytes());
    b.extend_from_slice(&9u64.to_be_bytes());
    b.push(1);
    assert_eq!(restored(7, 9, true), packet(&b));
    assert_eq!(resume_needed(7), packet(&[1, 24, 0, 0, 0, 0, 0, 0, 0, 7]));
    assert!(ready(7, 0, 40, 7).is_err());
    assert!(ready(7, 120, 40, 8).is_err());
    assert!(resize(7, 9, 0, 40).is_err());
    assert!(failure(7, 0).is_err());
    assert!(failure(7, 7).is_err());
}
#[test]
fn event_payload_bounds_precede_output_allocation() {
    assert!(encode_event(0, 1, &Event::Paste("x".repeat(262144))).is_ok());
    assert_eq!(
        encode_event(0, 1, &Event::Paste("x".repeat(262145))),
        Err(ProtocolError)
    );
    let text = |n| Event::Text {
        phase: Phase::Press,
        text: "x".repeat(n),
        modifiers: Modifiers::NONE,
    };
    assert!(encode_event(0, 1, &text(4096)).is_ok());
    assert_eq!(encode_event(0, 1, &text(4097)), Err(ProtocolError));
    assert_eq!(encode_event(0, 1, &text(0)), Err(ProtocolError));
}

#[test]
fn every_control_truncation_and_trailing_byte_rejects() {
    for tag in [1, 2, 4, 5, 6] {
        let mut body = vec![1, tag];
        body.extend_from_slice(&u64::MAX.to_be_bytes());
        if tag == 1 {
            body.push(7);
        } else {
            body.extend_from_slice(&u64::MAX.to_be_bytes());
        }
        for end in 0..body.len() {
            assert_eq!(decode_command(&body[..end]), Err(ProtocolError));
        }
        assert_eq!(decode_command(&body).unwrap().generation(), Some(u64::MAX));
        body.push(0);
        assert_eq!(decode_command(&body), Err(ProtocolError));
    }
}

#[test]
fn draws_are_validated_borrowed_and_redacted() {
    let mut body = vec![1, 3];
    body.extend_from_slice(&9u64.to_be_bytes());
    body.extend_from_slice(&7u64.to_be_bytes());
    body.extend_from_slice(&[0, 1, 0, 1, 0, 0, 0, 1, 0]); // Grid, policies, palette, no cursor.
    body.extend_from_slice(&1u32.to_be_bytes());
    body.extend_from_slice(&[0, 0, 0]); // Default palette.
    body.extend_from_slice(&[0, 1, 0, 0, 0, 0, 0, 6]);
    body.extend_from_slice(b"secret");
    let command = decode_command(&body).unwrap();
    assert_eq!(command.generation(), None);
    assert_eq!(command.token(), None);
    assert_eq!(command.operation(), "draw");
    assert!(!format!("{command:?}").contains("secret"));
    match command {
        Command::Draw {
            sequence,
            body: borrowed,
        } => {
            assert_eq!(sequence, 9);
            assert_eq!(borrowed.as_ptr(), body.as_ptr());
        }
        _ => panic!("expected draw"),
    }
    for end in 0..body.len() {
        assert_eq!(decode_command(&body[..end]), Err(ProtocolError));
    }
    body.push(0);
    assert_eq!(decode_command(&body), Err(ProtocolError));
    assert_eq!(
        decode_command(&vec![
            0;
            swarm_terminal_port::protocol::MAX_COMMAND_BYTES + 1
        ]),
        Err(ProtocolError)
    );
}

#[test]
fn every_key_and_rejection_has_the_exact_closed_wire_code() {
    let keys = [
        Key::Backspace,
        Key::Enter,
        Key::Left,
        Key::Right,
        Key::Up,
        Key::Down,
        Key::Home,
        Key::End,
        Key::PageUp,
        Key::PageDown,
        Key::Tab,
        Key::BackTab,
        Key::Delete,
        Key::Insert,
        Key::Escape,
        Key::Null,
        Key::CapsLock,
        Key::ScrollLock,
        Key::NumLock,
        Key::PrintScreen,
        Key::Pause,
        Key::Menu,
        Key::KeypadBegin,
        Key::F1,
        Key::F2,
        Key::F3,
        Key::F4,
        Key::F5,
        Key::F6,
        Key::F7,
        Key::F8,
        Key::F9,
        Key::F10,
        Key::F11,
        Key::F12,
    ];
    for (index, key) in keys.into_iter().enumerate() {
        let expected = if index < 23 {
            index as u8
        } else {
            index as u8 + 9
        };
        for (phase_code, phase) in [Phase::Press, Phase::Repeat, Phase::Release]
            .into_iter()
            .enumerate()
        {
            for bits in 0..64 {
                let encoded = encode_event(
                    1,
                    2,
                    &Event::Key {
                        phase,
                        key,
                        modifiers: Modifiers::from_bits(bits).unwrap(),
                    },
                )
                .unwrap();
                assert_eq!(&encoded[22..], &[0, phase_code as u8, expected, bits]);
                assert_eq!(&encoded[..4], &22u32.to_be_bytes());
            }
        }
    }
    for (code, reason) in [
        Rejection::InvalidUtf8,
        Rejection::TextFragmentTooLarge,
        Rejection::PasteTooLarge,
    ]
    .into_iter()
    .enumerate()
    {
        let encoded = encode_event(1, 2, &Event::Rejected(reason)).unwrap();
        assert_eq!(&encoded[22..], &[3, code as u8]);
    }
}

#[test]
fn fixed_response_sizes_and_largest_paste_packet_are_exact() {
    for reason in 1..=6 {
        let encoded = failure(u64::MAX, reason).unwrap();
        assert_eq!(encoded.len(), 15);
        assert_eq!(&encoded[..6], &[0, 0, 0, 11, 1, 21]);
        assert_eq!(encoded[14], reason);
    }
    for suspended in [false, true] {
        let encoded = restored(7, 9, suspended);
        assert_eq!(encoded.len(), 23);
        assert_eq!(encoded[22], u8::from(suspended));
    }
    let encoded = resize(7, 9, u16::MAX, u16::MAX).unwrap();
    assert_eq!(encoded.len(), 26);
    assert_eq!(&encoded[22..], &[255, 255, 255, 255]);
    assert!(ready(7, u16::MAX, u16::MAX, 0).is_ok());
    let encoded = encode_event(7, 9, &Event::Paste("p".repeat(262144))).unwrap();
    assert_eq!(
        encoded.len(),
        swarm_terminal_port::protocol::MAX_RESPONSE_BYTES + 4
    );
    assert_eq!(&encoded[..4], &262167u32.to_be_bytes());
    assert_eq!(&encoded[23..27], &262144u32.to_be_bytes());
    assert_eq!(
        encode_event(7, 9, &Event::Paste(String::new()))
            .unwrap()
            .len(),
        27
    );
}
