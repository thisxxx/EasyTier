//! A minimal EasyTier node for relay / subnet-gateway duty.
//!
//! Everything is configured on the command line: this binary carries no config
//! file, no config server and no clap. The flag set below is the whole surface.
//!
//! The network runs with a fixed policy that suits a small router acting as a
//! relay or a subnet gateway:
//!
//! * `no_tun` + `use_smoltcp` — subnet proxy runs on the userspace stack, so no
//!   TUN device and no kernel forwarding rules are needed.
//! * `private_mode` — only networks admitted by `--private-group` (or sharing
//!   this node's secret) may join.
//! * `enable_exit_node`, `enable_kcp_proxy`, `latency_first`,
//!   `proxy_forward_by_system`, `relay_all_peer_rpc` — see `default_flags`.

use std::{ffi::OsString, str::FromStr as _, sync::Arc};

use anyhow::Context as _;
use cidr::{Ipv4Cidr, Ipv4Inet};
use easytier::{
    common::{
        config::{
            ConfigFileControl, ConfigLoader as _, NetworkIdentity, PeerConfig, TomlConfigLoader,
        },
        log,
    },
    instance::factory::native_compact_instance_manager_with_runtime,
    proto::common::FlagsPatch,
    rpc_service::ReadOnlyApiRpcServer,
};
use easytier_core::config::PrivateGroupConfig;

/// Where the read-only management API listens. Fixed, loopback only: this is
/// what `easytier-cli` and the LuCI app talk to.
const RPC_PORTAL: &str = "127.0.0.1:15888";

const USAGE: &str = "\
easytier-lite — minimal EasyTier relay / subnet-gateway node

Usage:
  easytier-lite --network-name <NAME> [OPTIONS]

Required:
  --network-name <NAME>        network name this node joins

Options:
  --network-secret <SECRET>    network secret; omit for a secret-less network
  --ipv4 <CIDR>                static virtual address, e.g. 10.126.126.1/24
  -d, --dhcp                   let the network assign a virtual address instead
  -p, --peers <URL,...>        peers to connect to, e.g. tcp://1.2.3.4:11010
  -l, --listeners <URL,...>    listeners, e.g. tcp://0.0.0.0:11010
                               defaults to tcp+udp on 0.0.0.0:11010
      --no-listener            only connect out, never accept connections
  -n, --proxy-networks <CIDR,...>
                               local subnets to export, e.g. 192.168.1.0/24
                               also accepts 192.168.1.0/24->10.10.0.0/24
      --private-group <NAME#SECRET>
                               admit this network while private mode is on;
                               repeatable, NAME# admits by name only
      --console-log-level <LEVEL>
                               trace|debug|info|warn|error|off (default: info)
  -h, --help                   show this help
  -V, --version                show the version

Private mode is always on. A node whose network name and secret are not listed
by --private-group (and differ from this node's) is rejected.
";

enum Command {
    Run(Options),
    Exit,
}

#[derive(Default)]
struct Options {
    network_name: Option<String>,
    network_secret: Option<String>,
    ipv4: Option<String>,
    dhcp: bool,
    peers: Vec<String>,
    listeners: Vec<String>,
    no_listener: bool,
    proxy_networks: Vec<String>,
    private_groups: Vec<String>,
    console_log_level: Option<String>,
}

fn take_value(
    flag: &str,
    inline: Option<String>,
    args: &mut impl Iterator<Item = OsString>,
) -> anyhow::Result<String> {
    if let Some(value) = inline {
        return Ok(value);
    }
    args.next()
        .with_context(|| format!("{flag} requires a value"))?
        .into_string()
        .map_err(|_| anyhow::anyhow!("{flag} must be valid UTF-8"))
}

/// Appends one or more comma separated entries.
fn push_list(target: &mut Vec<String>, raw: String) {
    for part in raw.split(',') {
        let part = part.trim();
        if !part.is_empty() {
            target.push(part.to_owned());
        }
    }
}

fn parse_args(mut args: impl Iterator<Item = OsString>) -> anyhow::Result<Command> {
    let mut options = Options::default();

    while let Some(arg) = args.next() {
        let arg = arg
            .into_string()
            .map_err(|_| anyhow::anyhow!("arguments must be valid UTF-8"))?;
        if arg == "-h" || arg == "--help" {
            print!("{USAGE}");
            return Ok(Command::Exit);
        }
        if arg == "-V" || arg == "--version" {
            println!("easytier-lite {}", env!("CARGO_PKG_VERSION"));
            return Ok(Command::Exit);
        }

        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) => (flag.to_owned(), Some(value.to_owned())),
            None => (arg, None),
        };

        match flag.as_str() {
            "--network-name" => {
                options.network_name = Some(take_value(&flag, inline, &mut args)?)
            }
            "--network-secret" => {
                options.network_secret = Some(take_value(&flag, inline, &mut args)?)
            }
            "--ipv4" => options.ipv4 = Some(take_value(&flag, inline, &mut args)?),
            "-d" | "--dhcp" => options.dhcp = true,
            "-p" | "--peers" => push_list(&mut options.peers, take_value(&flag, inline, &mut args)?),
            "-l" | "--listeners" => {
                push_list(&mut options.listeners, take_value(&flag, inline, &mut args)?)
            }
            "--no-listener" => options.no_listener = true,
            "-n" | "--proxy-networks" => push_list(
                &mut options.proxy_networks,
                take_value(&flag, inline, &mut args)?,
            ),
            "--private-group" => push_list(
                &mut options.private_groups,
                take_value(&flag, inline, &mut args)?,
            ),
            "--console-log-level" => {
                options.console_log_level = Some(take_value(&flag, inline, &mut args)?)
            }
            other => anyhow::bail!("unknown argument {other:?}; try --help"),
        }
    }

    if options.network_name.is_none() {
        anyhow::bail!("--network-name is required; try --help");
    }
    Ok(Command::Run(options))
}

