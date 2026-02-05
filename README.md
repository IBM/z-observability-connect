# ZOC Telemetry Controller Grafana Dashboards

Sample Grafana dashboards for visualizing and validating ZOC Telemetry Controller data. Dashboards located in `dashboards/` directory.

## Quick Start with Docker Compose

### Prerequisites

- [Z Observability Connect Telemetry Controller](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=z-observability-connect-overview)
- Docker/Podman with Compose

### Deployment

#### 1. Clone repository
```bash
git clone git@github.com:IBM/zoc-telemetry-controller-assets.git
```

#### 2. Setup Tempo storage
```bash
sudo mkdir -p /var/tempo
sudo chown -R 10001:10001 /var/tempo
```

#### 3. Configure Prometheus scrape targets

ZOC Telemetry Controller exposes two metric endpoints:
- z/OS metrics (default port: 30889 or 31889)
- Internal telemetry metrics (default port: 30888 or 31888)

Note: 30 based ports will be used if you have deployed with Helm. 31 based ports will be used if you have deployed with the telemetryctl CLI tool.

Edit `config/tools/prometheus.yml` and replace `<telemetry-controller-fqdn>:<zos-metrics-port>` and `<telemetry-controller-fqdn>:<internal-metrics-port>` with actual values.

#### 4. Deploy stack

Docker:
```bash
docker compose up -d
```

Podman:
```bash
podman-compose up -d
```

#### 5. Access and configure

Access Grafana at `http://localhost:3000`.

Configure ZOC Telemetry Controller to send:
- OTLP gRPC traces to `http://<grafana-vm-endpoint>:4317`
- OTLP HTTP logs to `http://<grafana-vm-endpoint>:3100/otlp`

## Import to Existing Grafana

### Prerequisites

- [Z Observability Connect Telemetry Controller](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=z-observability-connect-overview)
- [Grafana](https://grafana.com/docs/grafana/latest/setup-grafana/installation/) (tested with 11.4.6)
- [Loki](https://grafana.com/docs/loki/latest/setup/install/)
- [Prometheus](https://prometheus.io/docs/prometheus/latest/installation/)

### Setup

1. Configure datasources ([Prometheus](https://grafana.com/docs/grafana/latest/datasources/prometheus/), [Loki](https://grafana.com/docs/grafana/latest/datasources/loki/))
2. Import dashboards via [UI](https://grafana.com/docs/grafana-cloud/visualizations/dashboards/build-dashboards/import-dashboards/) or [provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards)

### Notes

- **Datasource UIDs**: Dashboard JSONs contain hardcoded UIDs. Update during import or edit JSON `datasource` fields to match your UIDs.
- **Data availability**: Requires ZOC Telemetry Controller running and exporting to Prometheus/Loki with correct datasource configuration.
- **Customization**: Edit dashboards via dashboard settings → Edit.
