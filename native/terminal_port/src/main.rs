fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let beam_port = match args.as_slice() {
        [] => false,
        [flag] if flag == "--beam-port" => true,
        _ => std::process::exit(1),
    };
    std::process::exit(swarm_terminal_port::guard::run(beam_port));
}
