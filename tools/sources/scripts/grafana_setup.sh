#!/bin/bash

SUDO="sudo"
DEBIAN_FRONTEND_MODE="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEBIAN_FRONTEND_MODE=""
fi

INSTALL_GRAFANA=0

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--install-grafana")
          shift
          INSTALL_GRAFANA=${1}
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
echo "INSTALL_GRAFANA is $INSTALL_GRAFANA"
echo "====================================="
echo ""

if [[ "$INSTALL_GRAFANA" == "0" ]];then
   exit
fi

# fix the nodejs install if broken
pushd /etc/apt/sources.list.d
ls -lsa 
rm -f  nodesource.list
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get --fix-broken install
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get update
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get remove nodejs
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get remove nodejs-doc 
popd

${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get update 
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get install -y apt-transport-https software-properties-common  adduser libfontconfig1 wget curl
wget -q https://dl.grafana.com/enterprise/release/grafana-enterprise_8.3.4_amd64.deb 
${SUDO} dpkg -i grafana-enterprise_8.3.4_amd64.deb
echo "deb https://packages.grafana.com/enterprise/deb stable main" | tee -a /etc/apt/sources.list.d/grafana.list
echo "deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main" | tee /etc/apt/sources.list.d/yarn.list
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get install gnupg
wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc -O server-6.0.asc
${SUDO} apt-key add server-6.0.asc
echo "deb [trusted=yes arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org.list
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/yarnkey.gpg > /dev/null
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get update
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get install -y mongodb-org
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get install -y tzdata systemd apt-utils npm vim net-tools
${SUDO} mkdir -p /nonexistent
/usr/sbin/grafana-cli plugins install michaeldmoore-multistat-panel
/usr/sbin/grafana-cli plugins install ae3e-plotly-panel
/usr/sbin/grafana-cli plugins install natel-plotly-panel
/usr/sbin/grafana-cli plugins install grafana-image-renderer
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get autoremove -y
${SUDO} chown root:grafana /etc/grafana
pushd /var/lib/grafana/plugins/omniperfData_plugin
npm install
npm run build
curl --compressed -o- -L https://yarnpkg.com/install.sh | bash
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get autoremove -y
${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get autoclean -y
popd
pushd /var/lib/grafana/plugins/custom-svg
${SUDO} sed -i "s/  bindIp.*/  bindIp: 0.0.0.0/" /etc/mongod.conf
${SUDO} mkdir -p /var/lib/grafana
touch /var/lib/grafana/grafana.lib
chown grafana:grafana /var/lib/grafana/grafana.lib
popd
rm grafana-enterprise_8.3.4_amd64.deb server-6.0.asc

# switch Grafana port to 4000
sed -i "s/^;http_port = 3000/http_port = 4000/" /etc/grafana/grafana.ini
sed -i "s/^http_port = 3000/http_port = 4000/" /usr/share/grafana/conf/defaults.ini