/// The policy this build runs with. Callers can still override any of these
/// through the environment the node runs in; the values here are the defaults
/// a bare command line gets.
fn default_flags() -> FlagsPatch {
    FlagsPatch {
        enable_exit_node: Some(true),
        enable_kcp_proxy: Some(true),
        latency_first: Some(true),
        no_tun: Some(true),
        private_mode: Some(true),
        proxy_forward_by_system: Some(true),
        relay_all_peer_rpc: Some(true),
        use_smoltcp: Some(true),
        ..Default::default()
    }
}

fn parse_peer(raw: &str) -> anyhow::Result<PeerConfig> {
    Ok(PeerConfig {
        uri: url::Url::parse(raw).with_context(|| format!("invalid peer {raw:?}"))?,
        peer_public_key: None,
    })
}

fn parse_proxy_network(raw: &str) -> anyhow::Result<(Ipv4Cidr, Option<Ipv4Cidr>)> {
    let (real, mapped) = match raw.split_once("->") {
        Some((real, mapped)) => (real.trim(), Some(mapped.trim())),
        None => (raw.trim(), None),
    };
    let real =
        Ipv4Cidr::from_str(real).with_context(|| format!("invalid proxy network {real:?}"))?;
    let mapped = match mapped {
        Some(mapped) => Some(
            Ipv4Cidr::from_str(mapped)
                .with_context(|| format!("invalid mapped network {mapped:?}"))?,
        ),
        None => None,
    };
    Ok((real, mapped))
}

/// Parses `NAME#SECRET`; `NAME#` admits by name only, bare `NAME` does the same.
fn parse_private_group(raw: &str) -> PrivateGroupConfig {
    let (name, secret) = match raw.split_once('#') {
        Some((name, secret)) if !secret.is_empty() => (name, Some(secret.to_owned())),
        Some((name, _)) => (name, None),
        None => (raw, None),
    };
    PrivateGroupConfig {
        network_name: name.to_owned(),
        network_secret: secret,
    }
}

