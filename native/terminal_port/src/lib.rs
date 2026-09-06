//! Bounded terminal decoding/output plus an explicit-descriptor guarded owner.
//! The input, frame, output and protocol modules remain independent of terminal ownership.
pub mod frame;
pub mod guard;
pub mod input;
pub mod output;
pub mod protocol;
pub mod session;
pub mod tty;
