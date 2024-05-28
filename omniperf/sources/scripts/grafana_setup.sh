#!/bin/bash

GRAFANA_INSTALL_FROM_SOURCE=0

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--grafana_install_from_source")
          shift
          GRAFANA_INSTALL_FROM_SOURCE=1
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

echo ""
echo "====================================="
echo "Installing Grafana:"
echo "GRAFANA_INSTALL_FROM_SOURCE is $GRAFANA_INSTALL_FROM_SOURCE"
echo "====================================="
echo ""

# fix the nodejs install if broken
cd /etc/apt/sources.list.d  \
 && ls -lsa  \
 && rm -f  nodesource.list \
 && apt-get --fix-broken install \
 && apt-get update  \
 && apt-get remove nodejs \
 && apt-get remove nodejs-doc 

apt-get update 
apt-get install -y apt-transport-https software-properties-common  adduser libfontconfig1 wget curl
wget -q https://dl.grafana.com/enterprise/release/grafana-enterprise_8.3.4_amd64.deb
dpkg -i grafana-enterprise_8.3.4_amd64.deb
echo "deb https://packages.grafana.com/enterprise/deb stable main" | tee -a /etc/apt/sources.list.d/grafana.list
echo "deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main" | tee /etc/apt/sources.list.d/yarn.list
apt-get install gnupg
wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc -O server-6.0.asc
apt-key add server-6.0.asc
echo "deb [trusted=yes arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org.list
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/yarnkey.gpg > /dev/null
apt-get update
apt-get install -y mongodb-org
apt-get install -y tzdata systemd apt-utils npm vim net-tools
mkdir -p /nonexistent
/usr/sbin/grafana-cli plugins install michaeldmoore-multistat-panel
/usr/sbin/grafana-cli plugins install ae3e-plotly-panel
/usr/sbin/grafana-cli plugins install natel-plotly-panel
/usr/sbin/grafana-cli plugins install grafana-image-renderer
apt-get autoremove -y
chown root:grafana /etc/grafana
pushd /var/lib/grafana/plugins/omniperfData_plugin
npm install
npm run build
curl --compressed -o- -L https://yarnpkg.com/install.sh | bash
apt-get autoremove -y
apt-get autoclean -y
popd
pushd /var/lib/grafana/plugins/custom-svg
sed -i "s/  bindIp.*/  bindIp: 0.0.0.0/" /etc/mongod.conf
mkdir -p /var/lib/grafana
touch /var/lib/grafana/grafana.lib
chown grafana:grafana /var/lib/grafana/grafana.lib
popd
rm grafana-enterprise_8.3.4_amd64.deb server-6.0.asc
