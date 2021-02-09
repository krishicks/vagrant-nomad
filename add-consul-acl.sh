#!/usr/bin/env bash
set -o pipefail

vms="$(vagrant status | grep running)"
servers="$(echo "$vms" | grep server | cut -f1 -d' ')"
clients="$(echo "$vms" | grep client | cut -f1 -d' ')"

export CONSUL_HTTP_ADDR=http://10.199.0.10:8500

if [ -z "$vms" ]; then echo "no vms found; exiting" && exit 1; fi
if [ -z "$servers" ]; then echo "no servers found; exiting" && exit 1; fi
if [ -z "$clients" ]; then echo "no clients found; exiting" && exit 1; fi

echo "enabling Consul ACLs and restarting Consul"
cmd="$(cat <<EOF
sudo sed -i 's/acl {.*}/acl { enabled = true, default_policy = "deny", enable_token_persistence = true }/g' /opt/consul/config.hcl
sudo systemctl restart consul
EOF
)"

for name in $servers; do
  vagrant ssh "$name" -c "$cmd" >/dev/null 2>&1
done

# Wait for ACLs to actually be ready for bootstrapping; errors will be
#   ACL support disabled
#   The ACL system is currently in legacy mode
#   Permission denied
while true; do
  if [[ "$(curl -s http://10.199.0.10:8500/v1/acl/policies)" =~ "Permission denied" ]]; then
    break
  else
    sleep 1
  fi
done

# bootstrap (or re-bootstrap) Consul
consulBootstrapJSON="$(consul acl bootstrap -format=json 2>&1)"

consulToken="$(jq -r '.SecretID' <<< "$consulBootstrapJSON")"
export CONSUL_HTTP_TOKEN="$consulToken"

echo "bootstrap complete"
echo "use the following to set up your environment"
echo
echo "export CONSUL_HTTP_TOKEN=$consulToken"
echo


  serverPolicy="$(cat <<EOF
agent_prefix "" {
  policy = "read"
}

node_prefix "" {
  policy = "read"
}

service_prefix "" {
  policy = "write"
}

acl = "write"
EOF
)"

echo "creating server acl policy"

consul acl policy create \
  -name "nomad-server" \
  -description "Nomad server policy" \
  -rules "$serverPolicy" >/dev/null

  clientPolicy="$(cat <<EOF
agent_prefix "" {
  policy = "read"
}

node_prefix "" {
  policy = "read"
}

service_prefix "" {
  policy = "write"
}
EOF
)"

echo "creating client acl policy"

consul acl policy create \
  -name "nomad-client" \
  -description "Nomad client policy" \
  -rules "$clientPolicy" >/dev/null

echo "creating server/client acl token"

agentToken="$(
  consul acl token create \
    -description "Nomad agent token" \
    -policy-name "nomad-server" \
    -policy-name "nomad-client" \
    -format json | jq -r '.SecretID'
)"

function waitForNomad() {
  things="$1"
  path="$2"
  count="$3"

  echo -n "waiting for $things to be ready.."
  while true; do
    if [ "$(curl -s "http://10.199.0.10:4646/v1""$path" 2>/dev/null | jq -r 'length')" == "$count" ]; then
      echo
      break
    else
      echo -n '.'
      sleep 1
    fi
  done
}

waitForNomad servers "/status/peers" "$(echo "$servers" | wc -w)"
waitForNomad clients "/nodes" "$(echo "$clients" | wc -w)"

for name in $servers $clients; do
  echo "applying Consul ACL token and restarting $name"

  cmd="$(cat <<EOF
sudo sed -i 's/consul {.*}/consul { token = \"$agentToken\" }/g' /opt/nomad/config.hcl
sudo systemctl restart nomad
EOF
)"
  vagrant ssh "$name" -c "$cmd" >/dev/null 2>&1
done