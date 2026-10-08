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

// cli020 R2: the session's terminal writer waits for a slow terminal (a macOS
// pty holds about 1 KiB of unread output) and fails only when the terminal is
// gone; the bounded writer (restoration, mode transactions) keeps its 500 ms.
mod patience {
    use std::{
        io::{self, Write},
        os::fd::RawFd,
        thread,
        time::{Duration, Instant},
    };
    use swarm_terminal_port::tty::{FdWriter, nonblocking};

    fn pty() -> (RawFd, RawFd) {
        let (mut master, mut slave) = (0, 0);
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(opened, 0);
        let mut raw: libc::termios = unsafe { std::mem::zeroed() };
        assert_eq!(unsafe { libc::tcgetattr(slave, &mut raw) }, 0);
        unsafe { libc::cfmakeraw(&mut raw) };
        assert_eq!(unsafe { libc::tcsetattr(slave, libc::TCSANOW, &raw) }, 0);
        nonblocking(slave).unwrap();
        (master, slave)
    }

    fn drain(master: RawFd, total: usize) -> usize {
        let mut read = 0;
        let mut buffer = [0u8; 4096];
        while read < total {
            let n = unsafe { libc::read(master, buffer.as_mut_ptr().cast(), buffer.len()) };
            if n <= 0 {
                break;
            }
            read += n as usize;
        }
        read
    }

    fn close(fd: RawFd) {
        unsafe { libc::close(fd) };
    }

    #[test]
    fn a_patient_write_waits_out_a_reader_that_stalls_for_a_second() {
        let (master, slave) = pty();
        let payload = vec![b'x'; 16 * 1024];
        let reader = thread::spawn(move || {
            thread::sleep(Duration::from_millis(1_200));
            drain(master, 16 * 1024)
        });
        let start = Instant::now();
        FdWriter::patient(slave).write_all(&payload).unwrap();
        assert!(start.elapsed() >= Duration::from_millis(1_000));
        assert_eq!(reader.join().unwrap(), payload.len());
        close(slave);
        close(master);
    }

    #[test]
    fn a_bounded_write_still_gives_up_on_a_reader_that_stalls() {
        let (master, slave) = pty();
        let start = Instant::now();
        let error = FdWriter::new(slave, false)
            .write_all(&vec![b'x'; 16 * 1024])
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(3));
        close(slave);
        close(master);
    }

    #[test]
    fn a_patient_write_ends_when_the_terminal_is_gone() {
        let (master, slave) = pty();
        let closer = thread::spawn(move || {
            thread::sleep(Duration::from_millis(300));
            close(master);
        });
        let start = Instant::now();
        let result = FdWriter::patient(slave).write_all(&vec![b'x'; 16 * 1024]);
        assert!(result.is_err());
        assert!(start.elapsed() < Duration::from_secs(3));
        closer.join().unwrap();
        close(slave);
    }

    #[test]
    fn a_patient_write_ends_when_the_reader_of_a_pipe_is_gone() {
        let mut fds = [0; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        nonblocking(fds[1]).unwrap();
        let closer = thread::spawn(move || {
            thread::sleep(Duration::from_millis(300));
            close(fds[0]);
        });
        let result = FdWriter::patient(fds[1]).write_all(&vec![b'x'; 256 * 1024]);
        assert!(result.is_err());
        closer.join().unwrap();
        close(fds[1]);
    }
}