fn build_config(options: &Options) -> anyhow::Result<TomlConfigLoader> {
    let network_name = options
        .network_name
        .clone()
        .context("--network-name is required")?;
    let config = TomlConfigLoader::default();

    config.set_network_identity(NetworkIdentity::new(
        network_name,
        options.network_secret.clone().unwrap_or_default(),
    ));

    if let Some(ipv4) = options.ipv4.as_deref() {
        let ipv4 =
            Ipv4Inet::from_str(ipv4).with_context(|| format!("invalid --ipv4 {ipv4:?}"))?;
        config.set_ipv4(Some(ipv4));
    } else if options.dhcp {
        config.set_dhcp(true);
    }

    let peers = options
        .peers
        .iter()
        .map(|peer| parse_peer(peer))
        .collect::<anyhow::Result<Vec<_>>>()?;
    config.set_peers(peers);

    if options.no_listener {
        config.set_listeners(Vec::new());
    } else if options.listeners.is_empty() {
        config.set_listeners(vec![
            url::Url::parse("tcp://0.0.0.0:11010").expect("static url"),
            url::Url::parse("udp://0.0.0.0:11010").expect("static url"),
        ]);
    } else {
        let listeners = options
            .listeners
            .iter()
            .map(|listener| {
                url::Url::parse(listener)
                    .with_context(|| format!("invalid listener {listener:?}"))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        config.set_listeners(listeners);
    }

    for raw in &options.proxy_networks {
        let (real, mapped) = parse_proxy_network(raw)?;
        config.add_proxy_cidr(real, mapped)?;
    }

    config.set_private_groups(
        options
            .private_groups
            .iter()
            .map(|raw| parse_private_group(raw))
            .collect(),
    );
    config.patch_flags(default_flags());

    Ok(config)
}

#[tokio::main(worker_threads = 2)]
async fn main() -> anyhow::Result<()> {
    let Command::Run(options) = parse_args(std::env::args_os().skip(1))? else {
        return Ok(());
    };

    log::init_console_with_level(options.console_log_level.as_deref().unwrap_or("info"))?;

    let config = build_config(&options)?;
    let manager = Arc::new(native_compact_instance_manager_with_runtime(
        tokio::runtime::Handle::current(),
    ));
    let instance_id =
        manager.run_network_instance(config, ConfigFileControl::STATIC_CONFIG)?;
    let _rpc_server =
        ReadOnlyApiRpcServer::new(Some(RPC_PORTAL.to_owned()), None, manager.clone())?
            .serve()
            .await?;

    eprintln!(
        "easytier-lite started: instance={instance_id:?}, proxies={:?}, rpc={RPC_PORTAL}",
        options.proxy_networks
    );

    let stopped_unexpectedly = tokio::select! {
        signal = tokio::signal::ctrl_c() => {
            signal.context("failed to listen for Ctrl-C")?;
            false
        }
        _ = manager.wait() => true,
    };

    for instance in manager.instances() {
        instance.stop().await;
    }
    if stopped_unexpectedly {
        anyhow::bail!("EasyTier instance stopped unexpectedly");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: impl IntoIterator<Item = &'static str>) -> anyhow::Result<Options> {
        let args = args
            .into_iter()
            .map(OsString::from)
            .collect::<Vec<_>>()
            .into_iter();
        match parse_args(args)? {
            Command::Run(options) => Ok(options),
            Command::Exit => panic!("expected a run command"),
        }
    }

    #[test]
    fn parses_the_full_command_line() {
        let options = parse([
            "--network-name",
            "home",
            "--network-secret=s3cret",
            "--ipv4",
            "10.126.126.1/24",
            "-p",
            "tcp://1.2.3.4:11010",
            "-l",
            "udp://0.0.0.0:11010,tcp://0.0.0.0:11010",
            "-n",
            "192.168.1.0/24",
            "--private-group",
            "office#officepass",
            "--console-log-level",
            "debug",
        ])
        .unwrap();

        assert_eq!(options.network_name.as_deref(), Some("home"));
        assert_eq!(options.network_secret.as_deref(), Some("s3cret"));
        assert_eq!(options.ipv4.as_deref(), Some("10.126.126.1/24"));
        assert_eq!(options.peers, ["tcp://1.2.3.4:11010"]);
        assert_eq!(options.listeners.len(), 2);
        assert_eq!(options.proxy_networks, ["192.168.1.0/24"]);
        assert_eq!(options.private_groups, ["office#officepass"]);
        assert_eq!(options.console_log_level.as_deref(), Some("debug"));
    }

    #[test]
    fn requires_a_network_name() {
        assert!(parse(["--dhcp"]).is_err());
    }

    #[test]
    fn rejects_unknown_arguments() {
        assert!(parse(["--network-name", "home", "--config-file", "x.toml"]).is_err());
    }

    #[test]
    fn parses_mapped_proxy_networks() {
        let (real, mapped) = parse_proxy_network("192.168.1.0/24->10.10.0.0/24").unwrap();

        assert_eq!(real.to_string(), "192.168.1.0/24");
        assert_eq!(mapped.unwrap().to_string(), "10.10.0.0/24");
    }

    #[test]
    fn parses_private_group_entries() {
        let pair = parse_private_group("office#pass");
        assert_eq!(pair.network_name, "office");
        assert_eq!(pair.network_secret.as_deref(), Some("pass"));

        let name_only = parse_private_group("office#");
        assert_eq!(name_only.network_name, "office");
        assert!(name_only.network_secret.is_none());
    }

    #[test]
    fn default_flags_match_the_router_policy() {
        let flags = default_flags();

        assert_eq!(flags.no_tun, Some(true));
        assert_eq!(flags.private_mode, Some(true));
        assert_eq!(flags.use_smoltcp, Some(true));
        assert_eq!(flags.enable_kcp_proxy, Some(true));
        assert_eq!(flags.enable_exit_node, Some(true));
        assert_eq!(flags.latency_first, Some(true));
        assert_eq!(flags.proxy_forward_by_system, Some(true));
        assert_eq!(flags.relay_all_peer_rpc, Some(true));
    }
}
