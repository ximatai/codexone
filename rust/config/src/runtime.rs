use std::collections::HashMap;
use std::net::IpAddr;
use std::path::PathBuf;

use crate::ConfigError::{self, *};
use crate::urls::http_origin_host;

const PRIVATE_NETWORKS: &[&str] = &[
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10",
    "fc00::/7",
];
const LOOPBACK_NETWORKS: &[&str] = &["127.0.0.0/8", "::1/128"];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Network {
    address: IpAddr,
    prefix: u8,
}

impl Network {
    pub fn address(self) -> IpAddr {
        self.address
    }

    pub fn prefix(self) -> u8 {
        self.prefix
    }

    fn parse(value: &str) -> Option<Self> {
        let (address, prefix) = value.split_once('/')?;
        let address: IpAddr = address.parse().ok()?;
        let prefix = decimal(prefix)?;
        let width = if address.is_ipv4() { 32 } else { 128 };
        (prefix <= width).then_some(Self { address, prefix })
    }

    pub fn contains(self, peer: IpAddr) -> bool {
        if self.prefix == 0 {
            return peer.is_ipv4() == self.address.is_ipv4();
        }
        match (self.address, peer) {
            (IpAddr::V4(network), IpAddr::V4(peer)) => {
                let shift = 32 - self.prefix;
                u32::from(network) >> shift == u32::from(peer) >> shift
            }
            (IpAddr::V6(network), IpAddr::V6(peer)) => {
                let shift = 128 - self.prefix;
                u128::from(network) >> shift == u128::from(peer) >> shift
            }
            _ => false,
        }
    }
}

pub struct RuntimeConfiguration {
    pub business_day_offset_minutes: i16,
    pub listen_address: Option<IpAddr>,
    pub allowed_networks: Vec<Network>,
    pub data_port: u16,
    pub admin_port: u16,
    pub backup_directory: Option<PathBuf>,
    pub data_directory: Option<PathBuf>,
    pub http_body_staging_directory: Option<PathBuf>,
    pub identity_path: Option<PathBuf>,
    pub account_pool_path: Option<PathBuf>,
    pub admin_token_file: Option<PathBuf>,
    pub master_key_file: Option<PathBuf>,
    pub admin_live_enabled: bool,
    pub admin_public_origin: Option<String>,
    pub web_directory: Option<PathBuf>,
    pub upstream_proxy: Option<String>,
}

impl RuntimeConfiguration {
    pub fn from_process() -> Result<Self, ConfigError> {
        Self::from_lookup(|key| {
            std::env::var_os(key).map(|value| value.to_string_lossy().into_owned())
        })
    }

    pub fn from_environment(environment: &HashMap<String, String>) -> Result<Self, ConfigError> {
        Self::from_lookup(|key| environment.get(key).cloned())
    }

    fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let business_day_offset_minutes = parse_business_day(
            get("CODEXONE_BUSINESS_DAY_OFFSET")
                .as_deref()
                .unwrap_or("UTC"),
        )
        .ok_or(BusinessDayOffset)?;
        let private: Vec<_> = PRIVATE_NETWORKS
            .iter()
            .map(|net| Network::parse(net).unwrap())
            .collect();
        let listen_address = get("CODEXONE_LISTEN_ADDRESS")
            .filter(|value| !value.is_empty())
            .map(|value| {
                let address = value.parse().map_err(|_| ListenAddress)?;
                private
                    .iter()
                    .any(|net| net.contains(address))
                    .then_some(address)
                    .ok_or(ListenAddress)
            })
            .transpose()?;
        let defaults: Vec<_> = private
            .into_iter()
            .chain(
                LOOPBACK_NETWORKS
                    .iter()
                    .map(|net| Network::parse(net).unwrap()),
            )
            .collect();
        let allowed_networks =
            match get("CODEXONE_ALLOWED_NETWORKS").filter(|value| !value.is_empty()) {
                Some(value) => {
                    let networks = value
                        .split(',')
                        .take(65)
                        .map(|part| {
                            let network = Network::parse(part).ok_or(AllowedNetworks)?;
                            defaults
                                .iter()
                                .any(|net| {
                                    net.prefix <= network.prefix && net.contains(network.address)
                                })
                                .then_some(network)
                                .ok_or(AllowedNetworks)
                        })
                        .collect::<Result<Vec<_>, _>>()?;
                    if networks.len() > 64 {
                        return Err(AllowedNetworks);
                    }
                    networks
                }
                None => defaults,
            };

