//! cli020 lane D: kitty keyboard detection (D2), Notify (D3), alternate
//! scroll bursts (D5) and Redraw (D11).
use swarm_terminal_port::input::*;
use swarm_terminal_port::protocol::{
    Command, FLAGS, NotifyKind, ProtocolError, READY_ENHANCED_KEYS, decode_command, encode_event,
    notify_bytes, ready,
};

fn feed(p: &mut InputParser, mut bytes: &[u8]) -> Vec<Event> {
    let mut out = Vec::new();
    while !bytes.is_empty() {
        let step = p.advance(bytes);
        assert!(step.consumed > 0 || step.event.is_some(), "parser stalled");
        bytes = &bytes[step.consumed..];
        if let Some(e) = step.event {
            out.push(e)
        }
    }
    out
}

fn mods(bits: u8) -> Modifiers {
    Modifiers::from_bits(bits).unwrap()
}

// ------------------------------------------------------------------ D2

#[test]
fn the_probe_answers_are_never_keys() {
    let mut p = InputParser::new();
    assert_eq!(feed(&mut p, b"\x1b[?1u"), vec![]);
    assert_eq!(feed(&mut p, b"\x1b[?62;22c"), vec![]);
    assert!(!p.pending_escape());
}

#[test]
fn enhanced_keys_decode_to_the_legacy_events() {
    let mut p = InputParser::new();
    // Shift-Enter.
    assert_eq!(
        feed(&mut p, b"\x1b[13;2u"),
        vec![Event::Key {
            phase: Phase::Press,
            key: Key::Enter,
            modifiers: mods(1)
        }]
    );
    // Esc at once: a complete CSI u, no 40 ms wait.
    assert_eq!(
        feed(&mut p, b"\x1b[27u"),
        vec![Event::Key {
            phase: Phase::Press,
            key: Key::Escape,
            modifiers: Modifiers::NONE
        }]
    );
    assert!(!p.pending_escape());
    // Ctrl-C is the same event as the legacy byte 3.
    let legacy = feed(&mut InputParser::new(), b"\x03");
    assert_eq!(feed(&mut p, b"\x1b[99;5u"), legacy);
    // Alt-b is the same event as the legacy ESC b.
    let legacy = feed(&mut InputParser::new(), b"\x1bb");
    assert_eq!(feed(&mut p, b"\x1b[98;3u"), legacy);
}

#[test]
fn probe_replies_are_taken_out_and_typeahead_stays_in_order() {
    let mut bytes = *b"ab\x1b[?1uc\x1b[?62;22cd";
    let (len, found) = take_probe_replies(&mut bytes);
    assert_eq!(&bytes[..len], b"abcd");
    assert_eq!(
        found,
        ProbeReplies {
            kitty_flags: Some(1),
            attributes: true
        }
    );

    // A terminal without the protocol answers only DA1.
    let mut bytes = *b"\x1b[?6c";
    let (len, found) = take_probe_replies(&mut bytes);
    assert_eq!(len, 0);
    assert_eq!(
        found,
        ProbeReplies {
            kitty_flags: None,
            attributes: true
        }
    );

    // A split answer waits for the rest.
    let mut bytes = *b"x\x1b[?6";
    let (len, found) = take_probe_replies(&mut bytes);
    assert_eq!(len, 5);
    assert_eq!(found, ProbeReplies::default());
}

#[test]
fn ready_carries_enhanced_keys_and_init_still_rejects_it() {
    let packet = ready(1, 80, 24, 1 | READY_ENHANCED_KEYS).unwrap();
    assert_eq!(*packet.last().unwrap(), 129);
    assert!(ready(1, 80, 24, 1 | 8).is_err());
    let mut init = vec![1, 1];
    init.extend_from_slice(&1u64.to_be_bytes());
    init.push(FLAGS | READY_ENHANCED_KEYS);
    assert_eq!(decode_command(&init), Err(ProtocolError));
}

// ------------------------------------------------------------------ D3

fn notify(kind: u8, text: &[u8]) -> Vec<u8> {
    let mut b = vec![1, 9];
    b.extend_from_slice(&3u64.to_be_bytes());
    b.extend_from_slice(&4u64.to_be_bytes());
    b.push(kind);
    b.extend_from_slice(&(text.len() as u16).to_be_bytes());
    b.extend_from_slice(text);
    b
}

