#!/bin/bash -e

: ${REMOTE_HOST:=127.0.0.1}
: ${REMOTE_PORT:=1194}
: ${OPENVPN_CONFIG_FILE:=/etc/openvpn/server.conf}
: ${AUTH_TYPE:=none}

echo "REMOTE_HOST=$REMOTE_HOST"
echo "REMOTE_PORT=$REMOTE_PORT"
echo "OPENVPN_CONFIG_FILE=$OPENVPN_CONFIG_FILE"
echo "AUTH_TYPE=$AUTH_TYPE"
if [ "$DEBUG" = 'true' ]; then
  [ ! -z "$CA_CERTIFICATE" ] && echo "CA_CERTIFICATE=$CA_CERTIFICATE"
  [ ! -z "$DH_PARAMS" ] && echo "DH_PARAMS=$DH_PARAMS"
fi

export PATH="$PATH:/usr/share/easy-rsa"

set_conf(){
  # Really basic check and append.  This doesn't cater for directives that should only be set once
  # But it covers directives that can be set multiple times with different value
  if ! grep "^$1" "$OPENVPN_CONFIG_FILE"; then
    echo "$1" >> "$OPENVPN_CONFIG_FILE"
  fi
}

cd /etc/openvpn

# initialise the pki directory if it doesn't exist
if [ ! -e 'pki' ]; then
  echo '> initialising easy-rsa pki'
  easyrsa init-pki
fi

# currently we build all pki including server key and cert if a CA is not provided
if [ -z "$CA_CERTIFICATE" ]; then
  if [ ! -e '/etc/openvpn/pki/ca.crt' ]; then
    echo '> generating CA'
    easyrsa --batch build-ca nopass

    echo '> generating server pki'
    [ "$DEBUG" = 'true' ] && ls -l /etc/openvpn/pki
    # can't find a way to do this non-interactive (use build-server-full instead)
    # easyrsa --batch gen-req "$(hostname -s)" nopass
    # easyrsa show-req "$(hostname -s)"
    # interactive only
    # easyrsa sign-req server "$(hostname -s)"
    # we're going to full re-generate based on CN-by-host-name atm if we need to
    # but if the key exists, just skip entirely atm
    if [ ! -e /etc/openvpn/pki/reqs/$(hostname -s).key ]; then
      [ -e "/etc/openvpn/pki/reqs/.req" ] && rm "/etc/openvpn/pki/reqs/$(hostname -s).req"
      echo ">> easyrsa build-server-full $(hostname -s)"
      easyrsa build-server-full "$(hostname -s)" nopass
    fi
  else
    echo '> seems you already have a CA at /etc/openvpn/pki/ca.crt'
  fi
else
  if [ "$EUID" -ne 0 ]; then
    sudo mkdir -p /etc/openvpn/pki
  else
    mkdir -p /etc/openvpn/pki
  fi
  echo 'saving provided CA certificate to /etc/openvpn/pki/ca.crt'
  echo "$CA_CERTIFICATE" > /etc/openvpn/pki/ca.crt

  echo 'saving provided CA key to /etc/openvpn/pki/private/ca.key'
  echo "$CA_KEY" > /etc/openvpn/pki/private/ca.key
  chmod 600 /etc/openvpn/pki/private/ca.key
  ln -svf /etc/openvpn/pki/private/ca.key /etc/openvpn/ca.key
  cat /etc/openvpn/openssl-1.0.cnf
fi

# Diffie Hellman parameters
if [ -z "$DH_PARAMS" ]; then
  if [ ! -e 'pki/dh.pem' ]; then
    echo '> generating DH params'
    easyrsa gen-dh
    [ "$DEBUG" = 'true' ] && echo '> contents of new dh params' && cat /etc/openvpn/pki/dh.pem
  fi
else
  echo '> storing provided DH params'
  echo "$DH_PARAMS" > /etc/openvpn/pki/dh.pem
fi

