#!/usr/bin/env bash
# =============================================================================
# Shared hostname helpers + single-node-config-key bridge
# =============================================================================
# Sourced by compute/RP role scripts AFTER load_config has populated CONFIG[].
# Provides the helpers single-node's phase scripts expect, mapped to the
# production config keys (which are flat: internal_domain, keycloak_admin_email).
# =============================================================================

# Admin tools live under the internal domain, served via Wireguard.
get_rancher_hostname() {
    echo "rancher.$(cfg 'internal_domain' 'openg2p.internal')"
}

get_keycloak_hostname() {
    echo "keycloak.$(cfg 'internal_domain' 'openg2p.internal')"
}

# Bridge production flat keys to the dotted keys vendored single-node code reads.
# Call this once after load_config "$CONFIG_FILE".
hostnames_bridge_config_keys() {
    # Only bridge if not already set, so user could override either way.
    if [[ -z "${CONFIG[keycloak.admin_email]:-}" ]]; then
        CONFIG[keycloak.admin_email]="$(cfg 'keycloak_admin_email' 'admin@openg2p.internal')"
    fi
    if [[ -z "${CONFIG[rancher.version]:-}" ]]; then
        CONFIG[rancher.version]="$(cfg 'rancher_version' '2.12.3')"
    fi
}

# Ensure rancher.<internal_domain> and keycloak.<internal_domain> are in
# /etc/hosts pointing at the RP's private IP — required for phase 3's API
# calls from the compute node, since admin tools are only DNS-resolvable
# via the RP's dnsmasq (which compute does not use).
# Idempotent and additive — does not remove unrelated /etc/hosts entries.
ensure_admin_hostnames_in_etc_hosts() {
    local rp_ip
    rp_ip=$(cfg "rp_private_ip" "")
    if [[ -z "$rp_ip" ]]; then
        log_warn "rp_private_ip not in config; cannot ensure /etc/hosts entries"
        return 0
    fi
    local internal
    internal=$(cfg "internal_domain" "openg2p.internal")
    local host
    for host in "rancher.${internal}" "keycloak.${internal}"; do
        if ! grep -qE "(^|[[:space:]])${host}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
            echo "${rp_ip} ${host}" >> /etc/hosts
            log_info "Added /etc/hosts entry: ${rp_ip} ${host}"
        fi
    done
}
