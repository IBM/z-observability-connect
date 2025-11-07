FROM registry.access.redhat.com/ubi9/ubi:latest

ENV GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
    GF_PATHS_DATA="/var/lib/grafana" \
    GF_PATHS_HOME="/usr/share/grafana" \
    GF_PATHS_LOGS="/var/log/grafana" \
    GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
    GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

RUN yum install -y \
    wget \
    shadow-utils \
    tar \
    && yum install -y https://dl.grafana.com/oss/release/grafana-11.4.0-1.x86_64.rpm \
    && yum clean all \
    \
    && mkdir -p /etc/grafana /var/lib/grafana /var/log/grafana \
    && chown -R grafana:grafana /etc/grafana /var/lib/grafana /var/log/grafana \
    && chmod -R g+rw /etc/grafana /var/lib/grafana /var/log/grafana

EXPOSE 3000

USER grafana
WORKDIR /usr/share/grafana

CMD ["/usr/sbin/grafana-server", "--homepath=/usr/share/grafana"]
