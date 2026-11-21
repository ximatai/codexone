pub mod body_budget;
mod catalog;
mod data;
mod gateway;
mod headers;
mod image_route;
mod listener;
mod online_backup;
mod managed;
mod reply;
mod response;

use std::{
    process::ExitCode,
    time::{SystemTime, UNIX_EPOCH},
};

use codexone_config::{ConfigCommand, ConfigError, Configuration, RuntimeConfiguration};
use codexone_maintenance::Command as MaintenanceCommand;
use codexone_storage::{AccountCredentialCipher, Database, SCHEMA_VERSION};

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
    if let Some(command) = MaintenanceCommand::parse(&arguments) {
        return maintenance(command);
    }
    match arguments.as_slice() {
        [flag] if flag == "--help" => {
            println!(concat!(
                "Usage: codexone [--check-config | --schema-version | --migrate",
                " | --import-keys ABSOLUTE_MANIFEST",
                " | --backup ABSOLUTE_NEW_BUNDLE | --verify-backup ABSOLUTE_BUNDLE",
                " | --restore ABSOLUTE_BUNDLE | --maintenance-status",
                " | --reconcile-restored ABSOLUTE_BASELINE_JSON | --key-status",
                " | --reencrypt-credentials ABSOLUTE_NEW_BUNDLE | --resume-reencryption",
                " | --check-key-retirement ABSOLUTE_INVENTORY_JSON | --help]"
            ));
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
                "This backend supports HTTP upstream transport for single identities and account pools."
            );
            ExitCode::from(78)
        }
        Err(gateway::StartupError::UnsupportedSettings) => {
            eprintln!("This backend does not support configured HTTP body staging.");
            ExitCode::from(78)
        }
        Err(gateway::StartupError::RequiresManagedKeys) => {
            eprintln!("Restored databases require managed Keys or account-pool configuration.");
            ExitCode::FAILURE
        }
        Err(gateway::StartupError::Service) => service_failure(),
    }
}

fn maintenance(command: MaintenanceCommand) -> ExitCode {
    let runtime = match RuntimeConfiguration::from_process().and_then(|runtime| {
        runtime.validate_backup_directory()?;
        Ok(runtime)
    }) {
        Ok(runtime) => runtime,
        Err(error) => return configuration_error(error),
    };
    let Some(directory) = &runtime.data_directory else {
        return configuration_error(ConfigError::DataDirectory);
    };
    let importing_keys = matches!(command, MaintenanceCommand::ImportKeys(_));
    let admin_digest = if importing_keys {
        match runtime.key_import_admin_digest() {
            Ok(digest) => Some(digest),
            Err(error) => return configuration_error(error),
        }
    } else {
        None
    };
    let protection =
        if let Some(path) = runtime.master_key_file.as_ref().filter(|_| !importing_keys) {
            let forbidden_digest = match runtime.maintenance_identity_digest(unix_time()) {
                Ok(digest) => digest,
                Err(error) => return configuration_error(error),
            };
            match AccountCredentialCipher::load(
                path,
                runtime.admin_token_file.as_deref(),
                forbidden_digest.as_deref(),
            ) {
                Ok(cipher) => Some(cipher),
                Err(_) => return configuration_error(ConfigError::AccountMasterKey),
            }
        } else {
            None
        };
    match command.run(
        &directory.join("core.sqlite"),
        protection.as_ref(),
        runtime.business_day_offset_minutes,
        admin_digest.as_ref(),
    ) {
        Ok(result) => {
            println!("{result}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn migrate() -> ExitCode {
    let directory = match RuntimeConfiguration::from_process().and_then(|runtime| {
        runtime.validate_backup_directory()?;
        runtime.data_directory.ok_or(ConfigError::DataDirectory)
    }) {
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

#[cfg(test)]
mod managed_process;