echo '01' > /etc/openvpn/pki/serial
touch /etc/openvpn/pki/index.txt

# regardless, these directories should exist
mkdir -p /etc/openvpn/pki/issued /etc/openvpn/pki/private /etc/openvpn/pki/certs_by_serial

# server key
if [ ! -e "/etc/openvpn/pki/private/$(hostname -s).key" ]; then
  echo '> generating server csr and key'
  easyrsa --batch gen-req "$(hostname -s)" nopass
fi
ln -fsv "/etc/openvpn/pki/private/$(hostname -s).key" /etc/openvpn/server.key
# server certificate
if [ ! -e "/etc/openvpn/pki/issued/$(hostname -s).crt" ]; then
  echo '> generating server certificate'
  ls -lahR /etc/openvpn
  #easyrsa import-req "/etc/openvpn/pki/reqs/$(hostname -s).req" "$(hostname -s)"
  easyrsa --batch sign-req server "$(hostname -s)" nopass
fi

echo '> re-configure openvpn server'
# original file known to not have a trailing return
echo '' >> "$OPENVPN_CONFIG_FILE"
# comment out the extra shared key, we are not that advanced (yet)
sed -i '/tls-auth ta.key 0/c\;tls-auth ta.key 0' "$OPENVPN_CONFIG_FILE"

# Auth specific settings
case $AUTH_TYPE in
  adcheck)
    set_conf "auth-user-pass-verify openvpnadcheck.lua via-env"
    set_conf "script-security 3"
    mkdir -p /etc/ssl/certs/
    [ -n "$ADCHECK_SERVER_CACERT" ] && echo "$ADCHECK_SERVER_CACERT" > /etc/ssl/certs/ldap_server.pem
    echo ">> reconfigure openvpnadcheck config"
    sed -i "s|\(AD_server=\).*|\1\"$ADCHECK_SERVER\"|" /etc/openvpn/openvpnadcheck.conf
    sed -i "s|\(AD_domain=\).*|\1\"$ADCHECK_DOMAIN\"|" /etc/openvpn/openvpnadcheck.conf
    sed -i "s|\(AD_dn=\).*|\1\"$ADCHECK_GROUPDN\"|" /etc/openvpn/openvpnadcheck.conf
    # Update openvpnadcheck.lua to use the user principal name instead of the sAMAccountName
    sed -i -e 's|sAMAccountName|userPrincipalName|g' \
      -e 's|string.lower(os.getenv("username")) |string.lower(os.getenv("username").."@"..AD_domain) |' \
           /etc/openvpn/openvpnadcheck.lua
    ;;
  azuread)
    ([ -z "$AZUREAD_TENANT_ID" ] || [ -z "$AZUREAD_CLIENT_ID" ]) && \
      echo 'AZUREAD_TENANT_ID and AZUREAD_CLIENT_ID are required environment variables.' && \
      exit 1
    set_conf "auth-user-pass-verify openvpn-azure-ad-auth.py via-env"
    set_conf "script-security 3"
    echo ">> reconfigure azure-ad config"
    sed -i "s/{{tenant_id}}/$AZUREAD_TENANT_ID/" /etc/openvpn/config.yaml
    sed -i "s/{{client_id}}/$AZUREAD_CLIENT_ID/" /etc/openvpn/config.yaml
    sed -i "s/{{log_level}}/$HELPER_LOG_LEVEL/" /etc/openvpn/config.yaml
    if [ ! -z "$AZUREAD_GROUPS" ]; then
      grep -q "^permitted_groups:" /etc/openvpn/config.yaml || echo "permitted_groups:" >> /etc/openvpn/config.yaml
      IFS=',' read -ra groups <<< "$AZUREAD_GROUPS"
      for group in "${groups[@]}"; do
        echo ">>> Adding group access for '$group'"
        grep -q -- "- $group" /etc/openvpn/config.yaml || sed -i -e "/^permitted_groups:/a \  - $group" /etc/openvpn/config.yaml
      done
    fi
    # we also need to make it uses hashlib (err m$..)
    sed -i "s/#import hashlib/import hashlib/" /etc/openvpn/openvpn-azure-ad-auth.py
    sed -i "s/#from hmac import compare_digest/from hmac import compare_digest/" /etc/openvpn/openvpn-azure-ad-auth.py
    sed -i "s/^from backports.pbkdf2 import pbkdf2_hmac, compare_digest/#from backports.pbkdf2 import pbkdf2_hmac, compare_digest/" /etc/openvpn/openvpn-azure-ad-auth.py
    sed -i "s/(pbkdf2_hmac(/(hashlib.pbkdf2_hmac(/" /etc/openvpn/openvpn-azure-ad-auth.py
    ;;
