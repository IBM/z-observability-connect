# ZOC Sample Dashboards

This repo provides sample Grafana dashboards that can be used to validate and visualize data from a successful installation of the ZOC Telemetry Controller.

## Prerequisites

- [Z Observability Connect Telemetry Controller](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=z-observability-connect-overview)
- [Grafana](https://grafana.com/docs/grafana/latest/setup-grafana/installation/)
- [Loki](https://grafana.com/docs/loki/latest/setup/install/)
- [Prometheus](https://prometheus.io/docs/prometheus/latest/installation/)

## Using the dashboards

### Available Dashboards

ZOC currently provides sample dashboards to view z/OS metrics and logs, along with internal metrics of the ZOC Telemetry Controller. The dashboards are located in the `dashboards/` directory.

### Importing Dashboards

You can add the dashboards to your Grafana instance in two ways:
1. [Importing Grafana Dasboards](https://grafana.com/docs/grafana-cloud/visualizations/dashboards/build-dashboards/import-dashboards/)
2. [Provisioning Grafana Dashboards](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards) 

### Datasource Configuration

Configure datasources in Grafana before importing dashboards:

- **Prometheus**: [Configuration Guide](https://grafana.com/docs/grafana/latest/datasources/prometheus/)
- **Loki**: [Configuration Guide](https://grafana.com/docs/grafana/latest/datasources/loki/)

### Important Notes

- Datasource UIDs: Dashboard JSON files contain hardcoded datasource UIDs. If your datasource UIDs differ, you may need to:
  - Update the datasource selection during import, OR
  - Edit the JSON file and replace the `datasource` UID values with your actual datasource UIDs
  
- Data Availability: Dashboards will only display data if:
  - ZOC Telemetry Controller is properly configured and running
  - Metrics/logs are being exported to Prometheus/Loki
  - The datasources are correctly configured in Grafana

- Customization: After import, you can customize dashboards to fit your specific monitoring needs by entering edit mode (click dashboard settings → Edit)