        let path = |key, prerequisites, error| {
            get(key)
                .map(|value| {
                    (prerequisites && is_absolute_path(&value))
                        .then(|| PathBuf::from(value))
                        .ok_or(error)
                })
                .transpose()
        };
        let data_directory = path("CODEXONE_DATA_DIRECTORY", true, DataDirectory)?;
        let has_data = data_directory.is_some();
        let http_body_staging_directory = match get("CODEXONE_HTTP_BODY_STAGING").as_deref() {
            None | Some("off") => None,
            Some("on") if has_data => data_directory.clone(),
            _ => return Err(HttpBodyStaging),
        };
        let backup_directory = path("CODEXONE_BACKUP_DIRECTORY", has_data, BackupDirectory)?;
        let identity_path = path("CODEXONE_IDENTITY_CONFIG", has_data, IdentityPath)?;
        let admin_token_file = path("CODEXONE_ADMIN_TOKEN_FILE", has_data, AdminTokenPath)?;
        let has_admin = admin_token_file.is_some();
        let master_key_file = path(
            "CODEXONE_ACCOUNT_MASTER_KEY_FILE",
            has_admin,
            AccountMasterKey,
        )?;
        let account_pool_path = path(
            "CODEXONE_ACCOUNT_POOL_CONFIG",
            master_key_file.is_some() && identity_path.is_none(),
            AccountPoolPath,
        )?;
        let admin_live_enabled = match get("CODEXONE_ADMIN_LIVE").as_deref() {
            None | Some("on") => true,
            Some("off") => false,
            _ => return Err(AdminLive),
        };
        let admin_public_origin = get("CODEXONE_ADMIN_PUBLIC_ORIGIN");
        if let Some(origin) = admin_public_origin.as_deref() {
            let invalid_http_host = http_origin_host(origin).is_some_and(|host| {
                host != "127.0.0.1"
                    && host != "localhost"
                    && !listen_address
                        .is_some_and(|ip| host.trim_matches(['[', ']']).parse::<IpAddr>() == Ok(ip))
            });
            if !has_admin
                || origin.is_empty()
                || origin.len() > 2048
                || origin.as_bytes().contains(&0)
                || invalid_http_host
            {
                return Err(AdminOrigin);
            }
        }
        let web_directory = path("CODEXONE_WEB_DIRECTORY", true, WebDirectory)?;
        let upstream_proxy = get("CODEXONE_UPSTREAM_HTTP_PROXY").filter(|value| !value.is_empty());
        let port = |key, default, error| {
            get(key).map_or(Ok(default), |value| decimal(&value).ok_or(error))
        };
        let data_port = port("CODEXONE_DATA_PORT", 18080, DataPort)?;
        let admin_port = port("CODEXONE_ADMIN_PORT", 18081, AdminPort)?;
        if data_port != 0 && data_port == admin_port {
            return Err(ConflictingPorts);
        }

        Ok(Self {
            business_day_offset_minutes,
            listen_address,
            allowed_networks,
            data_port,
            admin_port,
            backup_directory,
            data_directory,
            http_body_staging_directory,
            identity_path,
            account_pool_path,
            admin_token_file,
            master_key_file,
            admin_live_enabled,
            admin_public_origin,
            web_directory,
            upstream_proxy,
        })
    }

    pub(crate) fn check_output(&self) -> String {
        let transport = if self.listen_address.is_some() {
            ",\"transportMode\":\"lan_http\""
        } else {
            ""
        };
        format!(
            "{{\"adminPort\":{},\"businessDay\":{{\"offsetMinutes\":{}}},\"dataPort\":{},\"host\":\"127.0.0.1\"{transport}}}\n",
            self.admin_port, self.business_day_offset_minutes, self.data_port,
        )
    }
}

pub(crate) fn decimal<T: std::str::FromStr>(value: &str) -> Option<T> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    value.parse().ok()
}

pub(crate) fn is_absolute_path(value: &str) -> bool {
    value.starts_with('/') && value.len() <= 4096 && !value.as_bytes().contains(&0)
}

fn parse_business_day(value: &str) -> Option<i16> {
    match value.as_bytes() {
        b"UTC" => Some(0),
        [
            sign @ (b'+' | b'-'),
            a @ b'0'..=b'9',
            b @ b'0'..=b'9',
            b':',
            b'0',
            b'0',
        ] => {
            let magnitude = i16::from(a - b'0') * 10 + i16::from(b - b'0');
            let hours = if *sign == b'-' { -magnitude } else { magnitude };
            (-12..=14).contains(&hours).then_some(hours * 60)
        }
        _ => None,
    }
}