esac

set_conf "verify-client-cert none"
set_conf "username-as-common-name"

if [ ! -z "$PUSH_OPTIONS" ]; then
  echo '>> adding push options'
  IFS=',' read -ra options <<< "$PUSH_OPTIONS"
  for option in "${options[@]}"; do
    echo ">>> $option"
    set_conf "push \"$option\""
  done
fi

[ "$DEBUG" = 'true' ] && echo '> directory listing of /etc/openvpn' && ls -l /etc/openvpn
[ "$DEBUG" = 'true' ] && echo '> contents of CA certificate' && cat /etc/openvpn/pki/ca.crt

echo "> reconfigure server"
#sed -i '/cert server.crt/c\;cert server.crt' /etc/openvpn/server.conf
#sed -i '/key server.key/c\;key server.key  # This file should be kept secret' /etc/openvpn/server.conf

echo ">> openvpn server config: $OPENVPN_CONFIG_FILE"
[ "$DEBUG" = 'true' ] && cat /etc/openvpn/server.conf

echo "> reconfigure client config"
sed -i "s/remote my-server-1 1194/remote $REMOTE_HOST $REMOTE_PORT/" /etc/openvpn/client.conf
echo 'auth-user-pass' >> /etc/openvpn/client.conf
# cancel out the client pki usage
sed -i 's/ca ca.crt/;ca ca.crt/' /etc/openvpn/client.conf
sed -i 's/cert client.crt/;cert client.crt/' /etc/openvpn/client.conf
sed -i 's/key client.key/;key client.key/' /etc/openvpn/client.conf
sed -i 's/tls-auth ta.key 1/;tls-auth ta.key 1/' /etc/openvpn/client.conf

echo '> copy client conf to client profile'
cp /etc/openvpn/client.conf /etc/openvpn/client.ovpn
echo "> append CA cert to client profile"
echo '<ca>' >> /etc/openvpn/client.ovpn
cat /etc/openvpn/pki/ca.crt >> /etc/openvpn/client.ovpn
echo '</ca>' >> /etc/openvpn/client.ovpn
[ "$PRINT_CLIENT_PROFILE" = 'true' ] && echo '>> print client profile' && cat /etc/openvpn/client.ovpn

echo '> linking pki'
ln -fsv "/etc/openvpn/pki/issued/$(hostname -s).crt" /etc/openvpn/server.crt
ln -fsv "/etc/openvpn/pki/private/$(hostname -s).key" /etc/openvpn/server.key
ln -fsv /etc/openvpn/pki/dh.pem /etc/openvpn/dh2048.pem
ln -fsv /etc/openvpn/pki/ca.crt /etc/openvpn/ca.crt

[ "$DEBUG" = 'true' ] && \
  echo '> list contents of /etc/openvpn/pki' && \
  ls -lahR /etc/openvpn/pki

# Setup NAT if needed
if [ "$NAT_ENABLE" = 'true' ]; then
  net=$(awk '/^server/ {print $2"/"$3}' ${OPENVPN_CONFIG_FILE})
  eth=$(ip route | awk '/^default/ {print $5}')
  iptables -t nat -A POSTROUTING -s ${net} -o ${eth} -j MASQUERADE
fi

echo "> $@" && exec "$@"
