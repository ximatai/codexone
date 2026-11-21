mod catalog;
mod data;
mod gateway;
mod headers;
mod listener;
mod reply;
mod response;

use std::{
    process::ExitCode,
    time::{SystemTime, UNIX_EPOCH},
};

use codexone_config::{ConfigCommand, ConfigError, Configuration, RuntimeConfiguration};
use codexone_storage::{Database, SCHEMA_VERSION};

fn main() -> ExitCode {
    let arguments: Vec<_> = std::env::args_os()
        .skip(1)
        .map(|value| value.to_string_lossy().into_owned())
        .collect();
    if let Some(command) = ConfigCommand::parse(&arguments) {
        return match command.run(SCHEMA_VERSION) {
            Ok(output) => {
                print!("{output}");
                ExitCode::SUCCESS
            }
            Err(error) => configuration_error(error),
        };
    }
    match arguments.as_slice() {
        [flag] if flag == "--help" => {
            println!("Usage: codexone [--check-config | --schema-version | --migrate | --help]");
            return ExitCode::SUCCESS;
        }
        [flag] if flag == "--migrate" => return migrate(),
        [] => {}
        _ => {
            eprintln!("Unsupported arguments. Use --help.");
            return ExitCode::from(64);
        }
    }
    let config = match RuntimeConfiguration::from_process()
        .and_then(|runtime| Configuration::load(runtime, unix_time()))
    {
        Ok(config) => config,
        Err(error) => return configuration_error(error),
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(_) => return service_failure(),
    };
    match runtime.block_on(gateway::run(config)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(gateway::StartupError::UnsupportedConfiguration) => {
            eprintln!(
                "This backend requires unmanaged single-identity configuration with HTTP upstream transport."
            );
            ExitCode::from(78)
        }
        Err(gateway::StartupError::UnsupportedSettings) => {
            eprintln!(
                "This backend does not support configured online backups or HTTP body staging."
            );
            ExitCode::from(78)
        }
        Err(gateway::StartupError::RequiresManagedKeys) => {
            eprintln!("Restored databases require managed Keys or account-pool configuration.");
            ExitCode::FAILURE
        }
        Err(gateway::StartupError::Service) => service_failure(),
    }
}

fn migrate() -> ExitCode {
    let directory = match RuntimeConfiguration::from_process()
        .and_then(|runtime| runtime.data_directory.ok_or(ConfigError::DataDirectory))
    {
        Ok(directory) => directory,
        Err(error) => return configuration_error(error),
    };
    if Database::migrate(directory.join("core.sqlite")).is_err() {
        return service_failure();
    }
    println!("Schema migration completed; any pre-upgrade backup is beside the database.");
    ExitCode::SUCCESS
}

fn configuration_error(error: ConfigError) -> ExitCode {
    eprintln!("{error}");
    ExitCode::from(error.exit_code())
}

fn service_failure() -> ExitCode {
    eprintln!("Service startup or shutdown failed.");
    ExitCode::FAILURE
}

fn unix_time() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs() as i64)
}
