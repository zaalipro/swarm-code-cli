//! Diagnostic only: validate exactly one framed draw on stdin without a terminal.
use std::io::{self, Read};
use swarm_terminal_port::frame::{DrawFrame, MAX_FRAME_BYTES};

fn main() {
    if run().is_err() {
        eprintln!("invalid draw frame");
        std::process::exit(1);
    }
}
fn run() -> Result<(), ()> {
    let mut input = io::stdin().lock();
    let mut header = [0u8; 4];
    input.read_exact(&mut header).map_err(|_| ())?;
    let size = u32::from_be_bytes(header) as usize;
    if size == 0 || size > MAX_FRAME_BYTES {
        return Err(());
    }
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(size).map_err(|_| ())?;
    bytes.resize(size, 0);
    input.read_exact(&mut bytes).map_err(|_| ())?;
    let mut trailing = [0u8; 1];
    if input.read(&mut trailing).map_err(|_| ())? != 0 {
        return Err(());
    }
    let frame = DrawFrame::decode(&bytes).map_err(|_| ())?;
    println!(
        "sequence={} revision={} columns={} rows={} glyphs={} palette={}",
        frame.sequence,
        frame.revision,
        frame.columns,
        frame.rows,
        frame.glyphs.len(),
        frame.palette.len()
    );
    Ok(())
}
