use std::{
    cell::RefCell,
    io::{self, Write},
    rc::Rc,
};
use swarm_terminal_port::tty::BufferedWriter;
#[derive(Clone)]
struct Sink(Rc<RefCell<(Vec<u8>, usize, bool)>>);
impl Write for Sink {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let mut state = self.0.borrow_mut();
        state.1 += 1;
        if state.2 {
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        state.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
#[test]
fn explicit_flush_batches_small_writes_and_drop_discards() {
    let sink = Sink(Rc::new(RefCell::new((Vec::new(), 0, false))));
    let mut writer = BufferedWriter::new(sink.clone());
    for _ in 0..20_000 {
        writer.write_all(b"x").unwrap();
    }
    writer.flush().unwrap();
    assert_eq!(sink.0.borrow().0.len(), 20_000);
    assert_eq!(sink.0.borrow().1, 3);
    writer.write_all(b"must not flush on drop").unwrap();
    drop(writer);
    assert_eq!(sink.0.borrow().0.len(), 20_000);
}
#[test]
fn failed_flush_and_explicit_discard_never_replay_bytes() {
    let sink = Sink(Rc::new(RefCell::new((Vec::new(), 0, true))));
    let mut writer = BufferedWriter::new(sink.clone());
    writer.write_all(b"failed").unwrap();
    assert!(writer.flush().is_err());
    sink.0.borrow_mut().2 = false;
    writer.flush().unwrap();
    writer.write_all(b"stale").unwrap();
    writer.discard();
    writer.write_all(b"fresh").unwrap();
    writer.flush().unwrap();
    assert_eq!(sink.0.borrow().0, b"fresh");
}
