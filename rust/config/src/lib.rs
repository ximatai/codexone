//! Trusted process configuration. Loading only reads configured files and metadata.
//! Call synchronous loaders before starting async services.

mod files;
mod json;
mod runtime;
mod source;
mod urls;

use std::fmt;
use std::time::{SystemTime, UNIX_EPOCH};

pub use files::{AdminWebBundle, MasterKeyring};
pub use runtime::{Network, RuntimeConfiguration};
pub use source::{
    Catalog, ClientFingerprint, ExecutionBudget, ImageConfiguration, ImageModel, ImageSizePolicy,
    Model, ModelProfileProvenance, ResponsesConfiguration, SingleIdentity, Source,
    UpstreamContract, UpstreamTransport,
};
pub use urls::UpstreamHttpProxy;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigError {
    BusinessDayOffset,
    ListenAddress,
    AllowedNetworks,
    DataPort,
    AdminPort,
    ConflictingPorts,
    BackupDirectory,
    DataDirectory,
    HttpBodyStaging,
    IdentityPath,
    AccountPoolPath,
    AdminTokenPath,
    AccountMasterKey,
    AdminLive,
    AdminOrigin,
    WebDirectory,
    InvalidFileOrSetting,
}

impl ConfigError {
    pub fn exit_code(self) -> u8 {
        match self {
            Self::InvalidFileOrSetting => 1,
            _ => 78,
        }
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::BusinessDayOffset => "Invalid business day offset configuration.",
            Self::ListenAddress => "Invalid private listen address configuration.",
            Self::AllowedNetworks => "Invalid allowed source networks configuration.",
            Self::DataPort => "Invalid port configuration: CODEXONE_DATA_PORT.",
            Self::AdminPort => "Invalid port configuration: CODEXONE_ADMIN_PORT.",
            Self::ConflictingPorts => "Data and admin ports must differ.",
            Self::BackupDirectory => "Invalid backup directory configuration.",
            Self::DataDirectory => "Invalid data directory configuration.",
            Self::HttpBodyStaging => "Invalid HTTP body staging configuration.",
            Self::IdentityPath => "Invalid single-identity configuration.",
            Self::AccountPoolPath => "Invalid account pool configuration.",
            Self::AdminTokenPath => "Invalid admin credential configuration.",
            Self::AccountMasterKey => "Invalid account master key configuration.",
            Self::AdminLive => "Invalid admin live configuration.",
            Self::AdminOrigin => "Invalid public admin origin configuration.",
            Self::WebDirectory => "Invalid admin web directory configuration.",
            Self::InvalidFileOrSetting => "Service startup or shutdown failed.",
        })
    }
}

impl std::error::Error for ConfigError {}

/// Validated startup snapshot. Contains credentials and intentionally omits `Debug`.
pub struct Configuration {
    pub runtime: RuntimeConfiguration,
    pub source: Option<Source>,
    pub upstream_proxy: Option<UpstreamHttpProxy>,
    pub web_bundle: Option<AdminWebBundle>,
    pub master_keys: Option<MasterKeyring>,
    pub admin_digest: Option<[u8; 32]>,
    pub admin_origin: Option<String>,
}

impl Configuration {
    pub fn load(runtime: RuntimeConfiguration, now_unix_seconds: i64) -> Result<Self, ConfigError> {
        use ConfigError::{
            AccountMasterKey, AdminTokenPath, BackupDirectory, InvalidFileOrSetting,
        };

        if let Some(path) = runtime.backup_directory.as_deref() {
            files::validate_backup_directory(path).ok_or(BackupDirectory)?;
        }
        let source = if let Some(path) = runtime.identity_path.as_deref() {
            let identity =
                source::load_identity(path, now_unix_seconds).ok_or(InvalidFileOrSetting)?;
            if identity.managed_keys && runtime.admin_token_file.is_none() {
                return Err(AdminTokenPath);
            }
            Some(Source::SingleIdentity(Box::new(identity)))
        } else if let Some(path) = runtime.account_pool_path.as_deref() {
            let pool = source::load_pool(path, now_unix_seconds).ok_or(InvalidFileOrSetting)?;
            Some(Source::AccountPool(Box::new(pool)))
        } else {
            None
        };
        let forbidden = match source.as_ref() {
            Some(Source::SingleIdentity(identity)) => identity.key_sha256,
            _ => None,
        };
        let upstream_proxy = runtime
            .upstream_proxy
            .as_deref()
            .map(|url| urls::parse_proxy(url).ok_or(InvalidFileOrSetting))
            .transpose()?;
        let web_bundle = runtime
            .web_directory
            .as_deref()
            .map(|path| files::load_web_bundle(path).ok_or(InvalidFileOrSetting))
            .transpose()?;
        let master_keys = runtime
            .master_key_file
            .as_deref()
            .map(|path| {
                files::load_master_keyring(path, runtime.admin_token_file.as_deref(), forbidden)
                    .ok_or(AccountMasterKey)
            })
            .transpose()?;
        let admin_origin = runtime
            .admin_public_origin
            .as_deref()
            .map(|origin| {
                urls::canonical_admin_origin(origin, runtime.listen_address)
                    .ok_or(InvalidFileOrSetting)
            })
            .transpose()?;
        let admin_digest = runtime
            .admin_token_file
            .as_deref()
            .map(|path| files::load_admin_digest(path, forbidden).ok_or(InvalidFileOrSetting))
            .transpose()?;

        Ok(Self {
            runtime,
            source,
            upstream_proxy,
            web_bundle,
            master_keys,
            admin_digest,
            admin_origin,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigCommand {
    CheckConfig,
    SchemaVersion,
}

impl ConfigCommand {
    /// Matches only the two standalone flags. The caller handles other commands.
    pub fn parse(args: &[impl AsRef<str>]) -> Option<Self> {
        match args {
            [flag] if flag.as_ref() == "--check-config" => Some(Self::CheckConfig),
            [flag] if flag.as_ref() == "--schema-version" => Some(Self::SchemaVersion),
            _ => None,
        }
    }

    /// Returns the exact stdout for a successful command, including its trailing newline.
    /// The product supplies the storage adapter's schema version.
    pub fn run(self, schema_version: i64) -> Result<String, ConfigError> {
        match self {
            Self::SchemaVersion => Ok(format!("{schema_version}\n")),
            Self::CheckConfig => {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_err(|_| ConfigError::InvalidFileOrSetting)?;
                let config = Configuration::load(
                    RuntimeConfiguration::from_process()?,
                    now.as_secs() as i64,
                )?;
                Ok(config.runtime.check_output())
            }
        }
    }
}
