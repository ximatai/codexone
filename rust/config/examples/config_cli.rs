use std::process::ExitCode;

use codexone_config::ConfigCommand;

fn main() -> ExitCode {
    // A fixture for comparing against the pinned Swift baseline. The product
    // binary will use the storage adapter's schema version.
    const SWIFT_BASELINE_SCHEMA_VERSION: i64 = 19;
    let args: Vec<_> = std::env::args_os()
        .skip(1)
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect();
    let Some(command) = ConfigCommand::parse(&args) else {
        eprintln!("Unsupported arguments. Use --help.");
        return ExitCode::from(64);
    };
    match command.run(SWIFT_BASELINE_SCHEMA_VERSION) {
        Ok(output) => {
            print!("{output}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(error.exit_code())
        }
    }
}
