#!/bin/bash

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

INSTALL_GRAFANA=0

usage()
{
   echo "Usage:"
   echo "  --help: display this usage information"
   echo "  --install-grafana: default value is 0, set it to 1 to install grafana"
   exit 1
}

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}


n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--help")
          shift
          usage
          ;;
      "--install-grafana")
          shift
          INSTALL_GRAFANA=${1}
	  reset-last
          ;;
      "--*")
          send-error "Unsupported argument at position $((${n} + 1)) :: ${1}"
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
${SUDO} apt-get --fix-broken install
${SUDO} apt-get update
${SUDO} apt-get remove nodejs
${SUDO} apt-get remove nodejs-doc
popd

${SUDO} apt-get update
${SUDO} apt-get install -y apt-transport-https software-properties-common  adduser libfontconfig1 wget curl
wget -q https://dl.grafana.com/enterprise/release/grafana-enterprise_8.3.4_amd64.deb
${SUDO} dpkg -i grafana-enterprise_8.3.4_amd64.deb
echo "deb https://packages.grafana.com/enterprise/deb stable main" | tee -a /etc/apt/sources.list.d/grafana.list
echo "deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main" | tee /etc/apt/sources.list.d/yarn.list
${SUDO} apt-get install gnupg
wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc -O server-6.0.asc
${SUDO} apt-key add server-6.0.asc
echo "deb [trusted=yes arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org.list
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/yarnkey.gpg > /dev/null
${SUDO} apt-get update
${SUDO} apt-get install -y mongodb-org
${SUDO} apt-get install -y tzdata systemd apt-utils npm vim net-tools
${SUDO} mkdir -p /nonexistent
/usr/sbin/grafana-cli plugins install michaeldmoore-multistat-panel
/usr/sbin/grafana-cli plugins install ae3e-plotly-panel
/usr/sbin/grafana-cli plugins install natel-plotly-panel
/usr/sbin/grafana-cli plugins install grafana-image-renderer
${SUDO} apt-get autoremove -y
${SUDO} chown root:grafana /etc/grafana
pushd /var/lib/grafana/plugins/omniperfData_plugin
npm install
npm run build
curl --compressed -o- -L https://yarnpkg.com/install.sh | bash
${SUDO} apt-get autoremove -y
${SUDO} apt-get autoclean -y
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
