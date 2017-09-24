#!/bin/bash -e

: ${REMOTE_HOST:=127.0.0.1}
: ${REMOTE_PORT:=1194}
: ${OPENVPN_CONFIG_FILE:=/etc/openvpn/server.conf}

# for azure ad, tenant id and client id are required
([ -z "$TENANT_ID" ] || [ -z "$CLIENT_ID" ]) && \
  echo 'TENANT_ID and CLIENT_ID are required environment variables.' && \
  exit 1

echo "REMOTE_HOST=$REMOTE_HOST"
echo "REMOTE_PORT=$REMOTE_PORT"
echo "OPENVPN_CONFIG_FILE=$OPENVPN_CONFIG_FILE"
echo "CLIENT_ID=$CLIENT_ID"
echo "TENANT_ID=$TENANT_ID"
[ "$DEBUG" = 'true' ] && [ ! -z "$CA_CERTIFICATE" ] && printf "CA_CERTIFICATE=\n$CA_CERTIFICATE\n"

export PATH="$PATH:/usr/share/easy-rsa"

set_conf(){
  directive="$1"
  values="$(echo $@ | cut -d ' ' -f 2,3,4,5)"
  # echo "directive is $directive"
  # echo "values is $values"

  # quick and dirty append for now
  if [ "$directive" = "$values" ]; then
    echo "$directive" >> "$OPENVPN_CONFIG_FILE"
  else
    echo "$directive" "$values" >> "$OPENVPN_CONFIG_FILE"
  fi
}

cd /etc/openvpn

if [ ! -e 'pki' ]; then
  echo '> initialising easy-rsa pki'
  easyrsa init-pki
fi

if [ -z "$CA_CERTIFICATE" ]; then
  if [ ! -e '/etc/openvpn/pki/ca.crt' ]; then
    echo '> generating CA'
    easyrsa --batch build-ca nopass
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
  echo "$CA_CERTIFICATE" /etc/openvpn/pki/ca.crt
fi

echo '> generating server pki'
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

echo '> generating DH params'
easyrsa gen-dh

# echo '> list contents of /etc/openvpn/pki'
# ls -lahR /etc/openvpn/pki

echo '> linking pki'
ln -sv /etc/openvpn/pki/ca.crt /etc/openvpn/ca.crt
ln -sv "/etc/openvpn/pki/issued/$(hostname -s).crt" /etc/openvpn/server.crt
ln -sv "/etc/openvpn/pki/private/$(hostname -s).key" /etc/openvpn/server.key
ln -sv /etc/openvpn/pki/dh.pem /etc/openvpn/dh2048.pem

echo '> re-configure openvpn server'
# original file known to not have a trailing return
echo '' >> "$OPENVPN_CONFIG_FILE"
# comment out the extra shared key, we are not that advanced (yet)
sed -i '/tls-auth ta.key 0/c\;tls-auth ta.key 0' "$OPENVPN_CONFIG_FILE"
set_conf auth-user-pass-verify \"openvpn-azure-ad-auth.py --consent\" via-env
set_conf verify-client-cert none
set_conf username-as-common-name
set_conf script-security 3

if [ ! -z "$PUSH_ROUTES" ]; then
  echo '>> adding push routes'
  IFS=',' read -ra routes <<< "$PUSH_ROUTES"
  for route in "${routes[@]}"; do
    echo ">>> $route"
    set_conf push route \""$route"\"
  done
fi

[ "$DEBUG" = 'true' ] && echo '> directory listing of /etc/openvpn' && ls -l /etc/openvpn
[ "$DEBUG" = 'true' ] && echo '> contents of CA certificate' && cat /etc/openvpn/pki/ca.crt

echo "> reconfigure azure-ad config"
sed -i "s/{{tenant_id}}/$TENANT_ID/" /etc/openvpn/config.yaml
sed -i "s/{{client_id}}/$CLIENT_ID/" /etc/openvpn/config.yaml
sed -i "s/{{log_level}}/$HELPER_LOG_LEVEL/" /etc/openvpn/config.yaml
# we also need to make it uses hashlib (err m$..)
sed -i "s/#import hashlib/import hashlib/" /etc/openvpn/openvpn-azure-ad-auth.py
sed -i "s/#from hmac import compare_digest/from hmac import compare_digest/" /etc/openvpn/openvpn-azure-ad-auth.py
sed -i "s/from backports.pbkdf2 import pbkdf2_hmac, compare_digest/#from backports.pbkdf2 import pbkdf2_hmac, compare_digest/" /etc/openvpn/openvpn-azure-ad-auth.py
sed -i "s/pbkdf2_hmac(/hashlib.pbkdf2_hmac(/" /etc/openvpn/openvpn-azure-ad-auth.py

echo "> openvpn server config: $OPENVPN_CONFIG_FILE"
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

echo "> $@" && exec "$@"