#[test]
fn notify_decodes_its_three_kinds() {
    let body = notify(2, "ncode · demo".as_bytes());
    assert_eq!(
        decode_command(&body).unwrap(),
        Command::Notify {
            generation: 3,
            token: 4,
            kind: NotifyKind::Title,
            text: "ncode · demo"
        }
    );
    assert_eq!(decode_command(&body).unwrap().operation(), "notify");
    assert!(matches!(
        decode_command(&notify(0, b"")).unwrap(),
        Command::Notify {
            kind: NotifyKind::Bell,
            ..
        }
    ));
    assert!(matches!(
        decode_command(&notify(1, b"ncode: demo needs you (approval)")).unwrap(),
        Command::Notify {
            kind: NotifyKind::Notification,
            ..
        }
    ));
}

#[test]
fn notify_refuses_controls_digits_lengths_and_kinds() {
    for text in [
        &b"a\x1bb"[..],
        b"a\x07",
        b"\n",
        "\u{9b}x".as_bytes(),
        b"a\x7f",
    ] {
        assert_eq!(decode_command(&notify(2, text)), Err(ProtocolError));
    }
    // ConEmu's OSC 9;<n> progress prefix.
    assert_eq!(decode_command(&notify(1, b"9;4")), Err(ProtocolError));
    assert!(decode_command(&notify(2, b"9 lives")).is_ok());
    assert_eq!(decode_command(&notify(3, b"x")), Err(ProtocolError));
    assert!(decode_command(&notify(2, &[b'a'; 512])).is_ok());
    assert_eq!(decode_command(&notify(2, &[b'a'; 513])), Err(ProtocolError));
    let mut trailing = notify(2, b"ab");
    trailing.push(b'c');
    assert_eq!(decode_command(&trailing), Err(ProtocolError));
    let mut short = notify(2, b"ab");
    short.pop();
    assert_eq!(decode_command(&short), Err(ProtocolError));
}

#[test]
fn notify_writes_the_exact_bytes() {
    assert_eq!(notify_bytes(NotifyKind::Bell, ""), b"\x07");
    assert_eq!(
        notify_bytes(NotifyKind::Notification, "ncode: p finished"),
        b"\x1b]9;ncode: p finished\x07"
    );
    assert_eq!(
        notify_bytes(NotifyKind::Title, "ncode · p"),
        "\x1b]2;ncode · p\x07".as_bytes()
    );
}

// ------------------------------------------------------------------ D5

#[test]
fn an_arrow_burst_in_one_read_is_the_wheel() {
    assert_eq!(arrow_burst(b"\x1b[A\x1b[A\x1b[A"), Some((true, 3)));
    assert_eq!(arrow_burst(b"\x1bOB\x1bOB"), Some((false, 2)));
    assert_eq!(arrow_burst(b"\x1b[A"), None);
    assert_eq!(arrow_burst(b"\x1b[A\x1b[B"), None);
    assert_eq!(arrow_burst(b"\x1b[A\x1b[Ax"), None);
    assert_eq!(arrow_burst(b"\x1b[C\x1b[C"), None);
    assert_eq!(arrow_burst(&b"\x1b[B".repeat(40)), Some((false, 32)));
}

#[test]
fn scroll_encodes_as_input_kind_seven() {
    let packet = encode_event(1, 2, &Event::Scroll { up: true, count: 3 }).unwrap();
    assert_eq!(&packet[packet.len() - 3..], &[7, 1, 3]);
    assert_eq!(
        u32::from_be_bytes(packet[..4].try_into().unwrap()) as usize,
        packet.len() - 4
    );
    assert!(
        encode_event(
            1,
            2,
            &Event::Scroll {
                up: false,
                count: 0
            }
        )
        .is_err()
    );
    assert!(
        encode_event(
            1,
            2,
            &Event::Scroll {
                up: false,
                count: 33
            }
        )
        .is_err()
    );
}

// ------------------------------------------------------------------ D11

#[test]
fn redraw_is_a_fixed_control() {
    let mut b = vec![1, 10];
    b.extend_from_slice(&7u64.to_be_bytes());
    b.extend_from_slice(&9u64.to_be_bytes());
    let command = decode_command(&b).unwrap();
    assert_eq!(
        command,
        Command::Redraw {
            generation: 7,
            token: 9
        }
    );
    assert_eq!(command.operation(), "redraw");
    b.push(0);
    assert_eq!(decode_command(&b), Err(ProtocolError));
}
