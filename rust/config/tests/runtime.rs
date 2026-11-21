use std::collections::HashMap;

use codexone_config::{ConfigCommand, RuntimeConfiguration};

#[test]
fn allowed_networks_preserve_subnet_and_address_family() {
    let env = HashMap::from([
        ("CODEXONE_LISTEN_ADDRESS".to_owned(), "fd00::5".to_owned()),
        (
            "CODEXONE_ALLOWED_NETWORKS".to_owned(),
            "192.168.20.5/24,fd12::/16".to_owned(),
        ),
    ]);
    let config = RuntimeConfiguration::from_environment(&env).unwrap();
    let allowed = |peer: &str| {
        let address = peer.parse().unwrap();
        config
            .allowed_networks
            .iter()
            .any(|net| net.contains(address))
    };
    assert!(allowed("192.168.20.254"));
    assert!(allowed("fd12::1234"));
    assert!(!allowed("192.168.21.5"));
    assert!(!allowed("::ffff:192.168.20.254"));
}

#[test]
fn schema_command_uses_version_supplied_by_storage() {
    let command = ConfigCommand::parse(&["--schema-version"]).unwrap();
    assert_eq!(command.run(42).unwrap(), "42\n");
    assert!(ConfigCommand::parse(&["--schema-version", "--check-config"]).is_none());
}
