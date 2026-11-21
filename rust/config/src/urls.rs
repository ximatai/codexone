// Preserve the authority and path as written by the operator. WHATWG URL parsers
// canonicalize addresses and resolve dot segments before the allowlist can check them.
use std::borrow::Cow;
use std::net::IpAddr;

use percent_encoding::percent_decode_str;

use crate::runtime::decimal;

struct Components<'a> {
    scheme: &'a str,
    host: Cow<'a, str>,
    raw_host: &'a str,
    raw_port: &'a str,
    port: Option<i64>,
    path: Cow<'a, str>,
    user_info: bool,
    query_or_fragment: bool,
}

impl<'a> Components<'a> {
    fn parse(input: &'a str) -> Option<Self> {
        let (scheme, rest) = input.split_once("://")?;
        let separator = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let (authority, suffix) = rest.split_at(separator);
        let (host_and_port, user_info) = match authority.rsplit_once('@') {
            Some((_, remainder)) => (remainder, true),
            None => (authority, false),
        };
        let (raw_host, raw_port) = if host_and_port.starts_with('[') {
            let close = host_and_port.find(']')?;
            let (host, remainder) = host_and_port.split_at(close + 1);
            match remainder {
                "" => (host, ""),
                value => (host, value.strip_prefix(':')?),
            }
        } else {
            host_and_port.split_once(':').unwrap_or((host_and_port, ""))
        };
        if !raw_port.bytes().all(|byte| byte.is_ascii_digit()) || !valid_host_syntax(raw_host, true)
        {
            return None;
        }
        let host = percent_decode_str(raw_host).decode_utf8().ok()?;
        let host = if host.contains('\0') {
            // Foundation retains the encoded spelling of a NUL-containing host.
            Cow::Borrowed(raw_host)
        } else if host
            .split('.')
            .any(|label| label.to_ascii_lowercase().starts_with("xn--"))
        {
            let (host, status) = idna::domain_to_unicode(&host);
            status.ok()?;
            Cow::Owned(host)
        } else {
            host
        };
        let (path, query_or_fragment) = match suffix.find(['?', '#']) {
            Some(index) => (&suffix[..index], true),
            None => (suffix, false),
        };
        let path = percent_decode_str(path)
            .decode_utf8()
            .unwrap_or(Cow::Borrowed(path));
        Some(Self {
            scheme,
            host,
            raw_host,
            raw_port,
            port: decimal(raw_port),
            path,
            user_info,
            query_or_fragment,
        })
    }

    fn no_credentials_or_suffix(&self) -> bool {
        !self.user_info && !self.query_or_fragment
    }
}

pub(crate) fn http_origin_host(input: &str) -> Option<Cow<'_, str>> {
    let url = Components::parse(input)?;
    (url.scheme == "http").then_some(url.host)
}

pub(crate) fn canonical_admin_origin(
    input: &str,
    listen_address: Option<IpAddr>,
) -> Option<String> {
    let url = Components::parse(input)?;
    let plain_http = url.scheme == "http";
    if !input.bytes().all(|byte| (33..127).contains(&byte))
        || !url.no_credentials_or_suffix()
        || !matches!(url.path.as_ref(), "" | "/")
        || url.host.is_empty()
        || url.port.is_some_and(|port| !(1..=65535).contains(&port))
        || !(url.scheme == "https"
            || plain_http
                && (matches!(url.host.as_ref(), "127.0.0.1" | "localhost")
                    || listen_address.is_some_and(|address| {
                        url.host.trim_matches(['[', ']']).parse::<IpAddr>() == Ok(address)
                    })))
    {
        return None;
    }
    let host = canonical_host(&url.host, url.raw_host)?;
    let default_port = if plain_http { 80 } else { 443 };
    let port = match (url.port, url.raw_port) {
        (Some(port), _) if port == default_port => String::new(),
        (Some(port), _) => format!(":{port}"),
        (None, "") => String::new(),
        (None, raw_port) => format!(":{raw_port}"),
    };
    Some(format!("{}://{host}{port}", url.scheme))
}

fn valid_host_syntax(host: &str, encoded: bool) -> bool {
    let (characters, bracketed) = host
        .strip_prefix('[')
        .and_then(|host| host.strip_suffix(']'))
        .map_or((host, false), |host| (host, true));
    let mut chars = characters.chars();
    while let Some(ch) = chars.next() {
        if ch == '%' && encoded {
            if !chars.next().is_some_and(|ch| ch.is_ascii_hexdigit())
                || !chars.next().is_some_and(|ch| ch.is_ascii_hexdigit())
            {
                return false;
            }
        } else if ch.is_ascii()
            && !(ch.is_ascii_alphanumeric()
                || "-._~!$&'()*+,;=".contains(ch)
                || bracketed && matches!(ch, ':' | '%'))
        {
            return false;
        }
    }
    true
}

fn canonical_host(host: &str, raw_host: &str) -> Option<String> {
    let host = host.to_lowercase();
    if raw_host.to_ascii_lowercase() == host && host.contains("%00") {
        return Some(host);
    }
    if !valid_host_syntax(&host, false) {
        return None;
    }
    if host.starts_with('[') {
        return Some(host.replace('%', "%25"));
    }
    if host.is_ascii() {
        Some(host)
    } else {
        idna::domain_to_ascii(&host).ok()
    }
}

pub struct UpstreamHttpProxy {
    pub host: String,
    pub port: u16,
}

pub(crate) fn parse_proxy(input: &str) -> Option<UpstreamHttpProxy> {
    let url = Components::parse(input)?;
    if input.len() > 2048
        || input.as_bytes().contains(&0)
        || url.scheme != "http"
        || !url.no_credentials_or_suffix()
        || !matches!(url.path.as_ref(), "" | "/")
        || url.host.is_empty()
        || url.host.contains('%')
        || !url.host.bytes().all(|byte| (33..127).contains(&byte))
    {
        return None;
    }
    let port = u16::try_from(url.port?).ok()?;
    (port != 0).then(|| UpstreamHttpProxy {
        host: url
            .host
            .strip_prefix('[')
            .and_then(|host| host.strip_suffix(']'))
            .unwrap_or(&url.host)
            .to_owned(),
        port,
    })
}

pub(crate) fn is_subscription_upstream(input: &str) -> Option<bool> {
    let url = Components::parse(input)?;
    if !url.no_credentials_or_suffix() {
        return None;
    }
    match (url.scheme, url.host.as_ref(), url.path.as_ref(), url.port) {
        ("https", "chatgpt.com", "/backend-api/codex", None | Some(443)) => Some(true),
        ("http", "127.0.0.1", "/v1" | "/backend-api/codex", Some(1..=65535)) => Some(false),
        _ => None,
    }
}
