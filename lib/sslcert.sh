# The machine's self-signed TLS certificate, made at first boot for the
# name the machine has: by firstboot.d/15regen-sslcert, and again by
# firstboot.d/31fqdn when the name it settles is not the one the
# certificate holds.
#
# The names are given to turnkey-make-ssl-cert (turnkey-ssl), the fqdn
# first, so that it is the CN, with the addresses of the machine (--ip).
# Without names it takes them from `hostname -A`, the reverse lookup of
# every address of the machine, which answers whatever name the network's
# DNS keeps for the address: a Web container named web served CN=core on
# 2026-10-03. The names here are the ones 31fqdn writes into /etc/hosts
# (bin/fqdn.py --machine), so nothing is asked of the network.
#
# The hook that sources this sets HOOK, its name, for the log lines.

SSLCERT_PEM="${SSLCERT_PEM:-/etc/ssl/private/cert.pem}"
SSLCERT_KEY="${SSLCERT_KEY:-/etc/ssl/private/cert.key}"
SSLCERT_SERVICES=(nginx apache2 lighttpd tomcat10 tomcat11 webmin)

# The journal is a side effect of a hook whose job is the certificate:
# under -e a logger that fails (journald down, "socket /dev/log: Connection
# refused", the published core 19.0-6 booted headless on 2026-10-03) killed
# the hook at its first line, so it may not fail the hook.
sslcert_log() {
    local level=$1
    shift
    logger -t inithooks -p "$level" "[$HOOK] $*" 2>/dev/null || true
}

sslcert_info() { sslcert_log 5 "$*"; echo "INFO: [$HOOK] $*"; }

sslcert_fatal() {
    sslcert_log 3 "$*"
    echo "FATAL: [$HOOK] $*" 1>&2
    exit 1
}

# sslcert_names
# The names the certificate is for, on one line: the fqdn when the machine
# has one, then the hostname.
sslcert_names() {
    local answer key value hostname= fqdn=
    answer=$("$INITHOOKS_PATH/bin/fqdn.py" --machine --current="$(hostname)")
    while IFS='=' read -r key value; do
        case $key in
            HOSTNAME) hostname=$value ;;
            FQDN) fqdn=$value ;;
        esac
    done <<< "$answer"
    echo "${fqdn:+$fqdn }$hostname"
}

# modulus_md5 KIND FILE: the md5 of the modulus of the x509 or rsa FILE
sslcert_modulus_md5() { openssl "$1" -noout -modulus -in "$2" | openssl md5; }

# sslcert_make NAME...
# Makes the certificate and key for NAME..., then restarts the services
# that serve it.
sslcert_make() {
    local make _wait cert_md5 key_md5 service
    # Check for 'turnkey-make-ssl-cert' - should be provided by
    # turnkey-ssl package.
    make=$(which turnkey-make-ssl-cert) \
        || sslcert_fatal "turnkey-make-ssl-cert executable not found."

    # We use predefined 4096 bits default dhparams file for TLS1.2 (not
    # needed for TLS1.3)
    # See https://github.com/turnkeylinux/tracker/issues/1653 for more info.
    sslcert_info "Generating SSL/TLS cert & key for $*."
    "$make" --default --force --ip "$@"

    # make sure that generated keys are ready to use - avoids occasional
    # race condition where cert & key don't (yet) match. a single sleep
    # should be plenty but let's be sure
    for _wait in {1..5}; do
        cert_md5=$(sslcert_modulus_md5 x509 "$SSLCERT_PEM")
        key_md5=$(sslcert_modulus_md5 rsa "$SSLCERT_KEY")
        if [[ "$cert_md5" == "$key_md5" ]]; then
            sslcert_info "SSL cert and key have been written - ready to restart services"
            break
        elif [[ $_wait -eq 1 ]]; then
            sslcert_info "Waiting for updated ssl cert & key to be written to disk"
        else
            echo "..."
        fi
        sleep 1
    done

    sslcert_info "Restarting relevant services."
    for service in "${SSLCERT_SERVICES[@]}"; do
        # only restart services that are running
        if systemctl is-active --quiet "${service}.service"; then
            sslcert_info "$service running; restarting..."
            systemctl restart --quiet "$service"
        fi
    done

    # final tidy up
    update-ca-certificates
}

# sslcert_hashes: the subject's hash, then the issuer's, of the certificate
sslcert_hashes() {
    openssl x509 -in "$SSLCERT_PEM" -noout -subject_hash -issuer_hash \
        2>/dev/null
}

# sslcert_follow
# Makes the certificate again when it is the machine's own, self-signed,
# and its CN is not the name the machine has now. A certificate an
# authority signed (confconsole's Let's Encrypt writes the same files) is
# kept, and so is a machine without one.
sslcert_follow() {
    local names subject hashes cn
    [[ -e "$SSLCERT_PEM" ]] || return 0
    names=$(sslcert_names)
    if ! hashes=$(sslcert_hashes); then
        sslcert_info "$SSLCERT_PEM cannot be read as a certificate; kept"
        return 0
    fi
    if [[ "$(sed -n 1p <<< "$hashes")" != "$(sed -n 2p <<< "$hashes")" ]]; then
        sslcert_info "$SSLCERT_PEM is signed by an authority; kept"
        return 0
    fi
    subject=$(openssl x509 -in "$SSLCERT_PEM" -noout -subject -nameopt RFC2253)
    cn=$(sed -En 's/^subject=(.*,)?CN=([^,]*).*/\2/p' <<< "$subject")
    [[ "$cn" != "${names%% *}" ]] || return 0
    sslcert_info "$SSLCERT_PEM is for ${cn:-no name}, the machine is ${names%% *}"
    # shellcheck disable=SC2086 # the names are words
    sslcert_make $names
}
