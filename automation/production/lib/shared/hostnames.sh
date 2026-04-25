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
    [[ -z "${CONFIG[keycloak.admin_email]:-}" ]] && \
        CONFIG[keycloak.admin_email]="$(cfg 'keycloak_admin_email' 'admin@openg2p.internal')"
    [[ -z "${CONFIG[rancher.version]:-}" ]] && \
        CONFIG[rancher.version]="$(cfg 'rancher_version' '2.12.3')"
}
